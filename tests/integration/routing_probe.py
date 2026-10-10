#!/usr/bin/env python3
"""Isolated real-kernel routing probe. No subscriptions, credentials or TUN.

python3 tests/integration/routing_probe.py --kernel /path/to/mihomo \
    --group fallback --output /tmp/fallback-result.json

Exit 1 means the observed behavior violates a routing requirement. The report
distinguishes connection-establishment retry from health-check recovery. This
does not reproduce an authenticated AI request or diagnose its timeout cause.
"""

import argparse
import contextlib
import json
import select
import socket
import socketserver
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def read_headers(conn):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            raise EOFError("connection ended before complete response headers")
        data += chunk
        if len(data) > 65536:
            raise ValueError("fixture headers too large")
    return data.split(b"\r\n\r\n", 1)


def free_port():
    with socket.socket() as conn:
        conn.bind(("127.0.0.1", 0))
        return conn.getsockname()[1]


class Origin(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_HEAD(self):
        if self.path != "/health":
            self.send_error(404)
            return
        time.sleep(0.01)
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        if self.path == "/health":
            # The controller treats a measured delay of 0 ms as a failed test.
            time.sleep(0.01)
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif self.path == "/once":
            self.send_response(200)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"ok")
        elif self.path == "/stream":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            try:
                while not self.server.finished.is_set():
                    if not self.server.paused.is_set():
                        self.wfile.write(b"data: fixture\n\n")
                        self.wfile.flush()
                    time.sleep(0.05)
            except (BrokenPipeError, ConnectionResetError):
                pass
        else:
            self.send_error(404)


class ProxyHandler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(3)
        try:
            header, tail = read_headers(self.request)
            method, target, _ = header.split(b"\r\n", 1)[0].split(b" ", 2)
            target_port = int(target.rsplit(b":", 1)[1])
            with self.server.lock:
                self.server.attempts.append(target.decode())
            if self.server.reject.is_set() and (self.server.failure_scope == "all" or target_port == self.server.stream_port):
                self.request.sendall(b"HTTP/1.1 502 Fixture rejected\r\nContent-Length: 0\r\n\r\n")
                return
            if method != b"CONNECT":
                raise ValueError("expected outbound HTTP CONNECT")
            # Only forward to our two fixtures, even when mihomo resolves the
            # synthetic host before sending CONNECT to this proxy.
            destination = self.server.origins.get(target_port)
            if destination is None:
                with self.server.lock:
                    self.server.blocked_probe_targets.append(target.decode())
                self.request.sendall(b"HTTP/1.1 502 Outside fixture scope\r\nContent-Length: 0\r\n\r\n")
                return
            if self.server.stall.is_set() and target_port == self.server.stream_port:
                self.server.finished.wait(timeout=5)
                return
            with socket.create_connection(destination, timeout=3) as upstream:
                self.request.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
                if tail:
                    upstream.sendall(tail)
                self.request.settimeout(None)
                upstream.settimeout(None)
                while not self.server.finished.is_set():
                    readable, _, _ = select.select([self.request, upstream], [], [], 0.1)
                    for source in readable:
                        chunk = source.recv(65536)
                        if not chunk:
                            return
                        (upstream if source is self.request else self.request).sendall(chunk)
        except (OSError, EOFError, ValueError) as error:
            with self.server.lock:
                self.server.errors.append(type(error).__name__)


class FixtureProxy(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, origin, health_origin):
        super().__init__(("127.0.0.1", 0), ProxyHandler)
        self.stream_port = origin[1]
        self.origins = {origin[1]: origin, health_origin[1]: health_origin}
        self.reject = threading.Event()
        self.stall = threading.Event()
        self.failure_scope = "all"
        self.finished = threading.Event()
        self.lock = threading.Lock()
        self.attempts = []
        self.errors = []
        self.blocked_probe_targets = []


@contextlib.contextmanager
def serving(server):
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.finished.set()
        server.shutdown()
        server.server_close()
        thread.join(timeout=1)


class Stream:
    def __init__(self, port, origin_port):
        self.conn = socket.create_connection(("127.0.0.1", port), timeout=3)
        self.source_port = self.conn.getsockname()[1]
        try:
            self.conn.sendall(f"CONNECT stream.test:{origin_port} HTTP/1.1\r\nHost: stream.test:{origin_port}\r\n\r\n".encode())
            header, _ = read_headers(self.conn)
            if b" 200 " not in header.split(b"\r\n", 1)[0]:
                raise ValueError(header.split(b"\r\n", 1)[0].decode())
            self.conn.sendall(b"GET /stream HTTP/1.1\r\nHost: stream.test\r\n\r\n")
            header, tail = read_headers(self.conn)
            if b" 200 " not in header.split(b"\r\n", 1)[0]:
                raise ValueError(header.split(b"\r\n", 1)[0].decode())
        except Exception:
            self.conn.close()
            raise
        self.bytes = len(tail)
        self.closed = threading.Event()
        self.error = None
        self.conn.settimeout(None)
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()

    def read(self):
        try:
            while True:
                chunk = self.conn.recv(4096)
                if not chunk:
                    break
                self.bytes += len(chunk)
        except OSError as error:
            self.error = type(error).__name__
        finally:
            self.closed.set()

    def progressing(self, seconds=0.3):
        before = self.bytes
        time.sleep(seconds)
        return not self.closed.is_set() and self.bytes > before

    def close(self):
        with contextlib.suppress(OSError):
            self.conn.shutdown(socket.SHUT_RDWR)
        self.conn.close()
        self.reader.join(timeout=1)


class Kernel:
    def __init__(self, binary, group, directory, origin, health_origin, nodes, max_failed_times, group_options=None):
        self.port = free_port()
        self.api_port = free_port()
        self.origin_port = origin.server_address[1]
        self.health_port = health_origin.server_address[1]
        self.http = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        self.version = subprocess.check_output([binary, "-v"], text=True).strip()
        health = f"http://health.test:{self.health_port}/health"
        group_config = {"name": "TEST", "type": group, "proxies": list(nodes)}
        if group != "select":
            group_config.update(url=health, interval=3600, lazy=False, timeout=1000, **{"max-failed-times": max_failed_times, "expected-status": "204"})
        if group == "smart":
            group_config.update(uselightgbm=False, collectdata=False)
        if group == "adaptive":
            group_config.update({"failure-cooldown": 1000, "max-attempts": 3, "dial-budget": 3000, "attempt-timeout": 1000})
        group_config.update(group_options or {})
        config = {
            "mixed-port": self.port,
            "bind-address": "127.0.0.1",
            "allow-lan": False,
            "external-controller": f"127.0.0.1:{self.api_port}",
            "mode": "rule",
            "log-level": "debug",
            "ipv6": False,
            "tun": {"enable": False},
            "dns": {"enable": False},
            "hosts": {"stream.test": "127.0.0.1", "health.test": "127.0.0.1"},
            "profile": {"store-selected": False, "store-fake-ip": False},
            "proxies": [{"name": name, "type": "http", "server": "127.0.0.1", "port": node.server_address[1]} for name, node in nodes.items()],
            "proxy-groups": [group_config],
            "rules": ["MATCH,TEST"],
        }
        # JSON is a YAML subset accepted by mihomo; no YAML dependency needed.
        self.config_path = directory / "config.json"
        self.config_path.write_text(json.dumps(config))
        self.log_path = directory / "kernel.log"
        self.log = self.log_path.open("w")
        self.process = subprocess.Popen([binary, "-d", str(directory), "-f", str(self.config_path)], stdout=self.log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 8
            while True:
                if self.process.poll() is not None:
                    raise RuntimeError("kernel exited: " + self.log_path.read_text())
                try:
                    self.api("/version")
                    configured = self.api("/proxies/TEST")
                    if set(configured.get("all", [])) != set(nodes):
                        raise OSError("fixture group has not loaded yet")
                    break
                except (OSError, urllib.error.URLError):
                    if time.monotonic() >= deadline:
                        raise TimeoutError("kernel API did not become ready")
                    time.sleep(0.05)
        except Exception:
            self.stop()
            raise

    def api(self, path, method="GET", data=None):
        payload = None if data is None else json.dumps(data).encode()
        req = urllib.request.Request(f"http://127.0.0.1:{self.api_port}{path}", data=payload, method=method, headers={"Content-Type": "application/json"})
        with self.http.open(req, timeout=3) as response:
            body = response.read()
            return json.loads(body) if body else None

    def connections(self):
        return [conn for conn in (self.api("/connections")["connections"] or []) if conn["metadata"].get("host") == "stream.test"]

    def wait_connections(self, count):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            conns = self.connections()
            if len(conns) == count:
                return conns
            time.sleep(0.05)
        raise AssertionError(f"expected {count} fixture connections, got {len(self.connections())}")

    def stream(self):
        return Stream(self.port, self.origin_port)

    def probe(self, name):
        url = urllib.parse.quote(f"http://health.test:{self.health_port}/health", safe="")
        try:
            return self.api(f"/proxies/{name}/delay?url={url}&timeout=1000&expected=204")
        except urllib.error.HTTPError as error:
            return {"error_status": error.code, "message": error.read().decode()}

    def stop(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=3)
        self.log.close()


def run(binary, group, keep_dir=None, max_failed_times=5, failure_scope="all"):
    with contextlib.ExitStack() as stack:
        if keep_dir:
            directory = Path(keep_dir).resolve()
            directory.mkdir(parents=True, exist_ok=False)
        else:
            directory = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix="mihomo-routing-probe-")))
        origin = ThreadingHTTPServer(("127.0.0.1", 0), Origin)
        origin.daemon_threads = True
        origin.finished = threading.Event()
        origin.paused = threading.Event()
        stack.enter_context(serving(origin))
        health_origin = ThreadingHTTPServer(("127.0.0.1", 0), Origin)
        health_origin.daemon_threads = True
        health_origin.finished = threading.Event()
        health_origin.paused = threading.Event()
        stack.enter_context(serving(health_origin))
        nodes = {name: stack.enter_context(serving(FixtureProxy(origin.server_address, health_origin.server_address))) for name in ["nodeA", "nodeB"]}
        kernel = Kernel(binary, group, directory, origin, health_origin, nodes, max_failed_times)
        stack.callback(kernel.stop)
        report = {"version": kernel.version, "group": group, "max_failed_times": max_failed_times, "failure_scope": failure_scope, "checks": {}, "observations": {}, "scope": "local HTTP CONNECT + TCP stream; no real AI requests"}
        if group == "select":
            kernel.api("/proxies/TEST", "PUT", {"name": "nodeA"})
        else:
            for name in nodes:
                health = kernel.probe(name)
                if "delay" not in health:
                    raise AssertionError(f"fixture health check failed for {name}: {health}")
        first = kernel.stream()
        stack.callback(first.close)
        old = kernel.wait_connections(1)[0]
        report["checks"]["baseline_stream_progresses"] = first.progressing()
        selected = next(name for name in nodes if name in old["chains"])
        other = next(name for name in nodes if name != selected)
        report["observations"]["initial_node"] = selected
        if group == "select":
            origin.paused.set()
            time.sleep(0.35)
            report["checks"]["healthy_stream_survives_brief_idle"] = not first.closed.is_set()
            origin.paused.clear()
            report["checks"]["stream_resumes_after_idle"] = first.progressing()
            kernel.api("/proxies/TEST", "PUT", {"name": other})
            second = kernel.stream()
            stack.callback(second.close)
            current = kernel.wait_connections(2)
            new = next(conn for conn in current if conn["id"] != old["id"])
            report["checks"]["new_connection_uses_other_node"] = other in new["chains"]
            report["checks"]["healthy_stream_survives_switch"] = first.progressing()
            kernel.api(f"/connections/{old['id']}", "DELETE")
            report["checks"]["negative_control_detects_explicit_close"] = first.closed.wait(timeout=2)
        else:
            def target_attempts(node):
                with node.lock:
                    return sum(target.endswith(f":{kernel.origin_port}") for target in node.attempts)

            before_attempts = {name: target_attempts(node) for name, node in nodes.items()}
            nodes[selected].failure_scope = failure_scope
            nodes[selected].reject.set()
            started = time.monotonic()
            second = None
            try:
                second = kernel.stream()
                stack.callback(second.close)
                recovered = second.progressing()
                error = None
            except (OSError, EOFError, ValueError) as failure:
                recovered = False
                error = f"{type(failure).__name__}: {failure}"
            report["checks"]["failed_establishment_retries_and_recovers"] = recovered
            report["checks"]["healthy_stream_survives_other_dial_failure"] = first.progressing()
            report["observations"].update(establishment_seconds=round(time.monotonic() - started, 3), establishment_error=error,
                dial_attempts={name: target_attempts(node) - before_attempts[name] for name, node in nodes.items()},
                first_connection_still_in_api=any(conn["id"] == old["id"] for conn in kernel.connections()))
            if report["observations"]["dial_attempts"][selected] == 0:
                raise AssertionError("failure injection was not exercised; result is inconclusive")
            if group == "fallback":
                report["observations"]["forced_health_check"] = kernel.probe(selected)
                try:
                    later = kernel.stream()
                    stack.callback(later.close)
                    report["checks"]["new_connection_recovers_after_health_check"] = later.progressing()
                except (OSError, EOFError, ValueError) as failure:
                    report["checks"]["new_connection_recovers_after_health_check"] = False
                    report["observations"]["later_error"] = str(failure)
            elif group == "adaptive" and second is not None:
                target = f"stream.test:{kernel.origin_port}"
                quality = kernel.api("/proxies/TEST/quality")
                failures = [event for event in quality["events"] if event["kind"] == "dial-failed" and event["target"] == target]
                report["checks"]["failed_dial_observable_for_original_target"] = any(event["node"] == selected for event in failures)
                report["checks"]["candidate_not_repeated_in_establishment"] = report["observations"]["dial_attempts"] == {selected: 1, other: 1}
                nodes[selected].reject.clear()
                # Allow A's temporary penalty to expire before feedback on B.
                time.sleep(1.1)
                origin.paused.set()
                time.sleep(0.35)
                report["checks"]["healthy_stream_survives_brief_idle"] = not first.closed.is_set() and not second.closed.is_set()
                origin.paused.clear()
                report["checks"]["streams_resume_after_idle"] = first.progressing() and second.progressing()
                kernel.api("/proxies/TEST/feedback", "POST", {"target": target, "reason": "timeout"})
                third = kernel.stream()
                stack.callback(third.close)
                current = kernel.wait_connections(3)
                new = next(conn for conn in current if int(conn["metadata"]["sourcePort"]) == third.source_port)
                report["checks"]["feedback_changes_next_route"] = selected in new["chains"] and third.progressing()
                report["checks"]["feedback_preserves_healthy_siblings"] = first.progressing() and second.progressing()
                kernel.api(f"/connections/{old['id']}", "DELETE")
                report["checks"]["negative_control_detects_explicit_close"] = first.closed.wait(timeout=2)
                quality = kernel.api("/proxies/TEST/quality")
                closed = [event for event in quality["events"] if event["kind"] == "closed" and event["target"] == target]
                report["checks"]["closed_lifecycle_observable"] = any(event["readBytes"] > 0 and event["writtenBytes"] > 0 for event in closed)
                report["observations"]["quality_event_kinds"] = [event["kind"] for event in quality["events"]]
            elif group == "smart" and second is not None:
                # Restore both nodes, then examine target-feedback collateral damage.
                nodes[selected].reject.clear()
                kernel.probe(selected)
                if first.closed.is_set():
                    first = kernel.stream()
                    stack.callback(first.close)
                time.sleep(0.1)
                siblings = kernel.connections()
                if len(siblings) >= 2 and first.progressing() and second.progressing():
                    feedback_id = next(conn["id"] for conn in siblings if int(conn["metadata"]["sourcePort"]) == second.source_port)
                    report["observations"]["feedback_connection_id"] = feedback_id
                    kernel.api(f"/connections/smart/{feedback_id}", "DELETE")
                    other_progresses = first.progressing(seconds=0.4)
                    remaining = kernel.connections()
                    report["observations"]["connections_after_feedback"] = len(remaining)
                    report["checks"]["feedback_preserves_other_healthy_connection"] = other_progresses
                else:
                    report["observations"]["feedback_check"] = "not evaluated: two healthy siblings were unavailable"
        report["observations"]["fixture_errors"] = {name: node.errors for name, node in nodes.items()}
        report["observations"]["blocked_probe_targets"] = {name: node.blocked_probe_targets for name, node in nodes.items()}
        if keep_dir:
            report["log_path"] = str(kernel.log_path)
        return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kernel", required=True)
    parser.add_argument("--group", choices=["select", "fallback", "smart", "adaptive"], required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--keep-dir", help="fresh directory for fixture config and kernel log")
    parser.add_argument("--max-failed-times", type=int, default=5)
    parser.add_argument("--failure-scope", choices=["all", "target"], default="all", help="reject all new tunnels, or only stream.test while health.test stays healthy")
    args = parser.parse_args()
    report = run(str(Path(args.kernel).resolve()), args.group, args.keep_dir, args.max_failed_times, args.failure_scope)
    formatted = json.dumps(report, indent=2, ensure_ascii=False)
    print(formatted)
    if args.output:
        args.output.write_text(formatted + "\n")
    return 0 if all(report["checks"].values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
