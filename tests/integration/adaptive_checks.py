#!/usr/bin/env python3
"""Extra isolated real-kernel checks: region preference and whole-dial bounds."""
import argparse
import contextlib
import json
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer
from pathlib import Path

from routing_probe import FixtureProxy, Kernel, Origin, serving


def setup(stack, binary, options):
    directory = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix="adaptive-checks-")))
    origins = []
    for _ in range(2):
        origin = ThreadingHTTPServer(("127.0.0.1", 0), Origin)
        origin.daemon_threads = True
        origin.finished = threading.Event()
        origin.paused = threading.Event()
        origins.append(stack.enter_context(serving(origin)))
    # Deliberately put US before the second SG candidate in configuration order.
    nodes = {name: stack.enter_context(serving(FixtureProxy(*(o.server_address for o in origins)))) for name in ["nodeA", "nodeC", "nodeB"]}
    kernel = Kernel(binary, "adaptive", directory, *origins, nodes, 5, options)
    stack.callback(kernel.stop)
    for name in nodes:
        if "delay" not in kernel.probe(name):
            raise AssertionError("fixture health check failed")
    return kernel, nodes


def attempts(kernel, nodes):
    result = {}
    for name, node in nodes.items():
        with node.lock:
            result[name] = sum(target.endswith(f":{kernel.origin_port}") for target in node.attempts)
    return result


def delta(before, after):
    return {key: after[key] - before[key] for key in before}


def region_check(binary):
    with contextlib.ExitStack() as stack:
        kernel, nodes = setup(stack, binary, {"failure-cooldown": 30000, "preferred-region": "SG", "regions": {"nodeA": "SG", "nodeB": "SG", "nodeC": "US"}})
        first = kernel.stream()
        stack.callback(first.close)
        kernel.wait_connections(1)
        nodes["nodeA"].failure_scope = "target"
        nodes["nodeA"].reject.set()
        before = attempts(kernel, nodes)
        second = kernel.stream()
        stack.callback(second.close)
        same_region = delta(before, attempts(kernel, nodes))
        nodes["nodeB"].failure_scope = "target"
        nodes["nodeB"].reject.set()
        before = attempts(kernel, nodes)
        third = kernel.stream()
        stack.callback(third.close)
        cross_region = delta(before, attempts(kernel, nodes))
        kernel.wait_connections(3)
        return {"checks": {
            "same_region_before_cross_region": same_region == {"nodeA": 1, "nodeC": 0, "nodeB": 1},
            "cross_region_after_local_candidates_fail": cross_region == {"nodeA": 0, "nodeC": 1, "nodeB": 1},
            "all_established_streams_survive": first.progressing() and second.progressing() and third.progressing(),
        }, "observations": {"same_region_attempts": same_region, "cross_region_attempts": cross_region}}


def budget_check(binary, stall=False):
    with contextlib.ExitStack() as stack:
        kernel, nodes = setup(stack, binary, {"max-attempts": 2, "dial-budget": 250, "attempt-timeout": 200})
        first = kernel.stream()
        stack.callback(first.close)
        kernel.wait_connections(1)
        for node in nodes.values():
            node.failure_scope = "target"
            (node.stall if stall else node.reject).set()
        before = attempts(kernel, nodes)
        started = time.monotonic()
        failed = False
        try:
            unexpected = kernel.stream()
            stack.callback(unexpected.close)
        except (OSError, EOFError, ValueError):
            failed = True
        elapsed = time.monotonic() - started
        counts = delta(before, attempts(kernel, nodes))
        # Wait beyond the old outer-loop backoff: no extra adapter attempts.
        time.sleep(0.35)
        settled = delta(before, attempts(kernel, nodes))
        return {"checks": {
            "bounded_failure_returned": failed and elapsed < 1.0,
            "one_attempt_per_candidate_and_max_two": counts == {"nodeA": 1, "nodeC": 1, "nodeB": 0},
            "outer_retry_does_not_restart_budget": settled == counts,
            "healthy_stream_survives_exhaustion": first.progressing(),
        }, "observations": {"attempts": counts, "dial_seconds": round(elapsed, 3), "configured_budget_ms": 250, "stalled": stall}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kernel", required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    binary = str(Path(args.kernel).resolve())
    report = {"region": region_check(binary), "refused_budget": budget_check(binary), "stalled_budget": budget_check(binary, stall=True)}
    formatted = json.dumps(report, indent=2)
    print(formatted)
    if args.output:
        args.output.write_text(formatted + "\n")
    return 0 if all(passed for case in report.values() for passed in case["checks"].values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
