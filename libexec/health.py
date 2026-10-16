#!/usr/bin/env python3
"""Local health evidence. Public GET probes only; never restarts or replays traffic."""
import argparse
import collections
import datetime
import fcntl
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import tempfile
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

TARGETS = {'chatgpt': 'https://chatgpt.com/robots.txt',
           'google': 'https://www.google.com/robots.txt',
           'gemini': 'https://gemini.google.com/robots.txt'}
UNIT = 'proxy-mihomo.service'
sys.path.insert(0, str(Path(__file__).resolve().parent))
from core_health import check_listener_ownership


def atomic(path, value):
    with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as out:
        pending = Path(out.name)
        try:
            os.chmod(pending, 0o600)
            json.dump(value, out, ensure_ascii=False, indent=2)
            out.flush(); os.fsync(out.fileno())
            os.replace(pending, path)
        finally:
            pending.unlink(missing_ok=True)


def evaluate(observation, previous=None):
    """Stable external interface: classify evidence and debounce notifications."""
    previous = previous or {}
    if observation.get('probe_error'):
        category = 'monitor_error'
    elif not observation.get('process_alive'):
        category = 'process_unavailable'
    elif not observation.get('listener_ownership_ok', True):
        category = 'listener_ownership_failure'
    elif not observation.get('controller_ok'):
        category = 'controller_unavailable'
    else:
        probes = observation.get('probes', {})
        failed = [name for name, result in probes.items() if not result.get('passed')]
        if not probes:
            category = 'monitor_error'
        elif not failed:
            category = 'healthy'
        elif len(failed) < len(probes):
            category = 'target_failure:' + ','.join(sorted(failed))
        elif observation.get('direct_controls_ok') is False:
            category = 'network_or_all_routes_failure'
        else:
            category = 'all_proxy_targets_failure'
    count = previous.get('consecutive', 0) + 1 if previous.get('observed') == category else 1
    confirmed = previous.get('confirmed', 'unknown')
    target_states = dict(previous.get('target_states', {}))
    active_targets = []
    if observation.get('process_alive') and observation.get('controller_ok') and not observation.get('probe_error'):
        for name, probe in observation.get('probes', {}).items():
            old = target_states.get(name, {})
            good = bool(probe.get('passed'))
            failures = 0 if good else old.get('failures', 0) + 1
            successes = old.get('successes', 0) + 1 if good else 0
            failed = old.get('failed', False)
            if failures >= 3: failed = True
            if successes >= 2: failed = False
            target_states[name] = {'failures': failures, 'successes': successes, 'failed': failed}
            if failed: active_targets.append(name)
        if active_targets and (category.startswith('target_failure:') or (category in ('all_proxy_targets_failure', 'network_or_all_routes_failure') and len(active_targets) < len(observation.get('probes', {})))):
            # A second intermittently failing target must not reset the first target's streak.
            category = 'target_failure:' + ','.join(sorted(active_targets))
            count = max(count, 3)
    threshold = 1 if category == 'process_unavailable' else (2 if category == 'healthy' else 3)
    notification = None
    if count >= threshold and confirmed != category:
        if not (confirmed == 'unknown' and category == 'healthy'):
            notification = {'from': confirmed, 'to': category}
        confirmed = category
    return {'schema': 1, 'observed': category, 'consecutive': count,
            'confirmed': confirmed, 'notification': notification, 'observation': observation, 'target_states': target_states}


def systemd(unit=UNIT, root=None):
    from systemd_service import supervisor
    try:
        scope, unit = supervisor(root) if root else ('user', unit)
    except (OSError, ValueError, RuntimeError):
        return {'supervisor_identity_invalid': True}
    result = subprocess.run(['systemctl', '--' + scope, 'show', unit,
        '--property=MainPID,NRestarts,ActiveState,SubState,Result,ExecMainCode,ExecMainStatus'],
        capture_output=True, text=True, timeout=5)
    if result.returncode:
        return {}
    evidence = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
    journal = subprocess.run(['journalctl', '--' + scope, '-u', unit, '-n', '30', '--output=json', '--no-pager'],
                             capture_output=True, text=True, timeout=5)
    exits = []
    limited = False
    for line in journal.stdout.splitlines():
        try:
            entry = json.loads(line)
            if entry.get('SYSLOG_IDENTIFIER') != 'systemd': continue
            if 'Start request repeated too quickly' in (entry.get('MESSAGE') or ''): limited = True
            match = re.search(r'Main process exited, code=(exited|killed|dumped), status=([0-9]+)', entry.get('MESSAGE', ''))
            if match:
                exits.append({'at_usec': entry.get('__REALTIME_TIMESTAMP'), 'code': match[1], 'status': int(match[2])})
        except (ValueError, TypeError): pass
    evidence['recent_exits'] = exits
    evidence['restart_limit_observed'] = limited
    evidence['scope'], evidence['unit'] = scope, unit
    return evidence


def public_probe(url, proxy, budget=10):
    # The total timeout bounds TLS, headers, body and redirects. No body is saved.
    result = subprocess.run(['curl', '--silent', '--show-error', '--proxy', proxy,
        '--noproxy', '', '--connect-timeout', str(budget), '--max-time', str(budget),
        '--max-filesize', '1048576', '--output', os.devnull, '--write-out', '%{json}', url],
        capture_output=True, timeout=budget + 2)
    try:
        data = json.loads(result.stdout)
    except (ValueError, UnicodeDecodeError):
        data = {}
    return {'passed': result.returncode == 0 and data.get('http_code') == 200
            and data.get('ssl_verify_result') == 0 and data.get('size_download', 0) > 0,
            'curl_exit': result.returncode, 'http_status': data.get('http_code', 0),
            'certificate_verified': result.returncode == 0 and data.get('ssl_verify_result') == 0,
            'complete_response': result.returncode == 0,
            'bytes': data.get('size_download', 0), 'seconds': data.get('time_total')}


def routing_evidence(qualities):
    """Retain route/fault correlation without storing private labels or guessing causes."""
    kinds = collections.Counter(); reasons = collections.Counter()
    events = []; faults = {}
    for group, quality in qualities:
        for event in quality.get('events') or []:
            kind = event.get('kind', 'unknown'); reason = event.get('reason', '')
            kinds[kind] += 1
            if reason: reasons[reason] += 1
            def label(value):
                return hashlib.sha256((group + '\0' + value).encode()).hexdigest()
            node = label(event.get('node', '')); target = label(event.get('target', ''))
            events.append({'at': event.get('at'), 'kind': kind, 'reason': reason,
                           'node_id': node, 'target_id': target})
            if kind in ('dial-failed', 'transport-error'):
                fault = faults.setdefault(node, {'targets': set(), 'kinds': collections.Counter()})
                fault['targets'].add(target); fault['kinds'][kind] += 1
    return {'event_kinds': dict(kinds), 'reasons': dict(reasons), 'events': events[-256:],
            'node_faults': [{'node_id': node, 'target_count': len(fault['targets']), 'kinds': dict(fault['kinds'])}
                            for node, fault in faults.items()],
            'scope': 'bounded kernel event history; fault identifies observed node, not business/root cause'}


def observe(root, proxy, targets=None, probe_budget=10, control_addresses=(('1.1.1.1', 443), ('8.8.8.8', 443))):
    result = {'process_alive': False, 'controller_ok': False, 'probes': {}, 'systemd': systemd(root=root)}
    try:
        pid = int((root / 'mihomo.pid').read_text())
        os.kill(pid, 0)
        # Reject a reused PID or foreign process; don't emit command line secrets.
        argv = (Path('/proc') / str(pid) / 'cmdline').read_bytes().split(b'\0')
        expected = [b'-d', os.fsencode(str(root)), b'-f', os.fsencode(str(root / 'config.yaml'))]
        result['process_alive'] = any(argv[i:i + 4] == expected for i in range(len(argv)))
        result['pid'] = pid
    except (OSError, ValueError):
        pass
    settings = dict(line.split('=', 1) for line in (root / 'proxy.conf').read_text().splitlines() if '=' in line)
    controller = settings.get('controller', '127.0.0.1:9090')
    parsed = urllib.parse.urlsplit('http://' + controller)
    if parsed.hostname not in ('localhost', '127.0.0.1', '::1') or not parsed.port:
        raise ValueError('health controller must use loopback')
    if result['process_alive']:
        try:
            proxy_port = urllib.parse.urlsplit(proxy).port
            result['listener_ownership_ok'] = check_listener_ownership(pid, {parsed.port, proxy_port})
        except OSError:
            result['listener_ownership_ok'] = False
            return result
    headers = {'Authorization': 'Bearer ' + settings['secret']} if settings.get('secret') else {}
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    def api(path):
        request = urllib.request.Request('http://' + controller + path, headers=headers)
        with opener.open(request, timeout=3) as response:
            return json.load(response)
    try:
        result['version'] = api('/version')['version']
        result['controller_ok'] = True
    except (OSError, ValueError, KeyError):
        pass
    if result['process_alive'] and result['controller_ok']:
        result['probes'] = {name: public_probe(url, proxy, probe_budget) for name, url in (targets or TARGETS).items()}
        # Route events are evidence, not proof of business success or a root cause.
        try:
            groups = [n for n, p in api('/proxies')['proxies'].items() if p.get('type') == 'Adaptive']
            qualities = []
            for group in groups[:16]:
                quality = api('/proxies/' + urllib.parse.quote(group, safe='') + '/quality')
                qualities.append((group, quality))
            result['routing'] = routing_evidence(qualities)
            result['routing']['groups_truncated'] = len(groups) > 16
        except (OSError, ValueError, KeyError):
            result['routing'] = {'available': False}
        if not any(p['passed'] for p in result['probes'].values()):
            controls = []
            for address in control_addresses:
                try:
                    with socket.create_connection(address, timeout=2): controls.append(True)
                except OSError:
                    controls.append(False)
            result['direct_controls_ok'] = any(controls) if controls else None
    return result


def rotate(root, max_bytes=50 * 1024 * 1024, retention_days=7, keep=8):
    """copytruncate keeps the existing append fd; no core restart or signal.

    Like logrotate copytruncate, a tiny concurrent-write loss window remains.
    The first oversized historical log is preserved outside routine retention.
    """
    log = root / 'mihomo.log'
    archive = root / 'logs'; archive.mkdir(mode=0o700, exist_ok=True)
    files = sorted(archive.glob('mihomo-*.log'), key=lambda p: p.stat().st_mtime, reverse=True)
    for index, path in enumerate(files):
        if index >= keep or path.stat().st_mtime < time.time() - retention_days * 86400:
            path.unlink()
    if not log.exists() or log.stat().st_size < max_bytes:
        return {'rotated': False}
    stamp = time.time_ns()
    historic = log.stat().st_size > 500 * 1024 * 1024 and not (archive / 'historical.log').exists()
    dest = archive / ('historical.log' if historic else f'mihomo-{stamp}.log')
    try:
        with log.open('r+b') as live, dest.open('xb') as saved:
            os.chmod(dest, 0o600)
            shutil.copyfileobj(live, saved, length=1024 * 1024)
            saved.flush(); os.fsync(saved.fileno())
            live.truncate(0)
    except Exception:
        # Never truncate on failed archive copy.
        dest.unlink(missing_ok=True)
        raise
    files = sorted(archive.glob('mihomo-*.log'), key=lambda p: p.stat().st_mtime, reverse=True)
    for index, path in enumerate(files):
        if index >= keep or path.stat().st_mtime < time.time() - retention_days * 86400:
            path.unlink()
    return {'rotated': True, 'historical_preserved': historic, 'archive_bytes': dest.stat().st_size}


def install(root):
    units = Path.home() / '.config/systemd/user'; units.mkdir(parents=True, exist_ok=True)
    script = Path(__file__).resolve()
    def quote(value):
        # systemd ExecStart uses its own quoting, percent expansion and C escapes.
        return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%') + '"'
    text = ('[Unit]\nDescription=Proxy public HTTPS health evidence\n'
        '[Service]\nType=oneshot\nUMask=0077\nTimeoutStartSec=90\n'
        'Environment=PATH=/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin\n'
        'ExecStart=/usr/bin/python3 ' + quote(script) + ' --root ' + quote(root) + ' check --rotate\n')
    for name, content in [('proxy-health.service', text), ('proxy-health.timer',
        '[Unit]\nDescription=Low frequency proxy health probes\n[Timer]\nOnBootSec=2min\n'
        'OnUnitActiveSec=5min\nRandomizedDelaySec=20\n[Install]\nWantedBy=timers.target\n')]:
        path = units / name
        if path.exists() and path.read_text() != content:
            raise ValueError('existing health unit differs; review before replacing')
        path.write_text(content); path.chmod(0o600)
    subprocess.run(['systemctl', '--user', 'daemon-reload'], check=True)
    subprocess.run(['systemctl', '--user', 'enable', '--now', 'proxy-health.timer'], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    sub = parser.add_subparsers(dest='command', required=True)
    check = sub.add_parser('check'); check.add_argument('--rotate', action='store_true')
    check.add_argument('--proxy', default='http://127.0.0.1:7890')
    sub.add_parser('status'); sub.add_parser('install'); sub.add_parser('uninstall')
    record = sub.add_parser('record')
    record.add_argument('--app', choices=['codex', 'antigravity'], required=True)
    record.add_argument('--outcome', choices=['complete', 'timeout', 'disconnect'], required=True)
    args = parser.parse_args()
    if args.command == 'check':
        proxy_url = urllib.parse.urlsplit(args.proxy)
        if proxy_url.scheme != 'http' or proxy_url.hostname not in ('127.0.0.1','localhost','::1') or not proxy_url.port or proxy_url.username or proxy_url.password:
            parser.error('probe proxy must be explicit loopback HTTP without credentials')
    root = args.root.resolve(); state_dir = root / 'health'; state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.umask(0o077)
    if args.command == 'install': install(root); return 0
    if args.command == 'uninstall':
        subprocess.run(['systemctl', '--user', 'disable', '--now', 'proxy-health.timer'], check=True); return 0
    if args.command == 'status':
        print((state_dir / 'state.json').read_text() if (state_dir / 'state.json').exists() else '{"confirmed":"unknown"}'); return 0
    with (state_dir / 'lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        now = datetime.datetime.now(datetime.timezone.utc).isoformat()
        events = state_dir / 'events.jsonl'
        if events.exists() and events.stat().st_size > 10 * 1024 * 1024:
            os.replace(events, state_dir / 'events.previous.jsonl')
        if args.command == 'record':
            event = {'at': now, 'kind': 'business_feedback', 'app': args.app, 'outcome': args.outcome,
                     'scope': 'user-observed response; socket reuse and backend path not independently traced'}
            with events.open('a') as output: output.write(json.dumps(event) + '\n')
            print(json.dumps(event)); return 0
        previous = {}
        try: previous = json.loads((state_dir / 'state.json').read_text())
        except (OSError, ValueError): pass
        try: observation = observe(root, args.proxy)
        except Exception as error: observation = {'probe_error': type(error).__name__}
        state = evaluate(observation, previous); state['at'] = now
        if args.rotate:
            try: state['log_rotation'] = rotate(root)
            except OSError as error: state['log_rotation'] = {'error_type': type(error).__name__}
        with events.open('a') as output:
            output.write(json.dumps({'at': now, 'kind': 'health_sample', **state}) + '\n')
        atomic(state_dir / 'state.json', state)
        if state['notification']:
            message = 'proxy health: ' + state['notification']['to']
            print(message, flush=True)
            if shutil.which('notify-send'):
                try:
                    subprocess.run(['notify-send', 'Proxy', message], capture_output=True, timeout=5)
                except (OSError, subprocess.SubprocessError):
                    print('proxy health: desktop notification unavailable; see journal', flush=True)
        print(json.dumps(state, ensure_ascii=False))
        return 0  # Reported faults are evidence; timer failures are reserved for runner faults.


if __name__ == '__main__': raise SystemExit(main())
