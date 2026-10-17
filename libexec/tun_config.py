"""Host-local Linux TUN overlay; preserve opaque subscription/node YAML."""
import argparse
import json
import os
import re
import urllib.request
from pathlib import Path
from routing_profile import ProfileError, replace_section


def defaults(uid):
    return {'schema': 1, 'enabled': True, 'tun': {
        'enable': True, 'device': 'proxy-tun', 'stack': 'system',
        'auto-route': True, 'auto-redirect': True, 'auto-detect-interface': True,
        'dns-hijack': ['any:53', 'tcp://any:53'],
        'include-uid': [uid], 'strict-route': False,
        'inet6-address': ['fdfe:dcba:9876::1/126'],
        'route-exclude-address': ['127.0.0.0/8', '10.0.0.0/8', '172.16.0.0/12',
                                  '192.168.0.0/16', '100.64.0.0/10', '169.254.0.0/16',
                                  '::1/128', 'fc00::/7', 'fe80::/10']}}


def render(text, settings):
    if settings.get('schema') != 1 or type(settings.get('enabled')) is not bool or not isinstance(settings.get('tun'), dict):
        raise ProfileError('TUN 本机偏好格式错误')
    tun = dict(settings['tun'], enable=settings['enabled'])
    try:
        data = json.loads(text)
    except ValueError:
        data = None
    if isinstance(data, dict):
        data['tun'] = tun
        data['ipv6'] = True
        data.setdefault('sniffer', {'enable': True, 'parse-pure-ip': True,
            'sniff': {'TLS': {'ports': [443, 8443]}, 'HTTP': {'ports': [80, '8080-8880']}}})
        return json.dumps(data, ensure_ascii=False, indent=2) + '\n'
    for field in ('tun', 'ipv6', 'sniffer'):
        if len(re.findall(r'(?m)^' + field + ':', text)) > 1:
            raise ProfileError('TUN 配置字段重复: ' + field)
    text = replace_section(text, 'tun', ''.join('  ' + k + ': ' + json.dumps(v, ensure_ascii=False) + '\n' for k, v in tun.items()))
    if re.search(r'(?m)^ipv6:', text):
        text = re.sub(r'(?m)^ipv6:[^\n]*', 'ipv6: true', text)
    else:
        text += 'ipv6: true\n'
    if not re.search(r'(?m)^sniffer:', text):
        text += 'sniffer:\n  enable: true\n  parse-pure-ip: true\n  sniff:\n    TLS:\n      ports: [443, 8443]\n    HTTP:\n      ports: [80, 8080-8880]\n'
    return text


def verify(root, settings):
    """A successful controller reload can still fail to create the TUN device."""
    conf = dict(line.split('=', 1) for line in (root / 'proxy.conf').read_text().splitlines() if '=' in line)
    headers = {'Authorization': 'Bearer ' + conf['secret']} if conf.get('secret') else {}
    request = urllib.request.Request('http://' + conf.get('controller', '127.0.0.1:9090') + '/configs', headers=headers)
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=8) as response:
        actual = json.load(response).get('tun', {})
    enabled = settings['enabled']
    if actual.get('enable', False) != enabled:
        raise ValueError('controller did not activate requested TUN state')
    device = settings['tun'].get('device', 'proxy-tun')
    if not isinstance(device, str) or '/' in device or device in ('.', '..'):
        raise ValueError('invalid TUN device name')
    if (Path('/sys/class/net') / device).exists() != enabled:
        raise ValueError('actual TUN device does not match requested state')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path)
    parser.add_argument('--preferences', required=True, type=Path)
    parser.add_argument('--in-place', action='store_true')
    parser.add_argument('--verify-root', type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        prefs = json.loads(args.preferences.read_text())
        if args.verify_root:
            verify(args.verify_root, prefs)
        elif args.config and args.in_place:
            result = render(args.config.read_text(), prefs)
            args.config.write_text(result)
        else:
            raise ValueError('specify --config --in-place or --verify-root')
    except (OSError, ValueError, TypeError):
        parser.exit(1, '[proxy] TUN 候选生成失败；现用配置未替换。\n')


if __name__ == '__main__':
    main()
