import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'libexec'))
from route_dependencies import NodeGraph,body
from adaptive_config import render


class RouteDependencies(unittest.TestCase):
    def config(self):
        return {'proxies':[
            {'name':'parent','type':'http','server':'old.example','port':443},
            {'name':'child','type':'http','server':'child.example','port':443,'dialer-proxy':'parent'}],
            'proxy-groups':[{'name':'POLICY','type':'select','proxies':['child']}],
            'rules':['MATCH,POLICY']}

    def test_parent_endpoint_change_removes_child_google_eligibility(self):
        config=self.config();graph=NodeGraph(config['proxies'],config['proxy-groups'])
        old=graph.identity('child')
        prefs={'services':{'google-ai':{'domains':['googleapis.com'],'allowed_regions':['US'],
                                      'verified_regions':{old:'US'}}}}
        before=json.loads(render(json.dumps(config),prefs))
        self.assertEqual(before['proxy-groups'][-1]['proxies'],['child'])
        config['proxies'][0]['server']='new.example'
        after=json.loads(render(json.dumps(config),prefs))
        self.assertEqual(after['proxy-groups'][-1]['proxies'],['REJECT'])

    def test_probe_closure_preserves_transitive_groups_and_opaque_credentials(self):
        config=self.config()
        config['proxies'][0]['password']='name: private-parent'
        config['proxies'][1]['dialer-proxy']='DIALER'
        config['proxy-groups'].append({'name':'DIALER','type':'fallback','url':'https://health.test',
                                      'proxies':['parent']})
        graph=NodeGraph(config['proxies'],config['proxy-groups']);nodes,groups=graph.closure('child')
        self.assertEqual(list(nodes),['parent','child'])
        self.assertEqual(list(groups),['DIALER'])
        self.assertIn('private-parent',body(nodes.values()))
        self.assertIn('https://health.test',body(groups.values()))

    def test_unsupported_dependency_does_not_block_independent_nodes(self):
        config=self.config();config['proxies'][1]['dialer-proxy']='missing'
        graph=NodeGraph(config['proxies'],config['proxy-groups'])
        self.assertEqual(len(graph.identity('child')),64)
        self.assertEqual(len(graph.identity('parent')),64)

    def test_type_exclusions_remove_false_cycles_from_dialer_groups(self):
        config=self.config();config['proxies'][0]['type']='socks5'
        config['proxies'][1]['dialer-proxy']='DIALER'
        config['proxy-groups'].append({'name':'DIALER','type':'select','include-all-proxies':True,'exclude-type':'http'})
        nodes,groups=NodeGraph(config['proxies'],config['proxy-groups']).closure('child')
        self.assertEqual(set(nodes),{'parent','child'})
        self.assertEqual(groups['DIALER']['proxies'],['parent'])

    def test_multiple_dialer_choices_are_not_qualified_using_a_scratch_default(self):
        config=self.config();config['proxies'][1]['dialer-proxy']='DIALER'
        config['proxies'].append({'name':'another','type':'http','server':'another.example','port':443})
        config['proxy-groups'].append({'name':'DIALER','type':'select','proxies':['parent','another']})
        graph=NodeGraph(config['proxies'],config['proxy-groups'])
        with self.assertRaises(ValueError):graph.closure('child')
        self.assertEqual(len(graph.identity('child')),64)
