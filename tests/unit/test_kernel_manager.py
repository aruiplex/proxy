"""Behavior tests at the public CLI seam, using temporary state and releases."""
import gzip
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'libexec'))
from kernel_manager import KernelError, Manager, host_platform, official_manifest


class KernelManagement(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='proxy-kernel-test-')
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.home = self.directory / 'home'
        self.home.mkdir()
        self.config = self.home / 'config.yaml'
        self.config.write_text('rules:\n- MATCH,DIRECT\nexternal-controller: 127.0.0.1:45678\nsecret: "fixture-only"\n')
        (self.home / 'proxy.conf').write_text('test_url=https://example.test\n')
        self.cli = [str(ROOT / 'proxy')]
        self.environment = dict(os.environ, CONF_DIR=str(self.home))
        self.manifest = self.release('v1.fixture', 'fixture/custom')

    def release(self, version, source='fixture/custom', bad=False, compressed=False):
        binary = self.directory / ('binary-' + version)
        binary.write_text(f'''#!/usr/bin/env python3
import pathlib,sys
if '-v' in sys.argv:
 print('Mihomo Meta {version} fixture amd64 with test')
elif '-t' in sys.argv:
 p=pathlib.Path(sys.argv[sys.argv.index('-f')+1])
 d=pathlib.Path(sys.argv[sys.argv.index('-d')+1])
 for name in ['logs','health','adaptive-quality']:
  if (d/name).exists(): raise SystemExit(3)
 # Absolute resources in the active home must be validated against its clone.
 for line in p.read_text().splitlines():
  if line.startswith('external-ui:'):
   import json
   value=json.loads(line.split(':',1)[1].strip())
   try: pathlib.Path(value).relative_to(d)
   except ValueError: raise SystemExit(2)
 # A candidate validator must never write in the active state directory.
 (d/'validation-side-effect').write_text('fixture')
 raise SystemExit(1 if 'BAD' in p.read_text() else 0)
''')
        binary.chmod(0o700)
        asset = binary
        if compressed:
            asset = binary.with_suffix('.gz')
            asset.write_bytes(gzip.compress(binary.read_bytes()))
        manifest = self.directory / ('manifest-' + version + '.json')
        manifest.write_text(json.dumps({'schema': 1, 'source': {'id': source, 'kind': 'custom'},
            'version': version, 'platform': host_platform(), 'asset': {'path': str(asset),
            'compression': 'gzip' if compressed else 'none',
            'sha256': '0'*64 if bad else hashlib.sha256(asset.read_bytes()).hexdigest()}}))
        return manifest

    def run_cli(self, *args, success=True):
        run = subprocess.run(self.cli + list(args), env=self.environment, text=True, capture_output=True, timeout=15)
        self.assertEqual(run.returncode == 0, success, run.stdout + run.stderr)
        return run

    def state(self):
        return json.loads(self.run_cli('kernel', 'status', '--json').stdout)

    def prepare(self, manifest=None, **kwargs):
        return self.run_cli('kernel', 'prepare', '--manifest', str(manifest or self.manifest), **kwargs)

    def activate(self):
        return self.run_cli('kernel', 'activate')

    def test_first_install_stage_activate_and_source_preserving_upgrade(self):
        initial = self.config.read_bytes()
        self.prepare()
        self.assertIsNone(self.state()['active'])
        self.assertEqual(self.config.read_bytes(), initial)
        self.assertFalse((self.home / 'validation-side-effect').exists())
        self.activate()
        state = self.state()
        self.assertEqual(state['active']['source']['id'], 'fixture/custom')
        self.assertIn('secret=fixture-only', (self.home / 'proxy.conf').read_text())
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)
        second = self.release('v2.fixture', compressed=True)
        self.run_cli('upgrade', '--manifest', str(second))
        self.assertEqual(self.state()['active']['version'], 'v1.fixture')
        self.activate()
        self.assertEqual(self.state()['active']['version'], 'v2.fixture')
        self.assertEqual(self.state()['previous']['version'], 'v1.fixture')
        self.run_cli('upgrade', success=False)
        self.run_cli('upgrade', '--version', 'v1.19.32', success=False)

    def test_failed_digest_platform_version_and_config_preserve_selection(self):
        self.prepare(); self.activate()
        state = self.state()
        config = self.config.read_bytes()
        for problem in ['digest', 'platform', 'version', 'config', 'download']:
            path = self.release('v-bad-' + problem, bad=problem == 'digest')
            data = json.loads(path.read_text())
            if problem == 'platform': data['platform']['arch'] = 'wrong'
            if problem == 'version': data['version'] = 'v-other'
            if problem == 'download': data['asset']['path'] = str(self.directory / 'missing-asset')
            path.write_text(json.dumps(data))
            if problem == 'config':
                bad_config = self.directory / 'bad.yaml'; bad_config.write_text('BAD')
                self.run_cli('kernel', 'prepare', '--manifest', str(path), '--config', str(bad_config), success=False)
            else:
                self.prepare(path, success=False)
            self.assertEqual(self.state(), state)
            self.assertEqual(self.config.read_bytes(), config)
        self.assertFalse((self.home / 'validation-side-effect').exists())

    def test_source_switch_requires_explicit_operation(self):
        self.prepare(); self.activate()
        other = self.release('v2.fixture', 'other/custom')
        self.run_cli('upgrade', '--manifest', str(other), success=False)
        self.run_cli('kernel', 'prepare', '--manifest', str(other), '--switch-source')
        self.assertEqual(self.state()['active']['source']['id'], 'fixture/custom')
        self.activate()
        self.assertEqual(self.state()['active']['source']['id'], 'other/custom')

    def test_rollback_restores_binary_config_settings_and_cache(self):
        self.prepare(); self.activate()
        self.config.write_text(self.config.read_text() + '# compatible old config\n')
        (self.home / 'proxy.conf').write_text((self.home / 'proxy.conf').read_text() + 'active_sub=old-fixture\n')
        (self.home / 'cache.db').write_bytes(b'old stopped cache')
        old_config = self.config.read_bytes()
        new_config = self.directory / 'next.yaml'
        new_config.write_text('rules:\n- MATCH,REJECT\nexternal-controller: 127.0.0.1:45679\n')
        second = self.release('v2.fixture')
        self.run_cli('kernel', 'prepare', '--manifest', str(second), '--config', str(new_config))
        self.activate()
        self.assertEqual(self.config.read_bytes(), new_config.read_bytes())
        self.assertFalse((self.home / 'cache.db').exists())
        self.run_cli('kernel', 'rollback')
        self.assertEqual(self.config.read_bytes(), old_config)
        self.assertEqual((self.home / 'cache.db').read_bytes(), b'old stopped cache')
        self.assertIn('active_sub=old-fixture', (self.home / 'proxy.conf').read_text())
        self.assertEqual(self.state()['active']['version'], 'v1.fixture')
        self.assertEqual(self.state()['previous']['version'], 'v2.fixture')

    def test_legacy_manual_binary_is_preserved_for_rollback(self):
        legacy = self.release('v-legacy.fixture')
        path = json.loads(legacy.read_text())['asset']['path']
        (self.home / 'proxy.conf').write_text(f'bin={path}\ninstall_method=gz\n')
        original_config = self.config.read_bytes()
        self.prepare(); self.activate()
        self.assertEqual(self.state()['previous']['source']['kind'], 'gz')
        Path(path).unlink()
        self.run_cli('kernel', 'rollback')
        self.assertEqual(self.state()['active']['version'], 'v-legacy.fixture')
        self.assertEqual(self.config.read_bytes(), original_config)

    def test_tampering_and_stale_preparation_are_rejected(self):
        self.prepare()
        self.config.write_text(self.config.read_text() + '# newer preference\n')
        self.run_cli('kernel', 'activate', success=False)
        self.prepare()
        state = self.state()
        binary = self.home / 'kernels' / state['prepared']['directory'] / 'mihomo'
        binary.write_text('tampered')
        self.run_cli('kernel', 'activate', success=False)
        self.assertIsNone(self.state()['active'])

    def test_running_instance_is_not_restarted_or_replaced(self):
        self.prepare()
        script = self.directory / 'fixture_running.py'
        script.write_text('import time;time.sleep(60)')
        process = subprocess.Popen([sys.executable, str(script), '-d', str(self.home), '-f', str(self.config)])
        self.addCleanup(process.wait)
        self.addCleanup(process.terminate)
        self.run_cli('kernel', 'activate', success=False)
        self.assertIsNone(process.poll())
        self.assertIsNone(self.state()['active'])

    def test_interrupted_transaction_is_recovered_and_legacy_core_resolution_blocked(self):
        self.prepare(); self.activate()
        original = self.config.read_bytes()
        state = self.state()
        manager = Manager(self.home)
        with manager.locked():
            manager.backup()
            self.config.write_text('interrupted config')
            manager.state['active'] = None
            manager.save()
        run = subprocess.run(['bash', '-c', 'source "$1/lib/common.sh"; mihomo_bin', 'fixture', str(ROOT)],
                             env=self.environment, text=True, capture_output=True)
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(self.state(), state)
        self.assertEqual(self.config.read_bytes(), original)
        self.assertFalse((self.home / 'kernels/undo.json').exists())

    def test_legacy_install_entrances_use_managed_copies(self):
        binary = json.loads(self.manifest.read_text())['asset']['path']
        script = 'SCRIPT_DIR=$1; source "$1/lib/common.sh"; source "$1/lib/install.sh"; proxy_init() { :; }; proxy_install --bin "$2"'
        run = subprocess.run(['bash', '-c', script, 'fixture', str(ROOT), binary], env=self.environment, text=True, capture_output=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(self.state()['active']['source']['kind'], 'manual')
        self.assertNotIn(binary, (self.home / 'proxy.conf').read_text())
        run = subprocess.run(['bash', '-c', script, 'fixture', str(ROOT), binary], env=self.environment, text=True, capture_output=True)
        self.assertNotEqual(run.returncode, 0)
        self.run_cli('upgrade', success=False)

    def test_local_gzip_is_not_misidentified_as_official(self):
        release = self.release('v-gzip.fixture', compressed=True)
        asset = json.loads(release.read_text())['asset']['path']
        self.run_cli('kernel', 'prepare', '--gzip', asset, '--source', 'local-archive', '--kind', 'gz')
        self.activate()
        self.assertEqual(self.state()['active']['source'], {'id': 'local-archive', 'kind': 'gz'})
        self.run_cli('upgrade', '--version', 'v1.19.32', success=False)

    def test_absolute_resources_are_rebased_only_in_validation_copy(self):
        resource = self.home / 'ui'; resource.mkdir()
        original = self.config.read_text() + 'external-ui: ' + json.dumps(str(resource)) + '\n'
        self.config.write_text(original)
        self.prepare()
        self.assertEqual(self.config.read_text(), original)
        self.activate()
        self.assertEqual(self.config.read_text(), original)

    def test_candidate_validation_excludes_live_logs_monitor_and_quality_history(self):
        for name in ['logs','health','adaptive-quality']:
            directory=self.home/name; directory.mkdir(); (directory/'evidence').write_text('local history')
        self.prepare()
        for name in ['logs','health','adaptive-quality']:
            self.assertEqual((self.home/name/'evidence').read_text(), 'local history')

    def test_parallel_start_and_preparation_cannot_bypass_management_lock(self):
        manager = Manager(self.home)
        with manager.locked():
            self.run_cli('start', success=False)
            self.prepare(success=False)
        self.assertFalse((self.home / 'mihomo.pid').exists())
        self.assertIsNone(self.state()['active'])

    def test_release_tag_accepts_old_numeric_version_display(self):
        release = self.release('1.19.29')
        manifest = json.loads(release.read_text()); manifest['version'] = 'v1.19.29'
        release.write_text(json.dumps(manifest))
        self.prepare(release); self.activate()
        self.assertEqual(self.state()['active']['version'], 'v1.19.29')
        self.assertIn('Mihomo Meta 1.19.29 ', self.state()['active']['actual_version'])

    def test_official_metadata_fallback_keeps_tag_and_requires_asset_digest(self):
        hp = host_platform(); variant = '-compatible' if hp['arch'] == 'amd64' else ''
        asset = f"mihomo-{hp['os']}-{hp['arch']}{variant}-v1.19.32.gz"
        data = {'tag_name': 'v1.19.32', 'assets': [{'name': asset, 'digest': 'sha256:'+'a'*64,
                 'browser_download_url': 'https://github.com/MetaCubeX/mihomo/releases/download/v1.19.32/'+asset}]}
        with patch('kernel_manager.request', side_effect=KernelError('anonymous quota exhausted')), patch('kernel_manager.shutil.which', return_value='/fixture/gh'), patch('kernel_manager.subprocess.run') as run:
            run.return_value = subprocess.CompletedProcess([], 0, json.dumps(data), '')
            manifest = official_manifest('v1.19.32')
            self.assertEqual(manifest['asset']['sha256'], 'a'*64)
            self.assertEqual(run.call_args.args[0], ['gh', 'api', 'repos/MetaCubeX/mihomo/releases/tags/v1.19.32'])
            data['tag_name'] = 'v-other'
            run.return_value = subprocess.CompletedProcess([], 0, json.dumps(data), '')
            with self.assertRaises(KernelError): official_manifest('v1.19.32')
            data['tag_name'] = 'v1.19.32'; data['assets'][0]['digest'] = ''
            run.return_value = subprocess.CompletedProcess([], 0, json.dumps(data), '')
            with self.assertRaises(KernelError): official_manifest('v1.19.32')

    def test_missing_managed_binary_never_falls_back_to_path(self):
        self.prepare(); self.activate()
        state = self.state()
        (self.home / 'kernels' / state['active']['directory'] / 'mihomo').unlink()
        run = subprocess.run(['bash', '-c', 'source "$1/lib/common.sh"; mihomo_bin', 'fixture', str(ROOT)],
                             env=self.environment, text=True, capture_output=True)
        self.assertNotEqual(run.returncode, 0)


if __name__ == '__main__':
    unittest.main()
