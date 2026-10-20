"""Read the routing fields of conventional YAML without rewriting opaque data.

This is intentionally not a general YAML loader. Unsupported routing structures
fail before a candidate can replace the live configuration.
"""
import hashlib
import json
import re


class ProfileError(ValueError):
    pass


def scalar(raw):
    raw = raw.strip()
    if raw.startswith('"'):
        value, end = json.JSONDecoder().raw_decode(raw)
        if raw[end:].strip() and not raw[end:].lstrip().startswith('#'):
            raise ProfileError('不支持的 YAML 标量')
        return value
    if raw.startswith("'"):
        match = re.fullmatch(r"'((?:[^']|'')*)'\s*(?:#.*)?", raw)
        if not match:
            raise ProfileError('不支持的 YAML 引号')
        return match[1].replace("''", "'")
    raw = raw.split(' #', 1)[0].strip()
    if raw.startswith(('*', '&', '!', '|', '>')):
        raise ProfileError('选路字段不支持 YAML 别名或多行标量')
    if raw in ('true', 'false'):
        return raw == 'true'
    return raw


def split_flow(raw):
    parts, start, quote, depth, i = [], 0, None, 0, 0
    while i < len(raw):
        c = raw[i]
        if quote:
            if c == '\\' and quote == '"':
                i += 2
                continue
            if c == quote:
                if quote == "'" and i + 1 < len(raw) and raw[i + 1] == "'":
                    i += 2
                    continue
                quote = None
        elif c in ('"', "'"):
            quote = c
        elif c in '[{':
            depth += 1
        elif c in ']}':
            depth -= 1
        elif c == ',' and depth == 0:
            parts.append(raw[start:i].strip())
            start = i + 1
        i += 1
    if quote or depth:
        raise ProfileError('不完整的 YAML 行内结构')
    return parts + ([raw[start:].strip()] if raw[start:].strip() else [])


def value(raw):
    raw = raw.strip()
    if raw.startswith('['):
        if not raw.endswith(']'):
            raise ProfileError('不支持的 YAML 列表')
        return [scalar(x) for x in split_flow(raw[1:-1])]
    if raw.startswith('{'):
        if not raw.endswith('}'):
            raise ProfileError('不支持的 YAML 映射')
        result = {}
        for item in split_flow(raw[1:-1]):
            key, sep, val = item.partition(':')
            key = scalar(key)
            if not sep or key in result:
                raise ProfileError('不支持或重复的 YAML 字段')
            result[key] = value(val)
        return result
    return scalar(raw)


def section(text, key, required=True):
    lines = text.splitlines(keepends=True)
    if sum(bool(re.match(r'^' + re.escape(key) + ':', line)) for line in lines) > 1:
        raise ProfileError('配置字段重复: ' + key)
    for i, line in enumerate(lines):
        if re.match(r'^' + re.escape(key) + ':', line):
            if line.strip() != key + ':':
                raise ProfileError(key + ' 需要块式 YAML')
            end = i + 1
            while end < len(lines) and not re.match(r'^[A-Za-z][\w-]*:', lines[end]):
                end += 1
            return ''.join(lines[i + 1:end])
    if required:
        raise ProfileError('配置缺少 ' + key)
    return ''


def entries(body):
    rows = list(re.finditer(r'(?m)^([ \t]*)-\s+', body))
    indent = min((len(m[1]) for m in rows), default=0)
    starts = [m for m in rows if len(m[1]) == indent]
    if body.strip() and not starts:
        raise ProfileError('需要以 name 开头的节点/策略列表')
    if starts and body[:starts[0].start()].strip().strip('#'):
        # Comments are harmless; any other prefix is not a supported entry.
        if any(x.strip() and not x.lstrip().startswith('#') for x in body[:starts[0].start()].splitlines()):
            raise ProfileError('不支持的节点/策略列表')
    return [body[m.start():starts[i + 1].start() if i + 1 < len(starts) else len(body)]
            for i, m in enumerate(starts)]


def routing_entry(chunk):
    lines = chunk.splitlines()
    field_indent = len(re.match(r'^(\s*)-', lines[0])[1]) + 2
    first = re.sub(r'^\s*-\s+', '', lines[0])
    if first.startswith('{'):
        return value(first)
    result, list_key = {}, None
    for i, line in enumerate(lines):
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        if i:
            indent = len(line) - len(line.lstrip())
            if indent > field_indent:
                if list_key and line.lstrip().startswith('- '):
                    result[list_key].append(scalar(line.lstrip()[2:]))
                continue
        line = first if i == 0 else line.strip()
        if line.startswith('- '):
            if list_key is None:
                raise ProfileError('不支持的策略列表结构')
            result[list_key].append(scalar(line[2:]))
            continue
        key, sep, raw = line.partition(':')
        key = scalar(key)
        # Only the routing fields are interpreted; other nested fields stay opaque.
        if not sep or key not in {'name', 'type', 'proxies', 'use', 'include-all', 'include-all-proxies',
                                  'include-all-providers', 'filter', 'exclude-filter', 'exclude-type', 'dialer-proxy'}:
            list_key = None
            continue
        if key in result:
            raise ProfileError('策略字段重复: ' + key)
        if not raw.strip() and key in ('proxies', 'use'):
            result[key], list_key = [], key
        else:
            result[key], list_key = value(raw), None
    return result


def replace_field(chunk, key, replacement):
    """Edit one root field, preserving opaque credentials and nested options."""
    lines = chunk.splitlines(keepends=True)
    indent = re.match(r'^([ \t]*)-', lines[0])[1]
    first = re.sub(r'^\s*-\s+', '', lines[0]).strip()
    encoded = json.dumps(replacement, ensure_ascii=False)
    if first.startswith('{'):
        fields = split_flow(first[1:-1])
        found = False
        for i, field in enumerate(fields):
            if scalar(field.partition(':')[0]) == key:
                fields[i] = key + ': ' + encoded
                found = True
        if not found:
            fields.append(key + ': ' + encoded)
        return indent + '- {' + ', '.join(fields) + '}\n'
    field_indent = len(indent) + 2
    for i, line in enumerate(lines):
        raw = first if i == 0 else line.strip()
        if i and len(line) - len(line.lstrip()) != field_indent:
            continue
        if scalar(raw.partition(':')[0]) != key:
            continue
        end = i + 1
        while end < len(lines):
            row = lines[end]
            level = len(row) - len(row.lstrip())
            if row.strip() and level <= field_indent and not (level == field_indent and row.lstrip().startswith('- ')):
                break
            end += 1
        prefix = indent + '- ' if i == 0 else ' ' * field_indent
        lines[i:end] = [prefix + key + ': ' + encoded + '\n']
        return ''.join(lines)
    return chunk.rstrip('\n') + '\n' + ' ' * field_indent + key + ': ' + encoded + '\n'


def replace_section(text, key, body):
    pattern = r'(?ms)^' + re.escape(key) + r':[^\n]*\n.*?(?=^[A-Za-z][\w-]*:|\Z)'
    replacement = key + ':\n' + body.rstrip('\n') + '\n'
    if re.search(pattern, text):
        return re.sub(pattern, lambda _: replacement, text, count=1)
    return text.rstrip('\n') + '\n' + replacement


def node_identity(node):
    """Conservative identity: renumbering survives; credential/endpoint edits don't."""
    if isinstance(node, dict):
        data = json.dumps({k: v for k, v in node.items() if k != 'name'}, sort_keys=True, ensure_ascii=False)
    else:
        first = re.sub(r'^\s*-\s+', '', node.splitlines()[0])
        if first.startswith('{'):
            # Split at actual mapping fields, never at text inside credentials.
            fields = split_flow(first[1:-1])
            data = '- {' + ', '.join('name: NODE' if scalar(f.partition(':')[0]) == 'name' else f for f in fields) + '}'
        else:
            if first.startswith('name:'):
                data = re.sub(r'^(\s*-\s+name:)\s*[^\n]+', r'\1 NODE', node, count=1)
            else:
                indent = re.match(r'^(\s*)-', node)[1] + '  '
                data = re.sub(r'(?m)^' + re.escape(indent) + r'name:\s*[^\n]+', indent + 'name: NODE', node, count=1)
        data = '\n'.join(x.strip() for x in data.splitlines() if x.strip() and not x.lstrip().startswith('#'))
    return hashlib.sha256(data.encode()).hexdigest()
