import os
import subprocess
import tempfile
import unittest
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'libexec'))
from pool_profile import apply_profile
from routing_profile import entries, routing_entry, section
from adaptive_config import render
BASE = '''proxies:
  - {name: Canada old, type: http, server: 127.0.0.1, port: 12345}
proxy-groups:
  - name: DEFAULT
    type: select
    proxies: [Canada old, PINNED]
  - name: PINNED
    type: select
    proxies: [Canada old]
rules:
  - DOMAIN,localhost,DIRECT
  - DOMAIN,ads.test,REJECT
  - DOMAIN,pinned.test,PINNED
  - DOMAIN-KEYWORD,google,DEFAULT
  - GEOIP,CN,DIRECT
  - MATCH,DEFAULT
'''


class PoolProfile(unittest.TestCase):
    def test_global_exclusion_applies_to_retained_baseline_groups(self):
        profile=BASE.replace('proxies: [Canada old]', 'include-all: true\n    proxies: [Canada old]')
        runtime='proxies:\n  - {name: CA01, type: http, server: 127.0.0.1, port: 12345}\n'
        out=apply_profile(runtime,profile,{'Canada old':'CA01'},
                          '    - name: POOL\n      type: select\n      proxies: [CA01]\n','POOL','^CA')
        out=render(out,{'policies':['PINNED']})
        groups=[routing_entry(c) for c in entries(section(out,'proxy-groups'))]
        self.assertEqual(groups[-1]['proxies'],['REJECT'])
        self.assertIn('exclude-filter: "^CA"',out)

    def test_pool_rebuild_keeps_baseline_rule_order_and_special_group_scope(self):
        with tempfile.TemporaryDirectory() as directory:
            d = Path(directory)
            (d / 'config.yaml').write_text('mixed-port: 17890\nproxies:\n  - {name: OLD, type: http}\nproxy-groups:\n  - {name: OLD, type: select}\nrules:\n  - MATCH,DIRECT\n')
            (d / 'proxy.conf').write_text('active_sub=baseline\n')
            (d / 'baseline.raw').write_text(BASE)
            (d / 'baseline.prox').write_text(BASE.split('proxy-groups:')[0])
            (d / 'extra.prox').write_text('proxies:\n  - {name: Japan extra, type: http, server: 127.0.0.1, port: 12346}\n')
            env = dict(os.environ, CONF_DIR=str(d), SCRIPT_DIR=str(ROOT), STAGING=str(d), PYTHONDONTWRITEBYTECODE='1')
            command = 'source "$SCRIPT_DIR/lib/common.sh"\nsource "$SCRIPT_DIR/lib/pool.sh"\n_pool_assemble "$STAGING" "$STAGING/out.yaml"'
            run = subprocess.run(['bash', '-c', command], env=env, text=True, capture_output=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stderr)
            out = (d / 'out.yaml').read_text()
            self.assertIn(BASE.split('rules:\n')[1], out)
            self.assertIn('proxies: ["CA01", "PINNED", "节点选择"]', out)
            self.assertIn('proxies: ["CA01"]', out)
            self.assertIn('x-proxy-node-regions: {"CA01": "CA", "JP01": "JP"}', out)
            # Supplemental nodes add to the pool; PINNED remains Canada-only.
            self.assertNotIn('proxies: ["CA01", "JP01"]', out)
            (d / 'baseline.raw').unlink()
            run = subprocess.run(['bash', '-c', command], env=env, text=True, capture_output=True, timeout=10)
            self.assertNotEqual(run.returncode, 0)
            self.assertIn('规则基准不可用', run.stderr)


if __name__ == '__main__':
    unittest.main()
