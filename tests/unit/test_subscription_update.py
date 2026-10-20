"""Two complete CLI refreshes against local subscription/controller fixtures."""
import base64
import collections
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'libexec'))
from routing_profile import entries,routing_entry,section


class SubscriptionUpdate(unittest.TestCase):
    def test_updates_import_every_source_and_preserve_rules_when_source_becomes_node_list(self):
        with tempfile.TemporaryDirectory() as directory:
            conf=Path(directory);generation=[1];published=[]
            first=('proxies:\n- type: http\n  name: CA cross\n  server: fixture.test\n  port: 1\n'
                   'proxy-groups:\n- name: BASE\n  type: select\n  proxies: [CA cross]\n'
                   'rules:\n- DOMAIN,keep.test,DIRECT\n- MATCH,BASE\n')
            def payload(name):
                if name=='crosswall':
                    if generation[0]==1:return first.encode()
                    return base64.b64encode(b'anytls://pw@fixture.test#CA%20cross\nanytls://pw@fixture2.test#US%20extra\n')
                count=generation[0]
                return ('proxies:\n'+''.join('- type: http\n  server: fixture.test\n  port: '+str(i+10)+'\n  name: '+name+' US '+str(i)+'\n' for i in range(count))).encode()
            class Handler(http.server.BaseHTTPRequestHandler):
                def log_message(self,*_):pass
                def do_GET(self):
                    self.send_response(200);self.end_headers()
                    if self.path.startswith('/sub/'):
                        self.wfile.write(payload(self.path.split('/')[-1]))
                    else:self.wfile.write(json.dumps({'version':'fixture','proxies':{}}).encode())
                def do_PUT(self):
                    self.rfile.read(int(self.headers.get('Content-Length','0')))
                    published.append((conf/'config.yaml').read_text())
                    self.send_response(204);self.end_headers()
            server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
            thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
            try:
                kernel=conf/'kernel';kernel.write_text('#!/usr/bin/env bash\n[[ "$1" != -v ]] || echo "Mihomo fixture v1"\nexit 0\n');kernel.chmod(0o755)
                (conf/'proxy.conf').write_text('pool=on\nactive_sub=crosswall\ncontroller=127.0.0.1:'+str(server.server_port)+'\nbin='+str(kernel)+'\n')
                (conf/'config.yaml').write_text(first)
                (conf/'subs.conf').write_text(''.join(n+'\thttp://127.0.0.1:'+str(server.server_port)+'/sub/'+n+'\n' for n in ['default','riolu','crosswall']))
                env=dict(os.environ,CONF_DIR=str(conf),PYTHONDONTWRITEBYTECODE='1',NO_PROXY='127.0.0.1,localhost',no_proxy='127.0.0.1,localhost')
                for expected in [1,2]:
                    generation[0]=expected
                    command=[str(ROOT/'proxy'),'pool','refresh'] if expected==1 else [str(ROOT/'proxy'),'update']
                    r=subprocess.run(command,env=env,capture_output=True,text=True,timeout=20)
                    self.assertEqual(r.returncode,0,r.stderr+'\n'+r.stdout)
                    text=(conf/'config.yaml').read_text()
                    self.assertEqual(len(entries(section(text,'proxies'))),3*expected)
                    sources=json.loads(next(l.split(':',1)[1] for l in text.splitlines() if l.startswith('x-proxy-node-sources:')))
                    self.assertEqual(dict(collections.Counter(sources.values())),{'crosswall':expected,'default':expected,'riolu':expected})
                    self.assertIn('DOMAIN,keep.test,DIRECT',text)
                    self.assertIn('MATCH,BASE',text)
                self.assertEqual(len(published),2)
            finally:
                server.shutdown();server.server_close();thread.join(3)
