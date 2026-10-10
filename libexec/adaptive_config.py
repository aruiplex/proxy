#!/usr/bin/env python3
"""Render a staged adaptive config while preserving existing rule conditions.

Handles JSON and conventional block YAML, rejecting unsupported structures
instead of guessing. Core -t remains the authoritative configuration check.
"""
import argparse
import json
import os
import re
import sys
from pathlib import Path

GROUP = 'AUTO-ADAPTIVE'
BEGIN = '# >>> adaptive (auto) >>>'
END = '# <<< adaptive (auto) <<<'


class ConfigError(ValueError):
    pass


def preferences(path):
    data = json.loads(Path(path).read_text())
    if data.get('schema') != 1 or data.get('enabled') is not True:
        raise ConfigError('选路偏好需要 schema=1 和 enabled=true')
    allowed = {'schema', 'enabled', 'policies', 'direct_first', 'preferred_region', 'regions', 'region_patterns', 'exclude',
               'max_attempts', 'dial_budget', 'attempt_timeout', 'failure_cooldown', 'max_records'}
    if set(data) - allowed:
        raise ConfigError('选路偏好含未知字段')
    if 'direct_first' in data and not isinstance(data['direct_first'], bool):
        raise ConfigError('direct_first 必须为布尔值')
    for key in ('regions', 'region_patterns'):
        if not isinstance(data.get(key, {}), dict):
            raise ConfigError(key + ' 必须为映射')
    if not isinstance(data.get('policies', []), list):
        raise ConfigError('policies 必须为列表')
    for key in ('policies',):
        if any(not isinstance(v, str) or not v or ',' in v or '\n' in v for v in data.get(key, [])):
            raise ConfigError('策略组名称无效')
    for key in ('regions', 'region_patterns'):
        if any(not isinstance(k, str) or not isinstance(v, str) or not k or not v for k,v in data.get(key, {}).items()):
            raise ConfigError(key + ' 的名称和值必须为非空字符串')
    for pattern in data.get('region_patterns', {}).values():
        re.compile(pattern)
    if 'exclude' in data:
        re.compile(data['exclude'])
    if 'preferred_region' in data and not isinstance(data['preferred_region'], str):
        raise ConfigError('preferred_region 必须为字符串')
    limits = {'max_attempts': (1,16), 'dial_budget': (1,30000), 'attempt_timeout': (1,30000),
              'failure_cooldown': (1,3600000), 'max_records': (1,65536)}
    for key,(low,high) in limits.items():
        if key in data and (type(data[key]) is not int or not low <= data[key] <= high):
            raise ConfigError(key + ' 超出允许范围')
    if data.get('attempt_timeout',2000) > data.get('dial_budget',6000):
        raise ConfigError('attempt_timeout 不能超过 dial_budget')
    return data


def scalar(text):
    text = text.strip()
    if text.startswith('"'):
        return json.JSONDecoder().raw_decode(text)[0]
    if text.startswith("'"):
        match = re.match(r"^'((?:[^']|'')*)'", text)
        if not match:
            raise ConfigError('不支持的 YAML 引号')
        return match[1].replace("''", "'")
    return text.split(' #', 1)[0].strip()


def section(lines, name):
    for start, line in enumerate(lines):
        if re.match('^' + name + r':', line):
            if line.strip() != name + ':':
                raise ConfigError(name + ' 需要块式 YAML；JSON 配置也受支持')
            end = start + 1
            while end < len(lines) and not re.match(r'^[A-Za-z][A-Za-z0-9_-]*:', lines[end]):
                end += 1
            return start, end
    raise ConfigError('配置缺少 ' + name)


def names(lines):
    result = []
    for line in lines:
        match = re.match(r'^\s*-\s*(?:\{\s*)?name:\s*(.*)', line)
        if match:
            raw = match[1]
            if line.lstrip().startswith('- {') and not raw.lstrip().startswith(('"', "'")):
                raw = raw.split(',', 1)[0].rstrip('} ')
            value = scalar(raw)
            if not isinstance(value, str) or not value:
                raise ConfigError('节点/策略名称无效')
            result.append(value)
    return result


def adaptive_group(prefs, node_names):
    regions = dict(prefs.get('regions', {}))
    for region, pattern in prefs.get('region_patterns', {}).items():
        regex = re.compile(pattern)
        for node in node_names:
            if regex.search(node) and node not in regions:
                regions[node] = region
    result = {'name': GROUP, 'type': 'adaptive', 'include-all': True, 'include-all-providers': True,
              'proxies': ['DIRECT'] if prefs.get('direct_first', True) else [], 'regions': regions}
    mapping = {'preferred_region': 'preferred-region', 'exclude': 'exclude-filter', 'max_attempts': 'max-attempts',
               'dial_budget': 'dial-budget', 'attempt_timeout': 'attempt-timeout', 'failure_cooldown': 'failure-cooldown', 'max_records': 'max-records'}
    for key, field in mapping.items():
        if key in prefs:
            result[field] = prefs[key]
    return result


def policy(rule):
    parts = rule.rsplit(',', 2)
    return parts[-2].strip() if parts[-1].strip() == 'no-resolve' else parts[-1].strip()


def select_policies(rules, groups, prefs):
    selected = prefs.get('policies') or list({policy(rule) for rule in rules if rule.startswith('MATCH,')})
    if not selected or any(name not in groups or name in ('DIRECT', 'REJECT', 'REJECT-DROP') for name in selected):
        raise ConfigError('请在 policies 中指定已有代理策略组；DIRECT/REJECT 不会被改写')
    return set(selected)


def tcp_rule(rule, selected):
    parts = rule.rsplit(',', 2)
    no_resolve = parts[-1].strip() == 'no-resolve'
    index = -2 if no_resolve else -1
    if parts[index].strip() not in selected:
        return None
    if rule.startswith('MATCH,'):
        return 'NETWORK,tcp,' + GROUP
    condition = ','.join(parts[:index])
    if no_resolve:
        condition += ',no-resolve'
    return 'AND,((NETWORK,tcp),(' + condition + ')),' + GROUP


def generated_rule(rule):
    return policy(rule) == GROUP and (rule.startswith('NETWORK,tcp,') or rule.startswith('AND,((NETWORK,tcp),('))


def render(text, prefs):
    try:
        config = json.loads(text)
    except ValueError:
        config = None
    if isinstance(config, dict):
        groups = config.get('proxy-groups', [])
        original_rules = [r for r in config.get('rules', []) if not generated_rule(r)]
        selected = select_policies(original_rules, {g['name'] for g in groups}, prefs)
        if any(g['name'] == GROUP and g.get('type') != 'adaptive' for g in groups):
            raise ConfigError('保留名称 AUTO-ADAPTIVE 已被其他策略使用')
        config['proxy-groups'] = [g for g in groups if g['name'] != GROUP] + [adaptive_group(prefs, [p['name'] for p in config.get('proxies', [])])]
        config['rules'] = []
        for rule in original_rules:
            candidate = tcp_rule(rule, selected)
            if candidate: config['rules'].append(candidate)
            config['rules'].append(rule)
        return json.dumps(config, ensure_ascii=False, indent=2) + '\n'
    # Owned blocks can be rebuilt after a subscription/pool update.
    owned = re.compile(r'(?m)^' + re.escape(BEGIN) + r'\n.*?^' + re.escape(END) + r'\n?', re.S)
    previous_owned = bool(owned.search(text))
    text = owned.sub('', text)
    text = re.sub(r'(?m)^.* # adaptive-tcp \(auto\)\n?', '', text)
    lines = text.splitlines(keepends=True)
    gs, ge = section(lines, 'proxy-groups')
    group_names = names(lines[gs + 1:ge])
    if GROUP in group_names:
        raise ConfigError('AUTO-ADAPTIVE 已存在但不属于本工具')
    rs, re_end = section(lines, 'rules')
    rule_rows, rules = [], []
    for index in range(rs + 1, re_end):
        line = lines[index]
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        match = re.match(r'^(\s*-\s+)(.+?)\s*\n?$', line)
        if not match:
            raise ConfigError('rules 需要块式字符串列表')
        raw = match[2]
        value = scalar(raw)
        if not isinstance(value, str):
            raise ConfigError('规则必须是字符串')
        comment = ''
        if raw.startswith('"'):
            _, end = json.JSONDecoder().raw_decode(raw)
            comment = raw[end:].strip()
        elif raw.startswith("'"):
            q = re.match(r"^'((?:[^']|'')*)'(.*)$", raw)
            comment = q[2].strip()
        elif ' #' in raw:
            comment = '#' + raw.split(' #', 1)[1]
        rule_rows.append((index, match[1], value, comment))
        rules.append(value)
    available = set(group_names) | ({GROUP} if previous_owned else set())
    selected = select_policies(rules, available, prefs)
    for index, prefix, value, comment in rule_rows:
        candidate = tcp_rule(value, selected)
        if candidate:
            lines[index] = prefix + json.dumps(candidate, ensure_ascii=False) + ' # adaptive-tcp (auto)\n' + lines[index]
    try:
        ps, pe = section(lines, 'proxies')
        node_names = names(lines[ps + 1:pe])
    except ConfigError:
        node_names = []  # provider-only configs need no local name mapping
    group = adaptive_group(prefs, node_names)
    entry = next((re.match(r'^(\s*)-\s+', line) for line in lines[gs + 1:ge] if re.match(r'^\s*-\s+', line)), None)
    indent = entry[1] if entry else '  '
    group_lines = [BEGIN + '\n', indent + '- name: ' + GROUP + '\n']
    for key, value in group.items():
        if key != 'name':
            group_lines.append(indent + '  ' + key + ': ' + json.dumps(value, ensure_ascii=False) + '\n')
    group_lines.append(END + '\n')
    lines[ge:ge] = group_lines
    return ''.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True, type=Path)
    parser.add_argument('--preferences', required=True, type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--in-place', action='store_true')
    args = parser.parse_args()
    os.umask(0o077)
    try:
        prefs = preferences(args.preferences)
        output = render(args.config.read_text(), prefs)
        if args.in_place:
            args.config.write_text(output)
        elif args.output:
            with args.output.open('x') as dest:
                dest.write(output)
        else:
            raise ConfigError('指定新的 --output 路径；--in-place 仅供订阅候选文件重放')
    except (OSError, ValueError, KeyError, TypeError, re.error) as error:
        message = str(error) if isinstance(error, ConfigError) else '自动选路配置生成失败；检查配置结构、偏好与输出路径'
        print('[proxy] ' + message, file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
