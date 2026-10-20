"""Subscription conversion and pool assembly with real parser/shell boundaries."""
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'libexec'))
from routing_profile import entries, routing_entry, section


class SubscriptionImport(unittest.TestCase):
    def shell(self, directory, command):
        env = dict(os.environ, CONF_DIR=str(directory), SCRIPT_DIR=str(ROOT),
                   STAGING=str(directory), PYTHONDONTWRITEBYTECODE='1')
        result = subprocess.run(['bash', '-c', 'source "$SCRIPT_DIR/lib/common.sh"\n'
            'source "$SCRIPT_DIR/lib/sub.sh"\nsource "$SCRIPT_DIR/lib/pool.sh"\n' + command],
            env=env, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_all_three_subscriptions_survive_yaml_indentation_and_field_order(self):
        with tempfile.TemporaryDirectory() as name:
            d = Path(name)
            base = ('proxies:\n  - {name: US baseline, type: http, server: localhost, port: 1}\n'
                    'proxy-groups:\n  - name: BASE\n    type: select\n    proxies: [US baseline]\n'
                    'rules:\n  - MATCH,BASE\n')
            (d / 'config.yaml').write_text(base)
            (d / 'proxy.conf').write_text('active_sub=baseline\n')
            (d / 'baseline.raw').write_text(base)
            (d / 'baseline.prox').write_text(base.split('proxy-groups:')[0])
            (d / 'second.prox').write_text('proxies:\n- type: anytls\n  name: Japan second\n'
                '  server: localhost\n  port: 2\n  password: "name: PRIVATE"\n'
                '  ws-opts:\n    headers:\n      name: opaque-header\n')
            (d / 'third.prox').write_text('proxies:\n- {type: http, name: Canada third, server: localhost, port: 3}\n')
            self.shell(d, '_pool_assemble "$STAGING" "$STAGING/out.yaml"')
            out = (d / 'out.yaml').read_text()
            nodes = [routing_entry(c) for c in entries(section(out, 'proxies'))]
            self.assertEqual({n['name'] for n in nodes}, {'US01', 'JP01', 'CA01'})
            self.assertIn('password: "name: PRIVATE"', out)
            self.assertIn('name: opaque-header', out)
            self.assertIn('MATCH,BASE', out)

    def test_anytls_uri_password_default_port_ipv6_and_tls_options(self):
        with tempfile.TemporaryDirectory() as name:
            d = Path(name)
            text = ('anytls://p%40ss%3Aword@edge.test/?sni=tls.test#US%20one\n'
                    'anytls://second@[2001:db8::1]:8443/?insecure=1#Japan%20two\n')
            (d / 'raw').write_text(base64.b64encode(text.encode()).decode())
            self.shell(d, '_sub_convert "$STAGING/raw" 127.0.0.1:9090')
            rows = [routing_entry(c) for c in entries(section((d / 'raw').read_text(), 'proxies'))]
            self.assertEqual([n['name'] for n in rows], ['US one', 'Japan two'])
            self.assertTrue(all(n['type'] == 'anytls' for n in rows))
            raw = (d / 'raw').read_text()
            self.assertIn('password: "p@ss:word"', raw)
            self.assertIn('port: 443', raw)
            self.assertIn('server: "2001:db8::1"', raw)
            self.assertIn('sni: tls.test', raw)
            self.assertEqual(raw.count('skip-cert-verify: true'), 1)

    def test_info_nodes_removed_from_unindented_definitions_and_group_members(self):
        with tempfile.TemporaryDirectory() as name:
            d = Path(name)
            (d / 'raw').write_text('proxies:\n- type: http\n  name: 剩余流量\n  server: fake\n  port: 1\n'
                '- {type: http, name: US real, server: localhost, port: 2}\n'
                'proxy-groups:\n- type: select\n  name: BASE\n  proxies:\n  - 剩余流量\n  - US real\n'
                'rules:\n- MATCH,BASE\n')
            self.shell(d, '_sub_sanitize "$STAGING/raw" 127.0.0.1:9090 off')
            out = (d / 'raw').read_text()
            self.assertNotIn('剩余流量', out)
            self.assertEqual(len(entries(section(out, 'proxies'))), 1)
            group = routing_entry(entries(section(out, 'proxy-groups'))[0])
            self.assertEqual(group['proxies'], ['US real'])

    def test_node_only_refresh_retains_cached_subscription_routing_profile(self):
        with tempfile.TemporaryDirectory() as name:
            d = Path(name)
            (d / 'pool-state').mkdir()
            profile = ('proxies:\n  - {name: US old, type: http, server: localhost, port: 1}\n'
                       'proxy-groups:\n  - {name: BASE, type: select, proxies: [US old]}\n'
                       'rules:\n  - DOMAIN,keep.test,DIRECT\n  - MATCH,BASE\n')
            (d / 'pool-state/baseline.profile').write_text(profile)
            (d / 'fixture').write_text('anytls://password@edge.test#US%20new\n')
            self.shell(d, 'curl_download_private() { cp "$STAGING/fixture" "$2"; }\n'
                       '_pool_fetch baseline unused unused "$STAGING"')
            self.assertEqual((d / 'baseline.raw').read_text(), profile)
            self.assertEqual(len(entries(section((d / 'baseline.prox').read_text(), 'proxies'))), 1)

    def test_converted_node_list_can_be_the_baseline_without_group_name_collisions(self):
        with tempfile.TemporaryDirectory() as name:
            d = Path(name)
            (d / 'baseline.raw').write_text('anytls://password@edge.test#US%20new\n')
            (d / 'proxy.conf').write_text('active_sub=baseline\n')
            self.shell(d, '_sub_convert "$STAGING/baseline.raw" 127.0.0.1:9090\n'
                       'sed "/^proxy-groups:/,\\$d" "$STAGING/baseline.raw" > "$STAGING/baseline.prox"\n'
                       '_pool_assemble "$STAGING" "$STAGING/out.yaml"')
            out = (d / 'out.yaml').read_text()
            names = [routing_entry(c)['name'] for c in entries(section(out, 'proxy-groups'))]
            self.assertEqual(len(names), len(set(names)))
            self.assertIn('MATCH,节点选择', out)

    def test_pool_status_counts_top_level_nodes_with_unindented_yaml(self):
        with tempfile.TemporaryDirectory() as name:
            d = Path(name)
            (d / 'pool-state').mkdir()
            (d / 'proxy.conf').write_text('pool=on\n')
            (d / 'pool-state/example.prox').write_text('proxies:\n- type: http\n  name: one\n'
                '  alpn:\n  - h2\n  - http/1.1\n- {name: two, type: http}\n')
            result = self.shell(d, 'ctrl_up() { return 1; }\npool_status')
            self.assertRegex(result.stdout, r'example\s+2 节点')
