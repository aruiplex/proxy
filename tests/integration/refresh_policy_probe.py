#!/usr/bin/env python3
"""Run actual subscription/pool refresh against local fixtures and a real core."""
import argparse
import contextlib
import json
import os
import subprocess
import tempfile
import threading
import urllib.request
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from protocol_probe import certificate, origin
from routing_probe import FixtureProxy, Stream, free_port, serving

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'libexec'))
from tun_config import defaults as tun_defaults


class Subscription(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.server.failed:
            self.send_error(503)
            return
        self.send_response(200)
        self.end_headers()
        self.wfile.write(self.server.profile.encode())


def check(binary):
    with contextlib.ExitStack() as stack:
        directory = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix='refresh-policy-')))
        home = directory / 'home'
        home.mkdir()
        _, _, server_tls, client_tls, _ = certificate(directory)
        target, health = origin(stack, server_tls), origin(stack)
        node = stack.enter_context(serving(FixtureProxy(target.server_address, health.server_address)))
        port, controller = free_port(), free_port()
        profile = f'''mixed-port: {port}
external-controller: 127.0.0.1:{controller}
secret: fixture-only
dns:
  enable: false
hosts:
  stream.test: 127.0.0.1
  health.test: 127.0.0.1
proxies:
  - {{name: Singapore one, type: http, server: 127.0.0.1, port: {node.server_address[1]}}}
proxy-groups:
  - name: PROXY
    type: select
    proxies: [Singapore one]
rules:
  - DOMAIN,blocked.test,REJECT
  - DOMAIN,localhost,DIRECT
  - MATCH,PROXY
'''
        server = ThreadingHTTPServer(('127.0.0.1', 0), Subscription)
        server.profile, server.failed = profile, False
        server.finished = threading.Event()
        stack.enter_context(serving(server))
        (home / 'config.yaml').write_text(profile)
        (home / 'proxy.conf').write_text(f'bin={binary}\ninstall_method=manual\nactive_sub=fixture\ncontroller=127.0.0.1:{controller}\nsecret=fixture-only\nregion_url=http://health.test:{health.server_address[1]}/health\n')
        (home / 'subs.conf').write_text(f'fixture\thttp://127.0.0.1:{server.server_port}/profile\n')
        (home / 'merge.yaml').write_text('prepend-rules:\n  - DOMAIN,stream.test,PROXY\n')
        (home / 'adaptive.json').write_text(json.dumps({'schema': 1, 'enabled': True, 'direct_first': True}))
        # Off is intentional: exercise refresh persistence without privileges or
        # touching host routes. Real TUN activation requires separate acceptance.
        tun_prefs = tun_defaults(os.getuid())
        tun_prefs['enabled'] = False
        (home / 'tun.json').write_text(json.dumps(tun_prefs))
        env = dict(os.environ, CONF_DIR=str(home), PYTHONDONTWRITEBYTECODE='1', NO_PROXY='127.0.0.1,localhost', no_proxy='127.0.0.1,localhost')

        def cli(*args):
            run = subprocess.run([str(ROOT / 'proxy'), *args], env=env, text=True, capture_output=True, timeout=40)
            if run.returncode:
                raise AssertionError(run.stdout + run.stderr)

        def connections():
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            req = urllib.request.Request(f'http://127.0.0.1:{controller}/connections', headers={'Authorization': 'Bearer fixture-only'})
            with opener.open(req, timeout=3) as response:
                return json.load(response)['connections'] or []

        cli('start')
        stack.callback(cli, 'stop')
        cli('sub', 'refresh')
        first = Stream(port, target.server_address[1], client_tls)
        stack.callback(first.close)
        checks = {'single_subscription_local_override_uses_adaptive_scope':
                  any('AUTO-ADAPTIVE' in c['chains'] and 'DIRECT' not in c['chains'] for c in connections())}
        checks['single_subscription_keeps_host_tun_preferences'] = 'device: "proxy-tun"' in (home / 'config.yaml').read_text()
        # Switching only this fixture to pool mode exercises the same public CLI.
        with (home / 'proxy.conf').open('a') as file:
            file.write('pool=on\n')
        cli('pool', 'refresh')
        second = Stream(port, target.server_address[1], client_tls)
        stack.callback(second.close)
        checks['pool_preserves_healthy_tls'] = first.progressing()
        checks['pool_keeps_host_tun_preferences'] = 'device: "proxy-tun"' in (home / 'config.yaml').read_text()
        checks['pool_local_override_uses_generated_scope'] = any('SG01' in c['chains'] and 'AUTO-ADAPTIVE' in c['chains'] for c in connections())
        checks['full_rule_profile_cached'] = (home / 'pool-state/fixture.profile').read_text().count('DOMAIN,blocked.test,REJECT') == 1
        server.failed = True
        cli('pool', 'refresh')
        checks['failed_download_uses_last_good_profile_and_keeps_streams'] = first.progressing() and second.progressing()
        (home / 'pool-state/fixture.profile').unlink()
        (home / 'config.fixture.yaml').write_text(profile)
        server.failed, server.profile = False, 'not a valid subscription'
        cli('pool', 'refresh')
        checks['legacy_cache_recovers_baseline_after_invalid_download'] = first.progressing() and second.progressing()
        text = (home / 'config.yaml').read_text()
        checks['explicit_direct_and_reject_survive_refresh'] = 'DOMAIN,blocked.test,REJECT' in text and 'DOMAIN,localhost,DIRECT' in text
        return {'checks': checks, 'scope': 'local HTTP subscription, isolated managed core and certificate-verified TLS; no production changes'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kernel', required=True, type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    report = check(str(args.kernel.resolve()))
    text = json.dumps(report, indent=2) + '\n'
    print(text, end='')
    if args.output:
        args.output.write_text(text)
    return 0 if all(report['checks'].values()) else 1


if __name__ == '__main__':
    raise SystemExit(main())
