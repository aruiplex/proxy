#!/usr/bin/env python3
"""Verify generated eligibility and fail-closed routing on an isolated real core."""
import argparse
import contextlib
import json
import sys
import tempfile
from pathlib import Path

from protocol_probe import certificate, origin
from routing_probe import FixtureProxy, Kernel, Stream, serving

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'libexec'))
from adaptive_config import render
from routing_profile import node_identity


def check(binary):
    with contextlib.ExitStack() as stack:
        directory = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix='policy-scope-')))
        _, _, server_tls, client_tls, _ = certificate(directory)
        target, health = origin(stack, server_tls), origin(stack)
        nodes = {name: stack.enter_context(serving(FixtureProxy(target.server_address, health.server_address)))
                 for name in ['nodeA', 'nodeB']}
        kernel = Kernel(binary, 'adaptive', directory, target, health, nodes, 5)
        stack.callback(kernel.stop)
        config = json.loads(kernel.config_path.read_text())
        config['proxy-groups'][0]['proxies'] = ['DIRECT', 'nodeA', 'nodeB']
        ids = {p['name']: node_identity(p) for p in config['proxies']}
        prefs = {'direct_first': True, 'preferred_region': 'SG', 'services': {'ai': {
            'domains': ['stream.test'], 'allowed_regions': ['SG', 'US'],
            'verified_regions': {ids['nodeA']: 'SG'}}}}

        def reload():
            kernel.config_path.write_text(render(json.dumps(config), prefs))
            kernel.api('/configs?force=true', 'PUT', {'path': str(kernel.config_path)})

        def stream():
            result = Stream(kernel.port, target.server_address[1], client_tls)
            stack.callback(result.close)
            return result

        def fails():
            try:
                stream()
                return False
            except (OSError, EOFError, ValueError):
                return True

        def attempts(name):
            with nodes[name].lock:
                return sum(t.endswith(':' + str(target.server_address[1])) for t in nodes[name].attempts)

        reload()
        first = stream()
        connections = kernel.wait_connections(1)
        checks = {'verified_node_selected': 'nodeA' in connections[0]['chains'] and first.progressing(),
                  'proxy_policy_excludes_direct': 'DIRECT' not in connections[0]['chains']}
        nodes['nodeA'].failure_scope = 'target'
        nodes['nodeA'].reject.set()
        before = attempts('nodeB')
        checks['failed_eligible_node_never_uses_unverified_or_direct'] = fails() and attempts('nodeB') == before
        checks['healthy_tls_survives_failed_establishment'] = first.progressing()
        # Empty eligibility must reject even though a healthy direct origin exists.
        prefs['services']['ai']['verified_regions'] = {}
        reload()
        checks['empty_eligibility_rejects_instead_of_compatible_direct'] = fails()
        checks['healthy_tls_survives_policy_reload'] = first.progressing()
        prefs['services']['ai']['verified_regions'] = {ids['nodeA']: 'SG', ids['nodeB']: 'US'}
        reload()
        second = stream()
        connections = kernel.wait_connections(2)
        checks['allowed_cross_region_fallback'] = any('nodeB' in c['chains'] for c in connections) and second.progressing()
        checks['original_tls_still_open'] = first.progressing()
        return {'checks': checks, 'scope': 'isolated Linux TCP, generated policy, certificate-verified TLS; no accounts or production changes'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kernel', required=True, type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    report = check(str(args.kernel.resolve()))
    output = json.dumps(report, indent=2) + '\n'
    print(output, end='')
    if args.output:
        args.output.write_text(output)
    return 0 if all(report['checks'].values()) else 1


if __name__ == '__main__':
    raise SystemExit(main())
