"""Remove subscription information placeholders without interpreting node secrets."""
import re

from routing_profile import entries, replace_field, replace_section, routing_entry, section

INFO = re.compile(r'剩余流量|套餐|到期|重置|官网|客服|邮箱|支持AI')


def sanitize(text):
    nodes = entries(section(text, 'proxies'))
    removed = {routing_entry(c)['name'] for c in nodes if INFO.search(routing_entry(c)['name'])}
    text = replace_section(text, 'proxies', ''.join(c for c in nodes if routing_entry(c)['name'] not in removed))
    groups = []
    for chunk in entries(section(text, 'proxy-groups', required=False)):
        group = routing_entry(chunk)
        if 'proxies' in group:
            members = [n for n in group['proxies'] if n not in removed and not INFO.search(n)]
            if members != group['proxies']:
                chunk = replace_field(chunk, 'proxies', members or ['REJECT'])
        groups.append(chunk)
    if groups:
        text = replace_section(text, 'proxy-groups', ''.join(groups))
    return text
