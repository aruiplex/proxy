#!/usr/bin/env python3
"""Opt-in live HTTPS acceptance: verify the response and continuous core health.

This performs public GET requests only. It does not read application credentials,
restart a service, select an exit, or modify routing. Reports contain no bodies.
"""
import argparse
import http.client
import json
import os
import re
import socket
import ssl
import subprocess
import threading
import time
import urllib.parse
import urllib.request
from pathlib import Path


def pid_identity(pid):
    os.kill(pid, 0)
    proc = Path('/proc') / str(pid) / 'stat'
    if proc.exists():
        # comm may contain spaces or parentheses; fields start after the last ).
        fields = proc.read_text().rsplit(')', 1)[1].split()
        if fields[0] == 'Z':
            raise OSError('core is a zombie')
        return fields[19]  # starttime: field 22, after pid and comm
    return str(pid)


def check_listener_ownership(pid, ports):
    """On Linux, reject healthy ports belonging to a competing core."""
    if not Path('/proc/net/tcp').exists():
        return False
    owned = set()
    for fd in (Path('/proc') / str(pid) / 'fd').iterdir():
        try:
            match = re.fullmatch(r'socket:\[(\d+)\]', os.readlink(fd))
        except FileNotFoundError:  # An unrelated socket can close during polling.
            continue
        if match:
            owned.add(match[1])
    found = set()
    for table in ('/proc/net/tcp', '/proc/net/tcp6'):
        path = Path(table)
        if not path.exists():
            continue
        for line in path.read_text().splitlines()[1:]:
            fields = line.split()
            port = int(fields[1].rsplit(':', 1)[1], 16)
            if fields[3] == '0A' and fields[9] in owned and port in ports:
                found.add(port)
    if found != ports:
        raise OSError('required listener is not owned by the expected core')
    return True


def run(args):
    settings_file = args.root / 'proxy.conf'
    settings = dict(line.split('=', 1) for line in settings_file.read_text().splitlines() if '=' in line)
    pid = int((args.root / 'mihomo.pid').read_text().strip())
    identity = pid_identity(pid)
    headers = {'Authorization': 'Bearer ' + settings['secret']} if settings.get('secret') else {}
    controller = settings.get('controller', '127.0.0.1:9090')
    controller_url = urllib.parse.urlsplit('http://' + controller)
    if controller_url.hostname not in ('127.0.0.1', 'localhost', '::1') or not controller_url.port:
        raise ValueError('controller must use a loopback address and explicit port')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    proxy = urllib.parse.urlsplit(args.proxy)
    if proxy.scheme != 'http' or proxy.hostname not in ('127.0.0.1', 'localhost', '::1') or not proxy.port:
        raise ValueError('proxy must be an explicit loopback HTTP proxy')
    if proxy.username or proxy.password:
        raise ValueError('proxy credentials are not accepted')
    urls = args.url or ['https://chatgpt.com/robots.txt']
    for url in urls:
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise ValueError('use public HTTPS URLs without credentials, queries or fragments')
    samples = []
    failures = []
    stop = threading.Event()
    version = None
    ownership_checked = False

    def health():
        nonlocal version, ownership_checked
        if pid_identity(pid) != identity:
            raise OSError('core PID was replaced')
        if int((args.root / 'mihomo.pid').read_text().strip()) != pid:
            raise OSError('core PID file was replaced')
        ownership_checked = check_listener_ownership(pid, {proxy.port, controller_url.port})
        with socket.create_connection((proxy.hostname, proxy.port), timeout=1):
            pass
        request = urllib.request.Request('http://' + controller + '/version', headers=headers)
        with opener.open(request, timeout=1) as response:
            current = json.load(response)['version']
        if args.expected_version and current != args.expected_version:
            raise ValueError('unexpected kernel version')
        if version is not None and current != version:
            raise ValueError('kernel version changed')
        version = current

    health()

    def monitor():
        while not stop.wait(0.2):
            try:
                health()
            except Exception as error:
                # Generic classifications only; urllib errors can contain URLs.
                failures.append({'kind': 'core_or_listener_unavailable', 'error_type': type(error).__name__})
                return

    watcher = threading.Thread(target=monitor, daemon=True)
    watcher.start()
    connections = {}
    try:
        for round_index in range(args.requests):
            for url in urls:
                if failures:
                    break
                target = urllib.parse.urlsplit(url)
                if args.keepalive:
                    started = time.monotonic()
                    if url not in connections:
                        connection = http.client.HTTPSConnection(proxy.hostname, proxy.port,
                            timeout=args.max_time, context=ssl.create_default_context())
                        connections[url] = (connection, None)
                        connection.set_tunnel(target.hostname, target.port or 443)
                        connection.connect()
                        connections[url] = (connection, connection.sock)
                    connection, original_socket = connections[url]
                    if connection.sock is not original_socket:
                        raise OSError('TLS connection was replaced')
                    connection.request('GET', target.path or '/', headers={'Connection': 'keep-alive'})
                    response = connection.getresponse()
                    count = 0
                    expected = response.getheader('Content-Length')
                    while True:
                        block = response.read(65536)
                        if not block:
                            break
                        count += len(block)
                    complete = expected is None or count == int(expected)
                    retained = connection.sock is original_socket
                    passed = response.status == args.expect_status and count > 0 and complete and retained
                    samples.append({'target': target.hostname, 'http_status': response.status,
                                    'certificate_verified': True, 'bytes_received': count,
                                    'complete_response': complete, 'same_tls_connection': retained,
                                    'tls_version': original_socket.version(),
                                    'seconds': round(time.monotonic() - started, 6), 'passed': passed})
                else:
                    result = subprocess.run([
                        'curl', '--silent', '--show-error', '--proxy', args.proxy,
                        '--noproxy', '', '--connect-timeout', str(args.max_time),
                        '--max-time', str(args.max_time), '--output', os.devnull,
                        '--write-out', '%{json}', url,
                    ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=args.max_time + 2)
                    try:
                        data = json.loads(result.stdout)
                    except (ValueError, UnicodeDecodeError):
                        data = {}
                    passed = (result.returncode == 0 and data.get('http_code') == args.expect_status
                              and data.get('ssl_verify_result') == 0 and data.get('size_download', 0) > 0)
                    samples.append({'target': target.hostname,
                                    'curl_exit': result.returncode, 'http_status': data.get('http_code', 0),
                                    'certificate_verified': data.get('ssl_verify_result') == 0,
                                    'bytes_received': data.get('size_download', 0),
                                    'seconds': data.get('time_total'), 'passed': passed})
                if not passed:
                    failures.append({'kind': 'https_request_failed'})
                    break
            if failures:
                break
            if args.keepalive and round_index + 1 < args.requests:
                stop.wait(args.idle_seconds)
        if not failures:
            stop.wait(args.settle_seconds)
        try:
            health()
        except Exception as error:
            failures.append({'kind': 'core_or_listener_unavailable', 'error_type': type(error).__name__})
    except Exception as error:
        failures.append({'kind': 'acceptance_exception', 'error_type': type(error).__name__})
    finally:
        stop.set()
        watcher.join(timeout=2)
        for connection, _ in connections.values():
            connection.close()
    try:
        same_pid = pid_identity(pid) == identity and int((args.root / 'mihomo.pid').read_text().strip()) == pid
    except (OSError, ValueError):
        same_pid = False
    return {'passed': bool(samples) and not failures and all(item['passed'] for item in samples),
            'version': version, 'same_pid_survived': same_pid,
            'listener_ownership_checked': ownership_checked,
            'request_mode': 'same TLS connection with idle intervals' if args.keepalive else 'fresh TLS connection per request',
            'core_health_continuous': not any(item['kind'] == 'core_or_listener_unavailable' for item in failures),
            'requests': samples, 'failures': failures,
            'scope': 'public HTTPS response, certificate verification and continuous PID/listener/controller checks; no authenticated AI request'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--proxy', default='http://127.0.0.1:7890')
    parser.add_argument('--url', action='append')
    parser.add_argument('--requests', type=int, default=3)
    parser.add_argument('--max-time', type=int, default=10)
    parser.add_argument('--settle-seconds', type=float, default=3)
    parser.add_argument('--keepalive', action='store_true', help='reuse the same verified TLS connection across requests')
    parser.add_argument('--idle-seconds', type=float, default=2)
    parser.add_argument('--expect-status', type=int, default=200)
    parser.add_argument('--expected-version')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    if args.requests < 1 or args.max_time < 1 or args.settle_seconds < 0 or args.idle_seconds < 0:
        parser.error('requests/max-time must be positive and settle-seconds nonnegative')
    os.umask(0o077)
    try:
        report = run(args)
    except Exception as error:
        report = {'passed': False, 'failures': [{'kind': 'preflight_failed', 'error_type': type(error).__name__}]}
    if args.report:
        with args.report.open('w') as output:
            os.chmod(args.report, 0o600)
            json.dump(report, output, indent=2)
            output.write('\n')
    print(json.dumps(report))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
