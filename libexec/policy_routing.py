"""Compile proxy-only candidate scopes and application eligibility constraints."""
import hashlib
import re

from routing_profile import ProfileError

PREFIX = 'AUTO-ADAPTIVE'
BUILTINS = {'DIRECT', 'REJECT', 'REJECT-DROP', 'PASS', 'COMPATIBLE', 'GLOBAL'}


def compile_groups(groups, nodes, prefs, selected, hints=None, providers=False):
    by_name = {g['name']: g for g in groups}
    node_names = {n['name']: n for n in nodes}
    if len(by_name) != len(groups) or len(node_names) != len(nodes):
        raise ProfileError('节点或策略组名称重复')
    regions = dict(hints or {})
    for region, pattern in prefs.get('region_patterns', {}).items():
        for name in node_names:
            if re.search(pattern, name):
                regions.setdefault(name, region)
    regions.update(prefs.get('regions', {}))

    def scope(name, seen=()):
        if name in BUILTINS:
            return []
        if name in node_names:
            return [name] if node_names[name].get('type') not in ('direct', 'reject', 'pass') else []
        if name in seen or name not in by_name:
            raise ProfileError('代理策略包含循环或未知引用；请检查原策略范围')
        group = by_name[name]
        if group.get('use') or group.get('include-all-providers') or (providers and group.get('include-all')):
            raise ProfileError('自动选路需要可确定范围的静态节点；请先通过节点池展开 provider')
        members = list(group.get('proxies', []))
        if group.get('include-all') or group.get('include-all-proxies'):
            added = list(node_names)
            if group.get('filter'):
                added = [n for n in added if re.search(group['filter'], n)]
            members.extend(added)
        found = []
        for member in members:
            for candidate in scope(member, seen + (name,)):
                if group.get('exclude-filter') and re.search(group['exclude-filter'], candidate):
                    continue
                excluded = str(group.get('exclude-type', '')).lower().split('|')
                if node_names[candidate].get('type', '').lower() in excluded:
                    continue
                if candidate not in found:
                    found.append(candidate)
        return found

    result, routes = [], {}
    for policy in sorted(selected):
        candidates = scope(policy)
        if prefs.get('exclude'):
            candidates = [n for n in candidates if not re.search(prefs['exclude'], n)]
        name = PREFIX if len(selected) == 1 else PREFIX + '-' + hashlib.sha256(policy.encode()).hexdigest()[:10]
        result.append(make_group(name, candidates, regions, prefs))
        routes[policy] = {'default': name, 'services': []}
        for service, constraint in prefs.get('services', {}).items():
            verified = constraint['verified_regions']
            eligible = []
            service_regions = {}
            for node in candidates:
                region = verified.get(node_names[node]['identity'])
                if region in constraint['allowed_regions']:
                    eligible.append(node)
                    service_regions[node] = region
            service_name = PREFIX + '-' + hashlib.sha256((policy + '\n' + service).encode()).hexdigest()[:10]
            result.append(make_group(service_name, eligible, service_regions, prefs))
            routes[policy]['services'].append((constraint['domains'], service_name))
    return result, routes


def make_group(name, nodes, regions, prefs):
    # An explicit rejecting member also works on kernels that require proxies/use.
    result = {'name': name, 'type': 'adaptive', 'proxies': nodes or ['REJECT'],
              'empty-fallback': 'REJECT', 'regions': {n: regions[n] for n in nodes if n in regions}}
    mapping = {'preferred_region': 'preferred-region', 'max_attempts': 'max-attempts',
               'dial_budget': 'dial-budget', 'attempt_timeout': 'attempt-timeout',
               'failure_cooldown': 'failure-cooldown', 'max_records': 'max-records',
               'quality_persistence': 'quality-persistence', 'quality_ttl': 'quality-ttl'}
    for key, field in mapping.items():
        if key in prefs:
            result[field] = prefs[key]
    return result


def tcp_rules(rule, routes):
    parts = rule.rsplit(',', 2)
    index = -2 if parts[-1].strip() == 'no-resolve' else -1
    route = routes.get(parts[index].strip())
    if not route:
        return []
    condition = ','.join(parts[:index])
    if index == -2:
        condition += ',no-resolve'
    match_all = rule.startswith('MATCH,')
    base = ['(NETWORK,tcp)'] + ([] if match_all else ['(' + condition + ')'])
    result = []
    for domains, name in route['services']:
        domain = '(OR,(' + ','.join('(DOMAIN-SUFFIX,' + d + ')' for d in domains) + '))'
        result.append('AND,(' + ','.join(base + [domain]) + '),' + name)
    result.append(('NETWORK,tcp,' if match_all else 'AND,(' + ','.join(base) + '),') + route['default'])
    return result
