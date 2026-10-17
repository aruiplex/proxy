"""Use real listening sockets to reject a competing process during acceptance."""
import importlib.util
import os
import socket
import subprocess
import sys
import unittest
import tempfile
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('live_tls_acceptance', Path(__file__).resolve().parents[1] / 'integration/live_tls_acceptance.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
import core_health


@unittest.skipUnless(Path('/proc/net/tcp').exists(), 'Linux listener ownership check')
class ListenerOwnershipTest(unittest.TestCase):
    def service_fixture(self, directory, members=None):
        root = Path(directory);pid = os.getpid();uid = os.getuid()
        proc = root / 'proc';(proc / str(pid)).mkdir(parents=True)
        group = '/system.slice/proxy-mihomo-%d.service' % uid
        (proc / str(pid) / 'cgroup').write_text('0::' + group + '\n')
        (proc / str(pid) / 'status').write_text('Uid:\t%d\t%d\t%d\t%d\n' % (uid, uid, uid, uid))
        cg = root / 'cgroup';members_file = cg / group.lstrip('/') / 'cgroup.procs'
        members_file.parent.mkdir(parents=True)
        members_file.write_text(str(pid) if members is None else members)
        return pid, uid, proc, cg, group

    def test_capability_restricted_fd_uses_exclusive_service_socket_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            pid, uid, proc, cg, group = self.service_fixture(directory)
            result = subprocess.CompletedProcess([], 0,
                'LISTEN 0 4096 *:7890 *:* uid:%d ino:42 cgroup:%s\n' % (uid, group))
            original = core_health._service_listener_ownership
            with patch.object(Path, 'iterdir', side_effect=PermissionError), \
                 patch.object(core_health.subprocess, 'run', return_value=result), \
                 patch.object(core_health, '_service_listener_ownership', side_effect=lambda p, ports: original(p, ports, proc, cg)):
                self.assertTrue(core_health.check_listener_ownership(pid, {7890}))

    def test_restricted_fd_never_accepts_foreign_or_missing_socket_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            pid, uid, proc, cg, group = self.service_fixture(directory)
            for tail in ['uid:%d cgroup:/other.service' % uid, 'uid:%d' % uid, 'cgroup:' + group]:
                result = subprocess.CompletedProcess([], 0, 'LISTEN 0 4096 *:7890 *:* ' + tail + '\n')
                with patch.object(core_health.subprocess, 'run', return_value=result), self.assertRaises(OSError):
                    core_health._service_listener_ownership(pid, {7890}, proc, cg)

    def test_service_with_another_process_cannot_claim_exact_pid_ownership(self):
        with tempfile.TemporaryDirectory() as directory:
            pid, uid, proc, cg, group = self.service_fixture(directory, str(os.getpid()) + '\n999999\n')
            with self.assertRaises(OSError):
                core_health._service_listener_ownership(pid, {7890}, proc, cg)

    def test_accepts_core_owned_listener(self):
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            listener.listen()
            self.assertTrue(MODULE.check_listener_ownership(os.getpid(), {listener.getsockname()[1]}))

    def test_rejects_reachable_listener_owned_by_competing_process(self):
        code = "import socket,time; s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen(); print(s.getsockname()[1],flush=True); time.sleep(30)"
        with subprocess.Popen([sys.executable, '-c', code], stdout=subprocess.PIPE, text=True) as competitor:
            try:
                port = int(competitor.stdout.readline())
                with socket.create_connection(('127.0.0.1', port), timeout=1):
                    pass
                with self.assertRaises(OSError):
                    MODULE.check_listener_ownership(os.getpid(), {port})
            finally:
                competitor.terminate()
                competitor.wait(timeout=3)


if __name__ == '__main__':
    unittest.main()
