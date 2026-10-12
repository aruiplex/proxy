"""Exercise the public CLI with an isolated authenticated controller, never a live proxy."""
import json
import os
import pty
import select
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT.parent / 'bin/scripts'


def row(target='ai.test:443', node='fixture A', selection=1, when='2026-10-12T10:00:00Z'):
    return dict(target=target, node=node, selection=selection, lastEstablished=when,
                established=1, dials=1, failures=0)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.server.reads.append(self.path)
        if self.headers.get('Authorization') != 'Bearer fixture-secret':
            self.send_error(401)
            return
        if self.path == '/version':
            result = {'version': 'fixture-adaptive'}
        elif self.path == '/proxies':
            result = {'proxies': {name: {'type': 'Adaptive'} for name in self.server.groups}}
        elif self.path.startswith('/proxies/') and self.path.endswith('/quality'):
            group = unquote(self.path[len('/proxies/'):-len('/quality')])
            if group == self.server.stalled_group:
                time.sleep(9)
            result = self.server.groups[group]
            if isinstance(result, int):
                self.send_error(result)
                return
            result = {'records': result}
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.end_headers()
        try:
            self.wfile.write(json.dumps(result).encode())
        except BrokenPipeError:
            pass

    def do_POST(self):
        self.server.posts.append((self.path, json.loads(self.rfile.read(int(self.headers['Content-Length'])))))
        self.send_response(self.server.feedback_status)
        self.end_headers()


class DailyCLI(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='proxy-daily-test-')
        self.addCleanup(self.temp.cleanup)
        self.state = Path(self.temp.name)
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.groups = {'自动/组': [row()]}
        self.server.reads = []
        self.server.posts = []
        self.server.feedback_status = 204
        self.server.stalled_group = None
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.conf = self.state / 'proxy.conf'
        self.conf.write_text(f'controller=127.0.0.1:{self.server.server_port}\nsecret=fixture-secret\n')
        (self.state / 'config.yaml').write_text('mixed-port: 17890\nrules:\n- MATCH,DIRECT\n')
        (self.state / 'env.state').write_text('off\n')
        (self.state / 'mihomo.pid').write_text('999999999\n')
        self.env = dict(os.environ, CONF_DIR=str(self.state), HTTP_PROXY='http://127.0.0.1:1',
                        HTTPS_PROXY='http://127.0.0.1:1', ALL_PROXY='http://127.0.0.1:1')

    def cli(self, *args, success=True, scripts=False):
        argv = ['bash', str(SCRIPTS), 'proxy'] if scripts else [str(ROOT / 'proxy')]
        result = subprocess.run(argv + list(args), env=self.env, text=True, capture_output=True,
                                stdin=subprocess.DEVNULL, timeout=10)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def snapshot(self):
        return {p.name: p.read_bytes() for p in self.state.iterdir() if p.is_file()}

    def test_default_is_read_only_brief_and_works_without_input(self):
        before = self.snapshot()
        output = self.cli().stdout
        self.assertIn('fixture-adaptive', output)
        self.assertIn('ai.test:443', output)
        self.assertIn('fixture A', output)
        self.assertNotIn('出口节点:', output)
        self.assertNotIn('请选择', output)
        self.assertLessEqual(len(output.splitlines()), 12)
        self.assertEqual(self.server.reads.count('/version'), 1)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.server.posts, [])

    def test_default_in_real_tty_does_not_start_menu_or_wait(self):
        before = self.snapshot()
        master, slave = pty.openpty()
        try:
            process = subprocess.Popen([str(ROOT / 'proxy')], env=self.env,
                stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
            os.close(slave)
            slave = None
            self.addCleanup(lambda: process.kill() if process.poll() is None else None)
            output = bytearray()
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                if select.select([master], [], [], 0.1)[0]:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    output.extend(chunk)
                elif process.poll() is not None:
                    break
            self.assertEqual(process.wait(timeout=1), 0)
            self.assertIn('近期目标', output.decode())
            self.assertNotIn('请选择', output.decode())
            self.assertEqual(self.snapshot(), before)
        finally:
            os.close(master)
            if slave is not None:
                os.close(slave)

    def test_next_normalizes_and_posts_once_to_unique_observed_group(self):
        self.server.groups = {'无记录': [], '自动/组': [row()], '其他目标': [row('else.test:443', selection=999)]}
        before = self.snapshot()
        output = self.cli('next', 'AI.TEST', '--reason', 'timeout').stdout
        self.assertIn('已有健康连接保持', output)
        self.assertEqual(self.server.posts, [('/proxies/%E8%87%AA%E5%8A%A8%2F%E7%BB%84/feedback',
            {'target': 'ai.test:443', 'reason': 'timeout'})])
        self.assertEqual(self.snapshot(), before)

    def test_ports_and_ipv6_are_exact_and_never_match_subdomains(self):
        for target, normalized in [('AI.TEST:8443', 'ai.test:8443'), ('[2001:db8::1]:443', '[2001:db8::1]:443')]:
            with self.subTest(target=target):
                self.server.groups = {'one': [row(normalized)]}
                self.cli('next', target)
                self.assertEqual(self.server.posts[-1][1]['target'], normalized)
        self.server.posts.clear()
        self.server.groups = {'one': [row('api.ai.test:443')]}
        self.cli('next', 'ai.test', success=False)
        self.assertEqual(self.server.posts, [])

    def test_ambiguous_missing_unestablished_or_invalid_target_never_posts(self):
        for groups in [{'a': [row()], 'b': [row(selection=900)]}, {'a': []}, {'a': [row(selection=0)]}]:
            with self.subTest(groups=groups):
                self.server.groups = groups
                result = self.cli('next', 'ai.test', success=False)
                self.assertNotIn('请选择', result.stdout + result.stderr)
                self.assertEqual(self.server.posts, [])
        for target in ['https://ai.test', 'ai.test:0', 'ai.test:65536', 'ai.test:', 'ai.test/path', 'a b', '2001:db8::1']:
            self.server.reads.clear()
            self.cli('next', target, success=False)
            self.assertEqual(self.server.reads, [])
            self.assertEqual(self.server.posts, [])
        missing = self.cli('next', success=False)
        self.assertIn('proxy next --help', missing.stderr)
        self.assertNotIn('quality.py', missing.stderr)
        self.assertNotIn('--root', missing.stderr)
        self.assertEqual(self.server.posts, [])

    def test_explicit_group_resolves_ambiguity_without_reading_other_groups(self):
        self.server.groups = {'a': [row()], 'b': 500}
        self.cli('next', 'ai.test', success=False)
        self.assertEqual(self.server.posts, [])
        self.server.reads.clear()
        self.cli('next', 'ai.test', '--group', 'a')
        self.assertEqual(len(self.server.posts), 1)
        self.assertNotIn('/proxies/b/quality', self.server.reads)

    def test_unreadable_or_malformed_group_prevents_feedback(self):
        for result in [500, [{'target': 'ai.test:443', 'node': 'B', 'selection': 'invalid'}]]:
            self.server.groups = {'a': [row()], 'b': result}
            self.cli('next', 'ai.test', success=False)
            self.assertEqual(self.server.posts, [])
        self.server.groups = {'a': [row()]}
        self.server.feedback_status = 400
        self.cli('next', 'ai.test', success=False)
        self.assertEqual(len(self.server.posts), 1)

    def test_authentication_error_is_private_and_default_degrades(self):
        self.conf.write_text(f'controller=127.0.0.1:{self.server.server_port}\nsecret=private-wrong-secret\n')
        result = self.cli('next', 'ai.test', success=False)
        self.assertIn('认证失败', result.stderr)
        self.assertNotIn('private-wrong-secret', result.stdout + result.stderr)
        output = self.cli().stdout
        self.assertIn('控制器不可达或认证失败', output)
        self.assertIn('proxy next', output)
        self.assertEqual(self.server.posts, [])

    def test_latest_targets_sort_by_time_across_groups_not_selection(self):
        self.server.groups = {'older': [row('old.test:443', selection=900, when='2026-10-11T12:00:00Z')],
                              'newer': [row('new.test:443', selection=1, when='2026-10-12T12:00:00Z')]}
        output = self.cli().stdout
        self.assertLess(output.index('new.test'), output.index('old.test'))
        self.assertIn('2 个组', output)

    def test_overview_limits_targets_and_explains_empty_evidence(self):
        self.server.groups = {'one': [row(f'example{i}.test:443') for i in range(8)]}
        output = self.cli().stdout
        self.assertEqual(sum(' → ' in line for line in output.splitlines()), 5)
        self.assertIn('更多记录', output)
        self.server.groups = {'one': []}
        self.assertIn('尚无成功建立记录', self.cli().stdout)
        self.server.groups = {}
        self.assertIn('当前无 Adaptive 组', self.cli().stdout)

    def test_live_owned_pid_is_reported_without_controller_or_pid_writes(self):
        process = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)',
            '-d', str(self.state), '-f', str(self.state / 'config.yaml')])
        self.addCleanup(process.wait)
        self.addCleanup(process.terminate)
        (self.state / 'mihomo.pid').write_text(str(process.pid) + '\n')
        self.conf.write_text(f'bin={sys.executable}\ncontroller=127.0.0.1:{self.server.server_port}\nsecret=wrong\n')
        before = self.snapshot()
        output = self.cli().stdout
        self.assertIn('进程仍在 · PID ' + str(process.pid), output)
        self.assertIsNone(process.poll())
        self.assertEqual(self.snapshot(), before)

    def test_controller_timeout_fails_without_feedback(self):
        self.server.groups = {'a': [row()], 'b': [row()]}
        self.server.stalled_group = 'b'
        started = time.monotonic()
        self.cli('next', 'ai.test', success=False)
        self.assertLess(time.monotonic() - started, 10)
        self.assertEqual(self.server.posts, [])

    def test_short_and_full_help(self):
        output = self.cli('help').stdout
        self.assertLessEqual(len(output.splitlines()), 8)
        self.assertIn('next', output)
        self.assertNotIn('kernel prepare', output)
        self.assertEqual(output, self.cli('--help').stdout)
        before = self.snapshot()
        self.assertEqual(output, self.cli('menu').stdout)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.server.posts, [])
        self.assertIn('kernel prepare', self.cli('help', '--all').stdout)
        self.cli('help', '--invalid', success=False)

    @unittest.skipUnless(SCRIPTS.is_file(), 'scripts forwarding is tested in the parent checkout')
    def test_scripts_forwarding_preserves_default_next_and_errors(self):
        self.assertIn('近期目标', self.cli(scripts=True).stdout)
        self.cli('next', 'AI.TEST', scripts=True)
        self.assertEqual(self.server.posts[-1][1]['target'], 'ai.test:443')
        self.cli('next', 'unknown.test', scripts=True, success=False)

    def test_empty_completion_is_small_but_advanced_prefixes_remain(self):
        script = 'source "$1/lib/complete.sh"; COMP_WORDS=(proxy ""); COMP_CWORD=1; _proxy_complete; printf "%s\\n" "${COMPREPLY[@]}"'
        result = subprocess.run(['bash', '-c', script, 'fixture', str(ROOT)], capture_output=True, text=True, timeout=3)
        self.assertEqual(result.stdout.splitlines(), ['next', 'on', 'off', 'help'])
        script = script.replace('COMP_WORDS=(proxy "")', 'COMP_WORDS=(proxy hea)')
        result = subprocess.run(['bash', '-c', script, 'fixture', str(ROOT)], capture_output=True, text=True, timeout=3)
        self.assertEqual(result.stdout.strip(), 'health')


if __name__ == '__main__':
    unittest.main()
