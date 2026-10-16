import json
import sys
import unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'libexec'))
from adaptive_config import ConfigError, GROUP, render
from routing_profile import entries, section, routing_entry, node_identity

BASE='''proxies:
    - {name: "SG one", type: http, server: 127.0.0.1, port: 12345}
    - name: JP two
      type: http
      server: 127.0.0.1
      port: 12346
proxy-groups:
    - name: PROXY
      type: select
      proxies: ["SG one", "JP two"]
    - name: PINNED
      type: select
      proxies: ["JP two"]
rules:
    - DOMAIN-SUFFIX,lan,DIRECT
    - 'DOMAIN-SUFFIX,ads.test,REJECT' # explicit reject
    - DOMAIN-SUFFIX,pinned.test,PINNED
    - 'IP-CIDR,192.168.0.0/16,DIRECT,no-resolve'
    - "DOMAIN-SUFFIX,ai.test,PROXY" # selected existing policy
    - MATCH,PROXY
'''
PREFS={'schema':1,'enabled':True,'preferred_region':'SG','region_patterns':{'SG':'^SG','JP':'^JP'}}


class AdaptiveConfig(unittest.TestCase):
    def test_default_policy_preserves_explicit_routing_and_conditions(self):
        out=render(BASE,PREFS)
        self.assertIn('DOMAIN-SUFFIX,lan,DIRECT',out)
        self.assertIn('DOMAIN-SUFFIX,ads.test,REJECT',out)
        self.assertIn('DOMAIN-SUFFIX,pinned.test,PINNED',out)
        self.assertIn('IP-CIDR,192.168.0.0/16,DIRECT,no-resolve',out)
        self.assertIn('AND,((NETWORK,tcp),(DOMAIN-SUFFIX,ai.test)),'+GROUP,out)
        self.assertIn('NETWORK,tcp,'+GROUP,out)
        self.assertIn('    - name: '+GROUP,out)
        self.assertIn('      proxies: ["SG one", "JP two"]',out)
        self.assertIn('empty-fallback: "REJECT"',out)
        self.assertNotIn('include-all:',out)
        self.assertIn('"SG one": "SG"',out)
        self.assertIn('"JP two": "JP"',out)
        self.assertIn('# selected existing policy',out)
        self.assertEqual(render(out,PREFS),out)

    def test_optional_local_quality_lifecycle_is_rendered_without_default_enabling(self):
        self.assertNotIn('quality-persistence', render(BASE,PREFS))
        out=render(BASE,dict(PREFS,quality_persistence=True,quality_ttl=86400))
        self.assertIn('quality-persistence: true',out)
        self.assertIn('quality-ttl: 86400',out)

    def test_explicit_policy_override_and_reserved_collision(self):
        out=render(BASE,dict(PREFS,policies=['PINNED']))
        self.assertIn('AND,((NETWORK,tcp),(DOMAIN-SUFFIX,pinned.test)),'+GROUP,out)
        self.assertIn('MATCH,PROXY',out)
        for selected in ['DIRECT','REJECT','unknown']:
            with self.assertRaises(ConfigError): render(BASE,dict(PREFS,policies=[selected]))
        with self.assertRaises(ConfigError): render(BASE.replace('name: PINNED','name: '+GROUP),PREFS)

    def test_json_and_refresh_recompute_name_regions(self):
        config={'proxies':[{'name':'SG first','type':'http'}],'proxy-groups':[{'name':'PROXY','type':'select','include-all':True}],
                'rules':['DOMAIN-SUFFIX,lan,DIRECT','MATCH,PROXY']}
        rendered=json.loads(render(json.dumps(config),PREFS))
        self.assertEqual(rendered['rules'][0],config['rules'][0])
        self.assertEqual(rendered['rules'][1],'NETWORK,tcp,'+GROUP)
        self.assertEqual(rendered['rules'][2],'MATCH,PROXY')
        rendered['proxies']=[{'name':'JP new','type':'http'}]
        fresh=json.loads(render(json.dumps(rendered),PREFS))
        self.assertEqual(fresh['proxy-groups'][-1]['regions'],{'JP new':'JP'})

    def test_complex_yaml_is_rejected_instead_of_silently_rewritten(self):
        with self.assertRaises(ConfigError): render(BASE.replace('rules:\n','rules: [MATCH,PROXY]\n'),PREFS)
        with self.assertRaises(ConfigError): render(BASE.replace('- MATCH,PROXY','- {rule: MATCH,PROXY}'),PREFS)

    def test_yaml_service_scope_is_idempotent_and_recomputes_after_renumbering(self):
        node=entries(section(BASE,'proxies'))[1]
        prefs=dict(PREFS,services={'google-ai':{'domains':['ai.test'],'allowed_regions':['JP'],
            'verified_regions':{node_identity(node):'JP'}}})
        out=render(BASE,prefs)
        self.assertEqual(render(out,prefs),out)
        groups=[routing_entry(c) for c in entries(section(out,'proxy-groups'))]
        self.assertEqual(groups[-1]['proxies'],['JP two'])
        renamed=render(out.replace('JP two','JP99'),prefs)
        groups=[routing_entry(c) for c in entries(section(renamed,'proxy-groups'))]
        self.assertEqual(groups[-1]['proxies'],['JP99'])
        self.assertIn('DOMAIN-SUFFIX,lan,DIRECT',renamed)

    def test_opaque_node_transport_options_do_not_change_routing_fields(self):
        source=BASE.replace('      port: 12346', '      port: 12346\n      alpn:\n        - h2\n      smux:\n        type: h2mux')
        out=render(source,PREFS)
        self.assertIn('      alpn:\n        - h2\n      smux:\n        type: h2mux',out)
        self.assertIn('proxies: ["SG one", "JP two"]',out)
        with self.assertRaises(ConfigError):
            render(source+'rules:\n  - MATCH,DIRECT\n',PREFS)


if __name__=='__main__': unittest.main()
