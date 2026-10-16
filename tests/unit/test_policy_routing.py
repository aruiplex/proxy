import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'libexec'))
from adaptive_config import render
from routing_profile import ProfileError, node_identity


class PolicyRouting(unittest.TestCase):
    def config(self):
        return {'proxies': [
            {'name': 'HK01', 'type': 'http', 'server': '127.0.0.1', 'port': 1234},
            {'name': 'CA01', 'type': 'http', 'server': '127.0.0.1', 'port': 1235},
            {'name': 'US01', 'type': 'http', 'server': '127.0.0.1', 'port': 1236}],
            'proxy-groups': [
                {'name': 'DEFAULT', 'type': 'select', 'proxies': ['DIRECT', 'HK01', 'CA01']},
                {'name': 'PINNED', 'type': 'select', 'proxies': ['US01']}],
            'rules': ['DOMAIN,localhost,DIRECT', 'DOMAIN,ads.test,REJECT',
                      'DOMAIN,pinned.test,PINNED', 'MATCH,DEFAULT']}

    def test_legacy_direct_first_never_reintroduces_direct_or_widens_scope(self):
        out = json.loads(render(json.dumps(self.config()), {'direct_first': True}))
        adaptive = out['proxy-groups'][-1]
        self.assertEqual(adaptive['proxies'], ['HK01', 'CA01'])
        self.assertEqual(adaptive['empty-fallback'], 'REJECT')
        self.assertEqual(out['rules'][:3], self.config()['rules'][:3])
        self.assertEqual(json.loads(render(json.dumps(out), {'direct_first': True})), out)

    def test_selected_policies_keep_separate_candidate_scopes(self):
        out = json.loads(render(json.dumps(self.config()), {'policies': ['DEFAULT', 'PINNED']}))
        adaptive = [g for g in out['proxy-groups'] if g['type'] == 'adaptive']
        self.assertEqual([g['proxies'] for g in adaptive], [['HK01', 'CA01'], ['US01']])
        self.assertNotEqual(adaptive[0]['name'], adaptive[1]['name'])

    def test_service_requires_verified_identity_and_allowed_region(self):
        config = self.config()
        ca_id = node_identity(config['proxies'][1])
        prefs = {'services': {'google-ai': {'domains': ['googleapis.com'],
                   'allowed_regions': ['CA', 'US'], 'verified_regions': {ca_id: 'CA'}}}}
        out = json.loads(render(json.dumps(config), prefs))
        service = out['proxy-groups'][-1]
        self.assertEqual(service['proxies'], ['CA01'])
        self.assertEqual(service['regions'], {'CA01': 'CA'})
        self.assertEqual(out['rules'][:3], config['rules'][:3])
        self.assertIn('(DOMAIN-SUFFIX,googleapis.com)', out['rules'][3])
        # Renumbering retains the proven identity; endpoint changes invalidate it.
        config['proxies'][1]['name'] = 'CA99'
        config['proxy-groups'][0]['proxies'][2] = 'CA99'
        out = json.loads(render(json.dumps(config), prefs))
        self.assertEqual(out['proxy-groups'][-1]['proxies'], ['CA99'])
        config['proxies'][1]['port'] = 9999
        out = json.loads(render(json.dumps(config), prefs))
        self.assertEqual(out['proxy-groups'][-1]['proxies'], ['REJECT'])

    def test_empty_scope_and_unknown_provider_fail_closed(self):
        config = self.config()
        config['proxy-groups'][0]['proxies'] = ['DIRECT']
        out = json.loads(render(json.dumps(config), {}))
        self.assertEqual(out['proxy-groups'][-1]['proxies'], ['REJECT'])
        config['proxy-groups'][0]['use'] = ['unresolved']
        with self.assertRaises(ProfileError):
            render(json.dumps(config), {})

    def test_provider_name_is_not_region_verification(self):
        config = self.config()
        prefs = {'regions': {'CA01': 'CA'}, 'services': {'google-ai': {
            'domains': ['googleapis.com'], 'allowed_regions': ['CA'], 'verified_regions': {}}}}
        out = json.loads(render(json.dumps(config), prefs))
        self.assertEqual(out['proxy-groups'][-1]['proxies'], ['REJECT'])

    def test_identity_never_ignores_credentials_containing_name_text(self):
        for original in [
            '  - {type: http, password: "name: old", name: CA01, server: 127.0.0.1, port: 1234}\n',
            '  - type: http\n    password: "name: old"\n    name: CA01\n    server: 127.0.0.1\n    port: 1234\n',
            '  - type: http\n    headers:\n      name: old\n    name: CA01\n    server: 127.0.0.1\n    port: 1234\n']:
            self.assertEqual(node_identity(original),node_identity(original.replace('CA01','CA99')))
            self.assertNotEqual(node_identity(original),node_identity(original.replace('name: old','name: new')))


if __name__ == '__main__':
    unittest.main()
