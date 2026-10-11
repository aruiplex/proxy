"""Use real listening sockets to reject a competing process during acceptance."""
import importlib.util
import os
import socket
import subprocess
import sys
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location('live_tls_acceptance', Path(__file__).resolve().parents[1] / 'integration/live_tls_acceptance.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


@unittest.skipUnless(Path('/proc/net/tcp').exists(), 'Linux listener ownership check')
class ListenerOwnershipTest(unittest.TestCase):
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
