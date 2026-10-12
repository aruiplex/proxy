"""Supervisor ownership and reentrancy are boundaries of the CLI lifecycle."""
import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('systemd_service', Path(__file__).resolve().parents[2] / 'libexec/systemd_service.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SupervisorOwnership(unittest.TestCase):
    def test_failed_supervised_start_never_falls_back_to_another_core(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            command = root / 'systemctl'
            command.write_text('#!/bin/sh\nif [ "$2" = show ]; then\n'
                'printf "LoadState=loaded\\nPIDFile=%s/mihomo.pid\\nControlGroup=/fixture/proxy-mihomo.service\\n" "$CONF_DIR"\n'
                'else\nexit 1\nfi\n')
            command.chmod(0o700)
            core = root / 'mihomo'
            core.write_text('#!/bin/sh\ntouch "$CONF_DIR/accidentally-started"\n')
            core.chmod(0o700)
            (root / 'proxy.conf').write_text(f'bin={core}\n')
            repo = Path(__file__).resolve().parents[2]
            result = subprocess.run(['bash', str(repo / 'proxy'), 'start'],
                env=dict(os.environ, CONF_DIR=str(root), PATH=str(root) + ':' + os.environ['PATH']),
                capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('systemd 操作失败', result.stderr)
            self.assertFalse((root / 'accidentally-started').exists())

    def metadata(self, root):
        return subprocess.CompletedProcess([], 0,
            f'LoadState=loaded\nPIDFile={root}/mihomo.pid\nControlGroup=/app.slice/proxy-mihomo.service\n', '')

    def test_worker_does_not_wait_on_its_own_start_job(self):
        root = Path('/tmp/fixture-home')
        with patch.object(MODULE.subprocess, 'run', return_value=self.metadata(root)):
            self.assertIsNone(MODULE.owned_unit(root, 'systemctl', '0::/app.slice/proxy-mihomo.service\n'))
            self.assertIsNone(MODULE.owned_unit(root, 'systemctl', '0::/app.slice/proxy-mihomo.service/child\n'))
            self.assertEqual(MODULE.owned_unit(root, 'systemctl', '0::/session.scope\n'), MODULE.UNIT)

    def test_other_configuration_is_never_delegated_to_foreign_unit(self):
        with tempfile.TemporaryDirectory() as home:
            root = Path(home) / 'our-home'
            root.mkdir()
            alias = Path(home) / 'alias'
            alias.symlink_to(root, target_is_directory=True)
            with patch.object(MODULE.subprocess, 'run', return_value=self.metadata(alias)):
                self.assertEqual(MODULE.owned_unit(root, 'systemctl', '0::/session.scope\n'), MODULE.UNIT)
            with patch.object(MODULE.subprocess, 'run', return_value=self.metadata(Path(home) / 'other-home')):
                self.assertIsNone(MODULE.owned_unit(root, 'systemctl', '0::/session.scope\n'))

    def test_unreachable_installed_supervisor_is_not_bypassed(self):
        with tempfile.TemporaryDirectory() as home:
            unit = Path(home) / '.config/systemd/user' / MODULE.UNIT
            unit.parent.mkdir(parents=True)
            unit.touch()
            failed = subprocess.CompletedProcess([], 1, '', 'manager unavailable')
            with patch.object(MODULE.Path, 'home', return_value=Path(home)), patch.object(MODULE.subprocess, 'run', return_value=failed):
                with self.assertRaises(RuntimeError):
                    MODULE.owned_unit(Path(home) / 'core', 'systemctl', '0::/session.scope\n')


if __name__ == '__main__':
    unittest.main()
