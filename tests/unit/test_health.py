import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('health', Path(__file__).resolve().parents[2] / 'libexec/health.py')
health = importlib.util.module_from_spec(spec); spec.loader.exec_module(health)

class HealthEvidence(unittest.TestCase):
    def sample(self, failures=(), **extra):
        return dict(process_alive=True, controller_ok=True,
                    probes={name: {'passed': name not in failures} for name in ['chatgpt','google','gemini']}, **extra)

    def test_active_core_with_persistent_timeout_notifies_once_and_recovers(self):
        state = None
        for i in range(3):
            state = health.evaluate(self.sample(['chatgpt']), state)
            self.assertEqual(state['notification'] is not None, i == 2)
        self.assertEqual(state['confirmed'], 'target_failure:chatgpt')
        state = health.evaluate(self.sample(['chatgpt']), state)
        self.assertIsNone(state['notification'])
        state = health.evaluate(self.sample(), state)
        self.assertIsNone(state['notification'])
        state = health.evaluate(self.sample(), state)
        self.assertEqual(state['notification']['to'], 'healthy')

    def test_other_targets_do_not_reset_persistent_target_timeout(self):
        state = None
        for failures in [('chatgpt',), ('chatgpt','gemini'), ('chatgpt',)]:
            state = health.evaluate(self.sample(failures), state)
        self.assertEqual(state['confirmed'], 'target_failure:chatgpt')

    def test_probe_failure_is_not_a_core_failure_and_global_failure_is_qualified(self):
        self.assertEqual(health.evaluate({'probe_error':'FileNotFoundError'})['observed'], 'monitor_error')
        self.assertEqual(health.evaluate({'process_alive':False})['observed'], 'process_unavailable')
        self.assertEqual(health.evaluate({'process_alive':True, 'controller_ok':False})['observed'], 'controller_unavailable')
        self.assertEqual(health.evaluate(self.sample(['chatgpt','google','gemini'], direct_controls_ok=False))['observed'], 'network_or_all_routes_failure')
        self.assertEqual(health.evaluate(self.sample(['chatgpt','google','gemini'], direct_controls_ok=True))['observed'], 'all_proxy_targets_failure')

    def test_live_append_fd_continues_after_rotation_and_archive_is_private(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); log=root/'mihomo.log'; log.write_bytes(b'before\n')
            with log.open('ab', buffering=0) as writer:
                inode=log.stat().st_ino
                self.assertTrue(health.rotate(root, max_bytes=1)['rotated'])
                writer.write(b'after\n')
            self.assertEqual(log.stat().st_ino, inode)
            self.assertEqual(log.read_bytes(), b'after\n')
            archives=list((root/'logs').glob('*.log'))
            self.assertEqual(archives[0].read_bytes(), b'before\n')
            self.assertEqual(archives[0].stat().st_mode & 0o777, 0o600)

    def test_failed_archive_never_truncates_live_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); log=root/'mihomo.log'; log.write_bytes(b'before\n')
            # Invalid archive path reaches the real filesystem failure seam.
            (root/'logs').write_text('blocked')
            with self.assertRaises(OSError): health.rotate(root, max_bytes=1)
            self.assertEqual(log.read_bytes(), b'before\n')

if __name__ == '__main__': unittest.main()
