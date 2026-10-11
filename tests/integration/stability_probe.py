#!/usr/bin/env python3
"""Real TCP/TLS fault matrix, isolated ports and origins; no production changes."""
import argparse
import contextlib
import json
import tempfile
import time
from pathlib import Path

from protocol_probe import certificate, origin
from routing_probe import FixtureProxy, Kernel, Stream, serving


def check(binary, stream_seconds=60, idle_seconds=60):
    with contextlib.ExitStack() as stack:
        directory = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix='routing-stability-')))
        _, _, server_tls, client_tls, _ = certificate(directory)
        encrypted = origin(stack, server_tls); health = origin(stack)
        nodes = {name: stack.enter_context(serving(FixtureProxy(encrypted.server_address, health.server_address)))
                 for name in ['nodeA', 'nodeB', 'nodeC']}
        for node in nodes.values(): node.failure_scope = 'target'
        kernel = Kernel(str(binary), 'adaptive', directory, encrypted, health, nodes, 5,
                        {'preferred-region': 'US', 'regions': {'nodeA':'US','nodeB':'US','nodeC':'JP'},
                         'failure-cooldown': 300, 'max-attempts': 3, 'dial-budget': 1500, 'attempt-timeout': 500})
        stack.callback(kernel.stop)
        target = f'stream.test:{encrypted.server_address[1]}'
        def stream():
            result = Stream(kernel.port, encrypted.server_address[1], client_tls)
            stack.callback(result.close)
            return result
        def selected():
            records = kernel.api('/proxies/TEST/quality')['records']
            return max(records, key=lambda r:r['selection'])['node']
        checks = {}
        first = stream(); identity = first.conn
        checks['cold_start_preferred_region'] = selected() == 'nodeA'
        deadline = time.monotonic() + stream_seconds
        while time.monotonic() < deadline:
            if not first.progressing(min(0.3, max(0.01, deadline - time.monotonic()))):
                raise AssertionError('long TLS stream interrupted')
        checks['long_verified_tls_stream'] = first.conn is identity and not first.closed.is_set()
        encrypted.paused.set()
        time.sleep(idle_seconds)
        checks['idle_does_not_close_same_tls_socket'] = first.conn is identity and not first.closed.is_set()
        encrypted.paused.clear()
        checks['same_tls_stream_resumes_after_idle'] = first.progressing()
        kernel.api('/proxies/TEST/feedback', 'POST', {'target': target, 'reason': 'timeout'})
        second = stream()
        checks['feedback_prefers_same_region'] = selected() == 'nodeB'
        nodes['nodeB'].reject.set()
        third = stream()
        checks['node_failure_uses_cross_region_after_same_region_exhausted'] = selected() == 'nodeC'
        checks['fault_and_feedback_keep_sibling_streams'] = first.progressing() and second.progressing() and third.progressing()
        for node in nodes.values(): node.reject.set()
        # Wait out prior cooldown; all three candidates must be attempted at most once.
        time.sleep(0.35)
        before = sum(len(node.attempts) for node in nodes.values())
        started = time.monotonic()
        failed = False
        try: stream()
        except (OSError, ValueError, EOFError): failed = True
        elapsed = time.monotonic() - started
        attempts = sum(len(node.attempts) for node in nodes.values()) - before
        checks['all_candidates_failure_is_bounded'] = failed and 1 <= attempts <= 3 and elapsed < 3
        # Simulated upstream outage blocks new establishments, not unrelated healthy transports.
        checks['all_candidates_failure_keeps_established_streams'] = first.progressing() and second.progressing()
        for node in nodes.values(): node.reject.clear()
        time.sleep(0.35)
        recovered = stream()
        checks['temporary_outage_recovers_after_cooldown'] = recovered.progressing()
        # Replace group and node definitions through the actual controller reload seam.
        config = json.loads(kernel.config_path.read_text())
        config['proxies'] = [p for p in config['proxies'] if p['name'] != 'nodeC']
        config['proxy-groups'][0]['proxies'] = ['nodeA','nodeB']
        kernel.config_path.write_text(json.dumps(config))
        kernel.api('/configs', 'PUT', {'path': str(kernel.config_path)})
        checks['group_reload_preserves_existing_tls_stream'] = first.progressing() and third.progressing()
        after = stream()
        checks['subscription_node_removal_affects_future_only'] = selected() in ('nodeA','nodeB') and after.progressing()
        return {'checks': checks, 'stream_seconds': stream_seconds, 'idle_seconds': idle_seconds,
                'all_failed_attempts': attempts, 'all_failed_seconds': round(elapsed, 3),
                'tls_version': first.conn.version(),
                'scope': 'verified fixture TLS/TCP; upstream outage for new connections only; no physical-link migration, TUN, UDP, QUIC or authenticated AI'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kernel', type=Path, required=True)
    parser.add_argument('--stream-seconds', type=float, default=60)
    parser.add_argument('--idle-seconds', type=float, default=60)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.stream_seconds < 0 or args.idle_seconds < 0: parser.error('durations must be nonnegative')
    report = check(args.kernel.resolve(), args.stream_seconds, args.idle_seconds)
    text = json.dumps(report, indent=2)
    if args.output: args.output.write_text(text + '\n')
    print(text)
    return 0 if all(report['checks'].values()) else 1


if __name__ == '__main__': raise SystemExit(main())
