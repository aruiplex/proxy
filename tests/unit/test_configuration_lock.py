import json
import os
from pathlib import Path
import subprocess
import signal
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'libexec'))
import configuration_lock as config


class ConfigurationLockTests(unittest.TestCase):
    def test_other_threads_wait_but_nested_same_thread_operations_do_not(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            entered = threading.Event()
            def other():
                with config.lock(root): entered.set()
            with config.lock(root):
                with config.lock(root): self.assertTrue(config.owned(root))
                t = threading.Thread(target=other)
                t.start()
                self.assertFalse(entered.wait(.15))
            t.join(3)
            self.assertTrue(entered.is_set())
            self.assertFalse(config.owned(root))

    def test_cli_child_can_reenter_and_ownership_expires_after_command(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            code = ('import sys;from pathlib import Path;sys.path.insert(0,sys.argv[1]);'
                    'import configuration_lock as c;assert c.owned(Path(sys.argv[2]));'
                    'exec("with c.lock(Path(sys.argv[2])): pass")')
            result = subprocess.run([sys.executable,str(ROOT/'libexec/configuration_lock.py'),
                '--root',str(root),'--',sys.executable,'-B','-c',code,str(ROOT/'libexec'),str(root)],
                capture_output=True,text=True,timeout=5)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertFalse((root/'.configuration-owner.json').exists())
            with config.lock(root,timeout=.1): pass

    def test_dead_or_forged_owner_does_not_bypass_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'.configuration-owner.json').write_text(json.dumps({'pid':999999999,'thread':1,'token':'old'}))
            saved = os.environ.get(config.TOKEN)
            os.environ[config.TOKEN]='old'
            try:
                self.assertFalse(config.owned(root))
                with config.lock(root): self.assertTrue(config.owned(root))
            finally:
                if saved is None:os.environ.pop(config.TOKEN,None)
                else:os.environ[config.TOKEN]=saved

    def test_killed_launcher_cannot_release_a_still_running_writers_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            code=("from pathlib import Path\nimport os,sys,time\nroot=Path(sys.argv[1])\n"
                  "(root/'writer-ready').write_text(str(os.getpid()))\n"
                  "while not (root/'go').exists(): time.sleep(.02)\n"
                  "(root/'published').write_text('done')\n")
            process=subprocess.Popen([sys.executable,str(ROOT/'libexec/configuration_lock.py'),
                '--root',str(root),'--',sys.executable,'-c',code,str(root)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            child=None
            try:
                deadline=time.monotonic()+3
                while not (root/'writer-ready').exists():
                    self.assertLess(time.monotonic(),deadline)
                    time.sleep(.02)
                child=int((root/'writer-ready').read_text())
                process.kill();process.wait(timeout=3)
                with self.assertRaises(TimeoutError):
                    with config.lock(root,timeout=.1):pass
                (root/'go').touch()
                with config.lock(root,timeout=3):
                    self.assertEqual((root/'published').read_text(),'done')
            finally:
                if process.poll() is None:process.kill();process.wait()
                if child:
                    try:os.killpg(child,signal.SIGKILL)
                    except ProcessLookupError:pass

    def test_daemon_child_detaches_lock_before_outliving_cli(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            (root/'daemon.py').write_text("import os,time\nfrom pathlib import Path\n"
                "(Path(os.environ['CONF_DIR'])/'daemon-ready').write_text(str(os.getpid()))\ntime.sleep(10)\n")
            script=root/'launch.sh'
            script.write_text('source "$SCRIPT_DIR/lib/common.sh"\n'
                '( detach_configuration_lock; exec "$TEST_PYTHON" "$CONF_DIR/daemon.py" ) &\n'
                'for i in {1..100}; do [[ ! -f "$CONF_DIR/daemon-ready" ]] || break; sleep .02; done\n')
            env=dict(os.environ,CONF_DIR=str(root),SCRIPT_DIR=str(ROOT),TEST_PYTHON=sys.executable)
            child=None
            try:
                r=subprocess.run([sys.executable,str(ROOT/'libexec/configuration_lock.py'),
                    '--root',str(root),'--','bash',str(script)],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=5)
                self.assertEqual(r.returncode,0)
                child=int((root/'daemon-ready').read_text())
                with config.lock(root,timeout=.1):pass
                os.kill(child,0)
            finally:
                if child:
                    try:os.kill(child,signal.SIGKILL)
                    except ProcessLookupError:pass
