"""Static dialer dependencies shared by qualification identities and probes."""
import hashlib
import json
import re

from routing_profile import ProfileError, node_identity, routing_entry, replace_field

BUILTINS = {'DIRECT', 'REJECT', 'REJECT-DROP', 'COMPATIBLE', 'PASS'}


class NodeGraph:
    def __init__(self, nodes, groups):
        self.nodes = {(n if isinstance(n, dict) else routing_entry(n))['name']: n for n in nodes}
        self.groups = {(g if isinstance(g, dict) else routing_entry(g))['name']: g for g in groups}

    def closure(self, name):
        selected_nodes, selected_groups = {}, {}
        def visit(current, stack=()):
            if current in BUILTINS:
                return
            if current in stack:
                raise ProfileError('代理拨号依赖循环')
            if current in selected_nodes or current in selected_groups:
                return
            chain = stack + (current,)
            if current in self.nodes:
                chunk = self.nodes[current]
                node = chunk if isinstance(chunk, dict) else routing_entry(chunk)
                if node.get('dialer-proxy'):
                    visit(node['dialer-proxy'], chain)
                selected_nodes[current] = chunk
            elif current in self.groups:
                chunk = self.groups[current]
                group = chunk if isinstance(chunk, dict) else routing_entry(chunk)
                if group.get('use') or group.get('include-all-providers'):
                    raise ProfileError('拨号依赖需要可确定的静态策略范围')
                members = list(group.get('proxies', []))
                if group.get('include-all') or group.get('include-all-proxies'):
                    members += [n for n in self.nodes if not group.get('filter') or re.search(group['filter'], n)]
                effective = []
                excluded = str(group.get('exclude-type', '')).lower().split('|')
                for member in dict.fromkeys(members):
                    if group.get('exclude-filter') and re.search(group['exclude-filter'], member):
                        continue
                    if member in self.nodes:
                        item = self.nodes[member]
                        item = item if isinstance(item, dict) else routing_entry(item)
                        if item.get('type', '').lower() in excluded:
                            continue
                    effective.append(member)
                if len(effective) != 1:
                    raise ProfileError('独立验证需要确定的单成员拨号策略')
                visit(effective[0], chain)
                selected_groups[current] = (dict(chunk, proxies=effective) if isinstance(chunk, dict)
                                            else replace_field(chunk, 'proxies', effective))
            else:
                raise ProfileError('代理拨号依赖不存在')
        visit(name)
        return selected_nodes, selected_groups

    def identity(self, name):
        chunk = self.nodes[name]
        node = chunk if isinstance(chunk, dict) else routing_entry(chunk)
        own = node_identity(chunk)
        if not node.get('dialer-proxy'):
            return own
        try:
            nodes, groups = self.closure(name)
        except ProfileError:
            # Keep an unsupported node imported and unqualified without blocking
            # independent candidates. Its isolated probe reports configuration.
            nodes, groups = self.nodes, self.groups
            own = 'unverifiable:' + own
        dependencies = [('node', n, node_identity(c)) for n, c in nodes.items() if n != name]
        dependencies += [('group', n, node_identity(c)) for n, c in groups.items()]
        return hashlib.sha256(json.dumps([own, sorted(dependencies)], ensure_ascii=False).encode()).hexdigest()


def body(chunks, indent=2):
    result = []
    for chunk in chunks:
        if isinstance(chunk, dict):
            result.append(' ' * indent + '- ' + json.dumps(chunk, ensure_ascii=False) + '\n')
        else:
            old_indent = len(re.match(r'^([ \t]*)-', chunk)[1])
            result.extend(' ' * indent + line[old_indent:] if line.strip() else line
                          for line in chunk.splitlines(keepends=True))
    return ''.join(result)
