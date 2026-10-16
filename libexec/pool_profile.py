"""Retain one subscription's routing profile while adding pooled nodes."""
import json
import re

from adaptive_config import policy
from routing_profile import ProfileError, entries, routing_entry, scalar, section, replace_section


def rebind(profile, renames, generated_groups, pool_entry, exclude=''):
    """Preserve rule ordering and provider groups; expand only MATCH's pool scope."""
    rules = section(profile, 'rules')
    policies = set()
    for line in rules.splitlines():
        match = re.match(r'^\s*-\s+(.+)', line)
        if match:
            rule = scalar(match[1])
            if rule.startswith('MATCH,'):
                policies.add(policy(rule))
    chunks = entries(section(profile, 'proxy-groups'))
    old_nodes = {routing_entry(c)['name'] for c in entries(section(profile, 'proxies'))}
    removed = old_nodes - set(renames)
    original_names = {routing_entry(c)['name'] for c in chunks}
    if original_names & {routing_entry(c)['name'] for c in entries(generated_groups)}:
        raise ProfileError('规则基准与节点池策略组名称冲突；请在基准中使用不同名称')
    result = []
    for chunk in chunks:
        group = routing_entry(chunk)
        members = group.get('proxies', [])
        if not isinstance(members, list):
            raise ProfileError('基准策略 proxies 需要列表')
        members = [renames.get(n, n) for n in members if n not in removed]
        if exclude:
            members = [n for n in members if not re.search(exclude, n)]
        if group['name'] in policies and pool_entry not in members:
            members.append(pool_entry)
        if not members and 'proxies' in group and not group.get('use') and not group.get('include-all'):
            members = ['REJECT']
        if chunk.lstrip().startswith('- {'):
            group['proxies'] = members
            if exclude:
                group['exclude-filter'] = '|'.join(filter(None, [group.get('exclude-filter', ''), exclude]))
            indent = re.match(r'^(\s*)-', chunk)[1]
            result.append(indent + '- ' + json.dumps(group, ensure_ascii=False) + '\n')
            continue
        lines = chunk.splitlines(keepends=True)
        start = next((i for i, line in enumerate(lines) if re.match(r'^\s+proxies:', line)), None)
        if start is None:
            if members:
                indent = re.match(r'^(\s*)-', lines[0])[1] + '  '
                lines.append(indent + 'proxies: ' + json.dumps(members, ensure_ascii=False) + '\n')
        else:
            indent = re.match(r'^(\s*)', lines[start])[1]
            end = start + 1
            while end < len(lines) and (not lines[end].strip() or len(lines[end]) - len(lines[end].lstrip()) > len(indent)
                                       or re.match(r'^' + re.escape(indent) + r'-\s', lines[end])):
                end += 1
            lines[start:end] = [indent + 'proxies: ' + json.dumps(members, ensure_ascii=False) + '\n']
        if exclude:
            expression = '|'.join(filter(None, [group.get('exclude-filter', ''), exclude]))
            indent = re.match(r'^(\s*)-', lines[0])[1] + '  '
            field = indent + 'exclude-filter: ' + json.dumps(expression, ensure_ascii=False) + '\n'
            row = next((i for i, line in enumerate(lines) if re.match(r'^\s+exclude-filter:', line)), None)
            if row is None:
                lines.append(field)
            else:
                lines[row] = field
        result.append(''.join(lines))
    # Subscription indentation varies; sibling YAML entries need one level.
    indent = re.match(r'^(\s*)-', chunks[0])[1] if chunks else '    '
    generated_indent = re.match(r'^(\s*)-', generated_groups)[1]
    generated_groups = ''.join(indent + line[len(generated_indent):] if line.strip() else line
                               for line in generated_groups.splitlines(keepends=True))
    return ''.join(result) + generated_groups, rules


def apply_profile(runtime, profile, renames, generated_groups, pool_entry, exclude=''):
    groups, rules = rebind(profile, renames, generated_groups, pool_entry, exclude)
    result = replace_section(runtime, 'proxy-groups', groups)
    result = replace_section(result, 'rules', rules)
    # Rule-provider definitions belong to the chosen baseline as well.
    providers = section(profile, 'rule-providers', required=False)
    result = re.sub(r'(?ms)^rule-providers:[^\n]*\n.*?(?=^[A-Za-z][\w-]*:|\Z)', '', result)
    if providers:
        result = replace_section(result, 'rule-providers', providers)
    return result
