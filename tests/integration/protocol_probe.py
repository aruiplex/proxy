#!/usr/bin/env python3
"""Two real cores, loopback-only protocol servers, authenticated TLS fixtures.

No subscription, account credentials or AI-service traffic. Fault injection
stops only new node accepts, or rejects a deferred WebSocket handshake.
"""
import argparse
import contextlib
import hashlib
import json
import select
import shutil
import socket
import socketserver
import ssl
import struct
import subprocess
import tempfile
import threading
import time
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

from routing_probe import Kernel, Origin, Stream, free_port, read_headers, serving

UUID = "d55c4176-d6cb-4d72-a1b3-993e4a207c8d"  # public fixture identity
PROTOCOLS = ["ss", "vmess", "vmess-tls", "vless", "vless-tls", "trojan", "vmess-ws-early", "vless-ws-early"]


class CountingOrigin(Origin):
    def handle(self):
        try:
            super().handle()
        except (ssl.SSLError, BrokenPipeError, ConnectionResetError):
            # Intentional response loss and fixture shutdown can truncate TLS.
            with self.server.lock:
                self.server.disconnects += 1

    def do_POST(self):
        if self.path != "/commit":
            self.send_error(404)
            return
        body = self.rfile.read(int(self.headers["Content-Length"]))
        with self.server.lock:
            self.server.commits.append(body.decode())
        # Business operation is already recorded. Drop the response so that a
        # caller cannot know its outcome; the proxy must not replay the POST.
        self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        self.close_connection = True


def origin(stack, tls_context=None):
    server = ThreadingHTTPServer(("127.0.0.1", 0), CountingOrigin)
    server.daemon_threads = True
    server.finished = threading.Event()
    server.paused = threading.Event()
    server.lock = threading.Lock()
    server.commits = []
    server.disconnects = 0
    if tls_context:
        server.socket = tls_context.wrap_socket(server.socket, server_side=True)
    return stack.enter_context(serving(server))


class GateHandler(socketserver.BaseRequestHandler):
    def handle(self):
        with self.server.lock:
            self.server.accepts += 1
        if self.server.reject_ws.is_set():
            with contextlib.suppress(OSError, EOFError, ValueError):
                self.request.settimeout(2)
                read_headers(self.request)
                with self.server.lock:
                    self.server.rejected_handshakes += 1
                self.request.sendall(b"HTTP/1.1 502 Fixture handshake rejected\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        with contextlib.suppress(OSError):
            with socket.create_connection(self.server.backend, timeout=2) as backend:
                self.request.settimeout(None)
                backend.settimeout(None)
                while not self.server.finished.is_set():
                    readable, _, _ = select.select([self.request, backend], [], [], 0.05)
                    for source in readable:
                        data = source.recv(65536)
                        if not data:
                            return
                        (backend if source is self.request else self.request).sendall(data)


class Gate(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, backend, port=0):
        super().__init__(("127.0.0.1", port), GateHandler)
        self.backend = backend
        self.finished = threading.Event()
        self.reject_ws = threading.Event()
        self.lock = threading.Lock()
        self.accepts = 0
        self.rejected_handshakes = 0

    def stop_accepts(self):
        # Keep accepted sockets and their relay loops alive.
        self.shutdown()
        self.server_close()


class ServerCore:
    def __init__(self, binary, directory, listener, ports, hosts):
        directory.mkdir()
        self.api_port = free_port()
        config = {
            "external-controller": f"127.0.0.1:{self.api_port}",
            "log-level": "debug", "ipv6": False,
            "tun": {"enable": False}, "dns": {"enable": False},
            "hosts": hosts, "listeners": [listener],
            # No server fixture can forward beyond our loopback origin ports.
            "rules": [f"AND,((IP-CIDR,127.0.0.1/32,no-resolve),(DST-PORT,{port})),DIRECT" for port in ports] + ["MATCH,REJECT"],
        }
        path = directory / "config.json"
        path.write_text(json.dumps(config))
        self.log_path = directory / "server.log"
        self.log = self.log_path.open("w")
        self.process = subprocess.Popen([binary, "-d", str(directory), "-f", str(path)], stdout=self.log, stderr=subprocess.STDOUT)
        self.http = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        try:
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                if self.process.poll() is not None:
                    raise RuntimeError(self.log_path.read_text())
                try:
                    self.api("/version")
                    with socket.create_connection(("127.0.0.1", listener["port"]), timeout=0.2):
                        break
                except OSError:
                    time.sleep(0.05)
            else:
                raise TimeoutError("protocol server did not start: " + self.log_path.read_text())
        except Exception:
            self.stop()
            raise

    def api(self, path):
        with self.http.open(f"http://127.0.0.1:{self.api_port}{path}", timeout=2) as response:
            return json.load(response)

    def stop(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=3)
        self.log.close()


def protocol_options(protocol, backend_port, cert, key, fingerprint):
    base = {"name": "fixture", "listen": "127.0.0.1", "port": backend_port}
    outbound = {"server": "127.0.0.1"}
    if protocol == "ss":
        base.update(type="shadowsocks", cipher="aes-128-gcm", password=UUID, udp=False)
        outbound.update(type="ss", cipher="aes-128-gcm", password=UUID)
    elif protocol == "trojan":
        base.update(type="trojan", users=[{"username": "fixture", "password": UUID}], certificate=cert.read_text(), **{"private-key": key.read_text()})
        outbound.update(type="trojan", password=UUID, sni="fixture.test", fingerprint=fingerprint)
    else:
        kind = protocol.split("-", 1)[0]
        base.update(type=kind, users=[{"username": "fixture", "uuid": UUID}])
        outbound.update(type=kind, uuid=UUID)
        if kind == "vless" and "tls" not in protocol:
            base["allow-insecure"] = True  # loopback test transport only
        if "tls" in protocol:
            base.update(certificate=cert.read_text(), **{"private-key": key.read_text()})
            outbound.update(tls=True, servername="fixture.test", fingerprint=fingerprint)
        if kind == "vmess":
            outbound.update(cipher="auto", alterId=0)
        if "ws" in protocol:
            base.update({"ws-path": "/ws"})
            outbound.update(network="ws", **{"ws-opts": {"path": "/ws", "max-early-data": 2048, "early-data-header-name": "Sec-WebSocket-Protocol"}})
    return base, outbound


def certificate(directory):
    executable = shutil.which("openssl")
    if executable is None:
        raise RuntimeError("openssl is required for temporary fixture certificates")
    cert, key = directory / "cert.pem", directory / "key.pem"
    subprocess.run([executable, "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes", "-days", "1", "-subj", "/CN=fixture.test", "-addext", "subjectAltName=DNS:fixture.test,DNS:stream.test,IP:127.0.0.1", "-keyout", str(key), "-out", str(cert)], check=True, capture_output=True)
    server = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server.load_cert_chain(cert, key)
    client = ssl.create_default_context(cafile=str(cert))
    fingerprint = hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert.read_text())).hexdigest()
    return cert, key, server, client, fingerprint


def post_once(kernel, port, tls_context, token):
    with socket.create_connection(("127.0.0.1", kernel.port), timeout=3) as raw:
        raw.sendall(f"CONNECT stream.test:{port} HTTP/1.1\r\nHost: stream.test:{port}\r\n\r\n".encode())
        header, _ = read_headers(raw)
        if b" 200 " not in header.split(b"\r\n", 1)[0]:
            raise AssertionError("proxy CONNECT failed before business request")
        with tls_context.wrap_socket(raw, server_hostname="stream.test") as conn:
            conn.sendall(f"POST /commit HTTP/1.1\r\nHost: stream.test\r\nContent-Length: {len(token)}\r\n\r\n{token}".encode())
            with contextlib.suppress(OSError):
                conn.recv(1)


def post_plain_once(kernel, port, token):
    with socket.create_connection(("127.0.0.1",kernel.port),timeout=3) as conn:
        # Coalesce the first business request with CONNECT so it is already in
        # the inbound peek buffer when the selected outbound begins its dial.
        conn.sendall((f"CONNECT stream.test:{port} HTTP/1.1\r\nHost: stream.test:{port}\r\n\r\n"
            f"POST /commit HTTP/1.1\r\nHost: stream.test\r\nContent-Length: {len(token)}\r\n\r\n{token}").encode())
        header,_=read_headers(conn)
        if b" 200 " not in header.split(b"\r\n",1)[0]:
            raise AssertionError("coalesced request CONNECT failed")
        with contextlib.suppress(OSError):
            conn.recv(1)


def check_protocol(binary, server_binary, protocol, failure_mode, keep_dir=None):
    with contextlib.ExitStack() as stack:
        if keep_dir:
            directory = Path(keep_dir).absolute()
            directory.mkdir(parents=True, exist_ok=False)
        else:
            directory = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix="adaptive-protocol-")))
        cert, key, tls_server, tls_client, fingerprint = certificate(directory)
        plain = origin(stack)
        health = origin(stack)
        encrypted = origin(stack, tls_server)
        ports = [o.server_address[1] for o in [plain, health, encrypted]]
        hosts = {"stream.test": "127.0.0.1", "health.test": "127.0.0.1"}
        nodes, proxies = {}, []
        for name in ["nodeA", "nodeB"]:
            backend_port = free_port()
            listener, outbound = protocol_options(protocol, backend_port, cert, key, fingerprint)
            server = ServerCore(server_binary, directory / name, listener, ports, hosts)
            stack.callback(server.stop)
            gate = stack.enter_context(serving(Gate(("127.0.0.1", backend_port))))
            nodes[name] = gate
            proxies.append(dict(outbound, name=name, port=gate.server_address[1]))
        client_dir = directory / "client"
        client_dir.mkdir()
        kernel = Kernel(binary, "adaptive", client_dir, plain, health, nodes, 5, {"failure-cooldown": 1000}, proxies)
        stack.callback(kernel.stop)
        for name in nodes:
            if "delay" not in kernel.probe(name):
                raise AssertionError(f"{protocol} fixture health check failed for {name}")
        first = Stream(kernel.port, encrypted.server_address[1], tls_client)
        stack.callback(first.close)
        old = kernel.wait_connections(1)[0]
        if "nodeA" not in old["chains"]:
            raise AssertionError("fault target nodeA was not selected")
        before = kernel.api("/proxies/TEST/quality")
        if failure_mode == "refuse":
            nodes["nodeA"].stop_accepts()
        else:
            nodes["nodeA"].reject_ws.set()
        second = Stream(kernel.port, encrypted.server_address[1], tls_client)
        stack.callback(second.close)
        current = kernel.wait_connections(2)
        new = next(conn for conn in current if conn["id"] != old["id"])
        target = f"stream.test:{encrypted.server_address[1]}"
        quality = kernel.api("/proxies/TEST/quality")
        failure_events = [e for e in quality["events"][len(before["events"]):] if e["kind"] == "dial-failed" and e["target"] == target]
        checks = {
            "tls_stream_uses_verified_fixture_certificate": first.progressing() and second.progressing(),
            "failed_establishment_uses_backup": "nodeB" in new["chains"],
            "healthy_tls_stream_survives_failure": first.progressing(),
            "failed_route_observed_once": len(failure_events) == 1 and failure_events[0]["node"] == "nodeA",
        }
        if failure_mode == "ws-reject":
            checks["deferred_handshake_failed_before_payload"] = failure_events[0]["reason"] == "handshake-error" and nodes["nodeA"].rejected_handshakes == 1
            nodes["nodeA"].reject_ws.clear()
        else:
            # Reopen the same port without touching existing accepted sockets.
            stack.enter_context(serving(Gate(nodes["nodeA"].backend, nodes["nodeA"].server_address[1])))
        time.sleep(1.1)
        kernel.api("/proxies/TEST/feedback", "POST", {"target": target, "reason": "timeout"})
        third = Stream(kernel.port, encrypted.server_address[1], tls_client)
        stack.callback(third.close)
        current = kernel.wait_connections(3)
        fresh = next(conn for conn in current if int(conn["metadata"]["sourcePort"]) == third.source_port)
        checks["feedback_changes_next_tls_route"] = "nodeA" in fresh["chains"] and third.progressing()
        checks["feedback_keeps_both_healthy_tls_streams"] = first.progressing() and second.progressing()
        post_once(kernel, encrypted.server_address[1], tls_client, "committed-once")
        post_plain_once(kernel, plain.server_address[1], "coalesced-once")
        time.sleep(0.2)
        checks["first_packet_business_operation_not_replayed"] = plain.commits == ["coalesced-once"]
        checks["business_operation_not_replayed_after_response_loss"] = encrypted.commits == ["committed-once"]
        checks["business_failure_preserves_healthy_tls_streams"] = first.progressing() and second.progressing() and third.progressing()
        report = {"version": kernel.version, "protocol": protocol, "failure_mode": failure_mode, "checks": checks, "observations": {"failure_reasons": [e["reason"] for e in failure_events], "commits_after_response_loss": len(encrypted.commits), "first_packet_commits": len(plain.commits), "tls_version": first.conn.version()}, "scope": "loopback two-core protocol fixture + certificate-verified TLS origin; no real AI service"}
        if keep_dir:
            report["logs"] = str(directory)
        return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kernel", required=True)
    parser.add_argument("--server-kernel", required=True, help="official kernel for independent protocol servers")
    parser.add_argument("--protocol", choices=PROTOCOLS, required=True)
    parser.add_argument("--failure-mode", choices=["refuse", "ws-reject"], default="refuse")
    parser.add_argument("--keep-dir")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.failure_mode == "ws-reject" and "ws" not in args.protocol:
        parser.error("ws-reject requires a WebSocket protocol")
    report = check_protocol(str(Path(args.kernel).resolve()), str(Path(args.server_kernel).resolve()), args.protocol, args.failure_mode, args.keep_dir)
    formatted = json.dumps(report, indent=2)
    print(formatted)
    if args.output:
        args.output.write_text(formatted + "\n")
    return 0 if all(report["checks"].values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
