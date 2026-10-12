import contextlib
import io
import json
import os
import subprocess
import tarfile
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]


class Controller(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_GET(self):
        if self.headers.get('Authorization') != 'Bearer fixture-secret':
            self.send_error(401); return
        if self.path=='/proxies':
            result={'proxies':{'自动/组':{'type':'Adaptive'}}}
        else:
            result={'records':[{'target':'ai.test:443','node':'fixture A','selection':1,'established':1,'dials':1,'failures':0,'reason':''}], 'events':[]}
        self.send_response(200);self.end_headers();self.wfile.write(json.dumps(result).encode())
    def do_POST(self):
        if self.headers.get('Authorization') != 'Bearer fixture-secret':
            self.send_error(401); return
        self.server.feedback=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.send_response(204);self.end_headers()


class QualityAndSync(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='proxy-sync-test-');self.addCleanup(self.temp.cleanup)
        self.directory=Path(self.temp.name);self.home=self.directory/'home';self.home.mkdir()
        self.environment=dict(os.environ,CONF_DIR=str(self.home),HTTP_PROXY='http://127.0.0.1:1',HTTPS_PROXY='http://127.0.0.1:1')

    def cli(self,*args,success=True):
        run=subprocess.run([str(ROOT/'proxy'),*args],env=self.environment,text=True,capture_output=True,timeout=10)
        self.assertEqual(run.returncode==0,success,run.stdout+run.stderr)
        return run

    def test_quality_and_feedback_use_local_auth_without_proxy_environment(self):
        server=ThreadingHTTPServer(('127.0.0.1',0),Controller)
        self.addCleanup(server.server_close);self.addCleanup(server.shutdown)
        threading.Thread(target=server.serve_forever,daemon=True).start()
        (self.home/'proxy.conf').write_text(f'controller=127.0.0.1:{server.server_port}\nsecret=fixture-secret\n')
        result=json.loads(self.cli('quality','--json').stdout)
        self.assertEqual(result['records'][0]['target'],'ai.test:443')
        self.assertIn('fixture A',self.cli('quality').stdout)
        self.cli('feedback','ai.test:443','--reason','timeout')
        self.assertEqual(server.feedback,{'target':'ai.test:443','reason':'timeout'})
        (self.home/'proxy.conf').write_text(f'controller=127.0.0.1:{server.server_port}\nsecret=wrong-fixture\n')
        bad=self.cli('quality',success=False)
        self.assertNotIn('wrong-fixture',bad.stderr)
        self.assertIn('认证失败',bad.stderr)

    def test_sync_only_shares_preferences_and_filters_local_keys(self):
        (self.home/'adaptive.json').write_text(json.dumps({'schema':1,'enabled':True}))
        (self.home/'proxy.conf').write_text('bin=/local/kernel\ncontroller=127.0.0.1:9\nsecret=local-fixture\nactive_sub=fixture\n')
        (self.home/'kernels').mkdir();(self.home/'kernels/state.json').write_text('local kernel metadata')
        (self.home/'quality.json').write_text('local quality')
        bundle=self.directory/'bundle.tar.gz'
        self.cli('sync','export',str(bundle))
        with tarfile.open(bundle) as archive:
            names={member.name.lstrip('./') for member in archive if member.isfile()}
            self.assertEqual(names,{'adaptive.json','proxy.portable'})
            portable=archive.extractfile('./proxy.portable').read().decode()
            self.assertNotIn('bin=',portable);self.assertNotIn('secret=',portable)
        incoming=self.directory/'incoming';incoming.mkdir()
        (incoming/'adaptive.json').write_text(json.dumps({'schema':1,'enabled':True,'preferred_region':'JP'}))
        (incoming/'proxy.portable').write_text('active_sub=other-fixture\nbin=/foreign/kernel\nsecret=foreign-fixture\ncontroller=foreign.test\n')
        self.cli('sync','import',str(incoming))
        text=(self.home/'proxy.conf').read_text()
        self.assertIn('bin=/local/kernel',text);self.assertIn('secret=local-fixture',text)
        self.assertNotIn('foreign',text)
        self.assertIn('active_sub=other-fixture',text)
        self.assertEqual((self.home/'quality.json').read_text(),'local quality')
        self.assertEqual((self.home/'kernels/state.json').read_text(),'local kernel metadata')

    def test_bad_preferences_and_archive_links_cannot_change_local_state(self):
        original='active_sub=local-fixture\n';(self.home/'proxy.conf').write_text(original)
        incoming=self.directory/'incoming';incoming.mkdir()
        (incoming/'adaptive.json').write_text('{"schema":1,"enabled":true,"dial_budget":false}')
        (incoming/'proxy.portable').write_text('active_sub=bad-fixture\n')
        self.cli('sync','import',str(incoming),success=False)
        self.assertEqual((self.home/'proxy.conf').read_text(),original)
        for name,kind in [('../escape',tarfile.REGTYPE),('proxy.portable',tarfile.SYMTYPE)]:
            path=self.directory/'bad.tar.gz'
            with tarfile.open(path,'w:gz') as archive:
                member=tarfile.TarInfo(name);member.type=kind;member.linkname='../escape';member.size=1 if kind==tarfile.REGTYPE else 0
                archive.addfile(member,io.BytesIO(b'x') if member.size else None)
            self.cli('sync','import',str(path),success=False)
            self.assertEqual((self.home/'proxy.conf').read_text(),original)


if __name__=='__main__': unittest.main()
