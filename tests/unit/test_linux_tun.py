"""Linux TUN staging, routing preservation and supervisor identity boundaries."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'libexec'))
import systemd_service as service
import tun_config
import tun_prepare
import tun_linux
import health


class LinuxTun(unittest.TestCase):
    def test_health_reads_the_selected_system_scope_instead_of_retired_user_unit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            unit = 'proxy-mihomo-%s.service' % os.getuid()
            (root / 'supervisor.json').write_text(json.dumps({'schema': 1, 'scope': 'system', 'unit': unit}))
            responses = [subprocess.CompletedProcess([], 0, 'MainPID=123\nNRestarts=0\n'),
                         subprocess.CompletedProcess([], 0, '')]
            with patch.object(health.subprocess, 'run', side_effect=responses) as run:
                result = health.systemd(root=root)
            self.assertEqual(result['scope'], 'system')
            self.assertEqual(result['unit'], unit)
            self.assertEqual(run.call_args_list[0][0][0][1:4], ['--system', 'show', unit])
            self.assertEqual(run.call_args_list[1][0][0][1:4], ['--system', '-u', unit])

    def test_reload_that_fails_to_create_tun_restores_config_and_preferences(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = 'rules:\n  - MATCH,DIRECT\n'
            (root / 'config.yaml').write_text(original)
            settings = tun_config.defaults(os.getuid());settings['enabled'] = False
            prefs = json.dumps(settings)
            (root / 'tun.json').write_text(prefs)
            with patch.object(tun_linux, 'supervisor', return_value=('system', 'fixture.service')), \
                 patch.object(tun_linux, 'owned_unit', return_value='fixture.service'), \
                 patch.object(tun_linux.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)), \
                 patch.object(tun_linux, 'reload_config') as reload, \
                 patch.object(tun_linux, 'verify', side_effect=ValueError('TUN device missing')):
                with self.assertRaises(ValueError):
                    tun_linux.toggle(root, Path('/fixture/core'), True)
            self.assertEqual((root / 'config.yaml').read_text(), original)
            self.assertEqual((root / 'tun.json').read_text(), prefs)
            self.assertEqual(reload.call_count, 2)

    def test_rejected_candidate_does_not_reload_or_modify_live_state(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = 'rules:\n  - MATCH,DIRECT\n'
            (root / 'config.yaml').write_text(original)
            with patch.object(tun_linux, 'supervisor', return_value=('system', 'fixture.service')), \
                 patch.object(tun_linux, 'owned_unit', return_value='fixture.service'), \
                 patch.object(tun_linux.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)), \
                 patch.object(tun_linux, 'reload_config') as reload:
                with self.assertRaises(ValueError):
                    tun_linux.toggle(root, Path('/fixture/core'), True)
            reload.assert_not_called()
            self.assertEqual((root / 'config.yaml').read_text(), original)
            self.assertFalse((root / 'tun.json').exists())

    def test_overlay_preserves_node_bytes_and_routing_and_replays_idempotently(self):
        raw = '''proxies:
  - name: secret-node
    password: 'opaque: name: \\ value'
    reality-opts: {public-key: untouched, short-id: abc123}
proxy-groups:
  - {name: PROXY, type: select, proxies: [secret-node]}
rules:
  - IP-CIDR,192.168.0.0/16,DIRECT
  - MATCH,PROXY
'''
        prefs = tun_config.defaults(1000)
        result = tun_config.render(raw, prefs)
        self.assertTrue(result.startswith(raw))
        self.assertEqual(result, tun_config.render(result, prefs))
        self.assertIn('100.64.0.0/10', result)
        self.assertIn('include-uid: [1000]', result)
        prefs['enabled'] = False
        self.assertIn('enable: false', tun_config.render(result, prefs))

    def test_json_overlay_preserves_original_rules_and_explicit_sniffer(self):
        original = {'rules': ['MATCH,PROXY'], 'proxies': [{'name': 'node', 'type': 'vless', 'uuid': 'opaque'}],
                    'sniffer': {'enable': True, 'skip-domain': ['+.example.com']}}
        result = json.loads(tun_config.render(json.dumps(original), tun_config.defaults(1234)))
        for key in original:
            self.assertEqual(result[key], original[key])
        self.assertTrue(result['ipv6'])
        self.assertEqual(result['tun']['include-uid'], [1234])

    def test_duplicate_fields_rejected(self):
        for field in ['tun', 'sniffer', 'ipv6']:
            with self.assertRaises(ValueError):
                tun_config.render(field + ': true\n' + field + ': false\n', tun_config.defaults(1000))

    def test_system_supervisor_is_explicit_and_reentrant(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            unit = 'proxy-mihomo-%s.service' % os.getuid()
            (root / 'supervisor.json').write_text(json.dumps({'schema': 1, 'scope': 'system', 'unit': unit}))
            self.assertEqual(service.supervisor(root), ('system', unit))
            metadata = subprocess.CompletedProcess([], 0,
                'LoadState=loaded\nPIDFile=%s/mihomo.pid\nControlGroup=/system.slice/%s\nUser=%s\n' % (root, unit, os.getuid()))
            with patch.object(service.subprocess, 'run', return_value=metadata) as run:
                self.assertEqual(service.owned_unit(root, 'systemctl', '0::/session.scope', 'system', unit), unit)
                self.assertEqual(run.call_args[0][0][1], '--system')
                self.assertIsNone(service.owned_unit(root, 'systemctl', '0::/system.slice/' + unit, 'system', unit))

    def test_invalid_or_foreign_supervisor_cannot_fall_back(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for marker in [{}, {'schema': 1, 'scope': 'system', 'unit': 'foreign.service'}]:
                (root / 'supervisor.json').write_text(json.dumps(marker))
                with self.assertRaises(RuntimeError):
                    service.supervisor(root)
            for data in ['LoadState=not-found\n', 'LoadState=loaded\nPIDFile=/other/mihomo.pid\n',
                         'LoadState=loaded\nPIDFile=%s/mihomo.pid\nUser=root\n' % root]:
                result = subprocess.CompletedProcess([], 0, data)
                with patch.object(service.subprocess, 'run', return_value=result), self.assertRaises(RuntimeError):
                    service.owned_unit(root, 'systemctl', '', 'system', 'proxy-mihomo-1000.service')

    def test_linux_on_without_installation_does_not_modify_or_stop_anything(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / 'config.yaml'
            config.write_text('rules:\n  - MATCH,DIRECT\n')
            before = config.read_bytes()
            result = subprocess.run(['bash', str(REPO / 'proxy'), 'tun', 'on'],
                env=dict(os.environ, CONF_DIR=str(root)), capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('tun prepare', result.stderr)
            self.assertEqual(config.read_bytes(), before)
            self.assertFalse((root / 'mihomo.pid').exists())

    def test_prepare_only_validates_and_never_changes_live_config_or_services(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = base / 'runtime';root.mkdir()
            original = 'rules:\n  - MATCH,DIRECT\n'
            (root / 'config.yaml').write_text(original)
            kernel = base / 'mihomo';kernel.write_text('#!/bin/sh\nexit 0\n');kernel.chmod(0o700)
            output = base / 'stage'
            result = tun_prepare.prepare(root, REPO / 'proxy', kernel, output, auto_redirect=False)
            self.assertFalse(result['activated'])
            self.assertEqual((root / 'config.yaml').read_text(), original)
            self.assertFalse((root / 'supervisor.json').exists())
            self.assertFalse(json.loads((output / 'tun.json').read_text())['tun']['auto-redirect'])
            self.assertIn('auto-redirect: false', (output / 'candidate.yaml').read_text())
            unit = (output / result['unit']).read_text()
            self.assertIn('NoNewPrivileges=true', unit)
            self.assertIn('AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW', unit)
            self.assertIn('User=' + str(os.getuid()), unit)
            installer = (output / 'install-supervisor.sh').read_text()
            self.assertNotIn('sudoers', installer)
            self.assertNotIn('systemctl start', installer)
            self.assertEqual(subprocess.run(['bash', '-n', str(output / 'install-supervisor.sh')]).returncode, 0)
            policy = next(output.glob('*.rules')).read_text()
            self.assertIn('manage-units', policy)
            self.assertNotIn('manage-unit-files', policy)
            self.assertIn('["start", "stop", "restart"]', policy)
            self.assertEqual(output.stat().st_mode & 0o777, 0o700)


if __name__ == '__main__':
    unittest.main()
