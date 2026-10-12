#!/usr/bin/env python3
"""Read-only routing overview and target feedback via the local controller."""
import argparse
import datetime
import ipaddress
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


class UsageError(ValueError):
    """An actionable local error safe to display without controller details."""


class CLIParser(argparse.ArgumentParser):
    def error(self, message):
        hint = 'proxy help' if self.prog == 'proxy' else self.prog + ' --help'
        self.exit(2, '[proxy] 参数无效: ' + message + '\n运行 ' + hint + ' 查看用法\n')


def target_key(value):
    """The kernel keys evidence by lowercase host:port, never by service name."""
    if not value or any(c.isspace() for c in value) or any(c in value for c in '/?#@'):
        raise UsageError('目标格式: 域名[:端口]，默认端口 443；IPv6 请用 [地址]:端口')
    try:
        parsed = urllib.parse.urlsplit('//' + value)
        host = parsed.hostname
        port = parsed.port if parsed.port is not None else 443
        if not host or not 1 <= port <= 65535 or value.endswith(':'):
            raise ValueError()
        if ':' in host:
            host = '[' + str(ipaddress.IPv6Address(host)) + ']'
        else:
            host = host.encode('idna').decode('ascii').lower()
            if any(c not in 'abcdefghijklmnopqrstuvwxyz0123456789.-_' for c in host):
                raise ValueError()
        return host + ':' + str(port)
    except (ValueError, UnicodeError):
        raise UsageError('目标格式: 域名[:端口]，端口范围 1–65535；IPv6 请用 [地址]:端口') from None


class Controller:
    def __init__(self, root, budget=8):
        file = root / 'proxy.conf'
        settings = dict(line.split('=', 1) for line in file.read_text().splitlines() if '=' in line) if file.exists() else {}
        self.address = settings.get('controller', '127.0.0.1:9090')
        self.headers = {'Content-Type': 'application/json'}
        if settings.get('secret'):
            self.headers['Authorization'] = 'Bearer ' + settings['secret']
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        self.deadline = time.monotonic() + budget

    def request(self, path, body=None):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError()
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request('http://' + self.address + path, data=data, headers=self.headers)
        with self.opener.open(request, timeout=remaining) as response:
            raw = response.read()
            return json.loads(raw) if raw else None

    def groups(self):
        proxies = self.request('/proxies')['proxies']
        return sorted(name for name, value in proxies.items() if value.get('type') == 'Adaptive')

    def quality(self, group):
        result = self.request('/proxies/' + urllib.parse.quote(group, safe='') + '/quality')
        if not isinstance(result, dict) or not isinstance(result.get('records') or [], list):
            raise ValueError()
        for row in result.get('records') or []:
            if not isinstance(row, dict) or not isinstance(row.get('target'), str) or not isinstance(row.get('node'), str):
                raise ValueError()
            selection = row.get('selection', 0)
            if isinstance(selection, bool) or not isinstance(selection, int) or selection < 0:
                raise ValueError()
        return result

    def feedback_group(self, target, explicit=None):
        groups = self.groups()
        if explicit:
            if explicit not in groups:
                raise UsageError('指定组不支持自动选路；运行 proxy 查看状态')
            groups = [explicit]
        matches = []
        # Read every candidate: an unreadable group cannot establish uniqueness.
        for group in groups:
            if any(row['target'] == target and row.get('selection', 0) > 0
                   for row in self.quality(group).get('records') or []):
                matches.append(group)
        if len(matches) == 1:
            return matches[0]
        if not matches:
            raise UsageError('尚无该目标的成功建立记录；运行 proxy 查看近期目标，并使用准确的域名与端口')
        raise UsageError('该目标出现在多个组: ' + ', '.join(matches) + '；请使用 --group NAME，不会同时反馈多个组')


def established_time(row):
    try:
        return datetime.datetime.fromisoformat(row.get('lastEstablished', '').replace('Z', '+00:00')).timestamp()
    except (ValueError, TypeError, AttributeError, OverflowError):
        return 0


def overview(root, controller, pid):
    try:
        version = controller.request('/version').get('version', 'mihomo')
        print('代理: 控制器可达 · ' + str(version) + (' · PID ' + pid if pid else ''))
        available = True
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        print('代理: ' + ('进程仍在 · PID ' + pid if pid else '未检测到本机进程') + ' · 控制器不可达或认证失败')
        available = False
    state = root / 'env.state'
    enabled = state.exists() and state.read_text().strip() == 'on'
    print('终端代理设置: ' + ('on' if enabled else 'off') + ' · proxy on / proxy off')
    if available:
        try:
            groups = controller.groups()
            print('自动选路: ' + (str(len(groups)) + ' 个组，按目标选择线路' if groups else '当前无 Adaptive 组'))
            recent = []
            for group in groups:
                latest = {}
                for row in controller.quality(group).get('records') or []:
                    if row.get('selection', 0) > 0:
                        previous = latest.get(row['target'])
                        if previous is None or row['selection'] > previous['selection']:
                            latest[row['target']] = row
                recent.extend((group, row) for row in latest.values())
            recent.sort(key=lambda pair: (-established_time(pair[1]), pair[1]['target'], pair[0]))
            if recent:
                print('近期目标（最近建立记录，非业务成功证明）:')
                for group, row in recent[:5]:
                    print('  ' + row['target'] + ' → ' + row['node'] + ' [' + group + ']')
                if len(recent) > 5:
                    print('  更多记录: proxy quality --group NAME')
            elif groups:
                print('近期目标: 尚无成功建立记录')
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            print('近期目标: 质量记录暂不可读；未推断当前线路')
    print('线路不好用: proxy next 域名[:端口]；帮助: proxy help')
    return 0


def main():
    parser = CLIParser(prog='proxy', description=__doc__)
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--group')
    parser.add_argument('--json', action='store_true')
    sub = parser.add_subparsers(dest='command', required=True, prog='proxy')
    quality = sub.add_parser('quality')
    quality.add_argument('--target')
    for name in ('feedback', 'next'):
        feedback = sub.add_parser(name)
        feedback.add_argument('target')
        feedback.add_argument('--reason', choices=['unknown', 'timeout', 'disconnect', 'unusable'], default='unusable')
    summary = sub.add_parser('overview')
    summary.add_argument('--pid', default='')
    args = parser.parse_args()
    try:
        # Validate local arguments before any controller access.
        target = target_key(args.target) if args.command == 'next' else None
        controller = Controller(args.root, budget=4 if args.command == 'overview' else 8)
        if args.command == 'overview':
            return overview(args.root, controller, args.pid)
        group = args.group
        if args.command == 'next':
            group = controller.feedback_group(target, group)
        elif not group:
            groups = controller.groups()
            if len(groups) != 1:
                raise UsageError('需要一个 adaptive 组；多个组时请使用 --group NAME')
            group = groups[0]
        path = '/proxies/' + urllib.parse.quote(group, safe='')
        if args.command in ('feedback', 'next'):
            controller.request(path + '/feedback', {'target': target or args.target, 'reason': args.reason})
            print('已反馈' + (' ' + target + ' [' + group + ']' if target else '') + '；该目标后续连接重新选路，已有健康连接保持。')
            return 0
        result = controller.quality(group)
        if args.target:
            result = dict(result, records=[r for r in (result.get('records') or []) if r['target'] == args.target],
                          events=[e for e in (result.get('events') or []) if e['target'] == args.target])
        if args.json:
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return 0
        print('组: ' + group)
        records = result.get('records') or []
        targets = sorted({r['target'] for r in records})
        for target in targets:
            rows = [r for r in records if r['target'] == target]
            latest = max(rows, key=lambda r: r.get('selection', 0))
            chosen = latest['node'] if latest.get('selection', 0) else '尚未建立'
            print(target + ' · 最近建立线路: ' + chosen)
            for row in rows:
                print('  %s · 建立 %s / 尝试 %s / 失败 %s · %s' % (row['node'], row['established'], row['dials'], row['failures'], row.get('reason') or '无故障证据'))
        if not targets:
            print('尚无该目标的质量记录。')
        print('建立成功不代表加密业务成功；记录只保存在本机，原因可能未知。')
        return 0
    except UsageError as error:
        print('[proxy] ' + str(error), file=sys.stderr)
    except urllib.error.HTTPError as error:
        messages = {400: '目标尚未观察到或已被淘汰；运行 proxy 查看近期目标',
                    401: '控制器认证失败，检查本机配置',
                    404: '当前内核或组不支持目标质量接口；请检查内核及 adaptive 配置'}
        print('[proxy] ' + messages.get(error.code, '控制器拒绝请求，HTTP ' + str(error.code)), file=sys.stderr)
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        print('[proxy] 控制器不可达或响应无效；检查 proxy status 和 adaptive 配置', file=sys.stderr)
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
