#!/usr/bin/env python3
"""Target quality and feedback; uses the local controller without proxy env."""
import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--group')
    parser.add_argument('--json', action='store_true')
    sub = parser.add_subparsers(dest='command', required=True)
    quality = sub.add_parser('quality')
    quality.add_argument('--target')
    feedback = sub.add_parser('feedback')
    feedback.add_argument('target')
    feedback.add_argument('--reason', choices=['unknown', 'timeout', 'disconnect', 'unusable'], default='unusable')
    args = parser.parse_args()
    try:
        file = args.root / 'proxy.conf'
        settings = dict(line.split('=', 1) for line in file.read_text().splitlines() if '=' in line) if file.exists() else {}
        controller = settings.get('controller', '127.0.0.1:9090')
        headers = {}
        if settings.get('secret'):
            headers['Authorization'] = 'Bearer ' + settings['secret']
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

        def request(path, body=None):
            data = json.dumps(body).encode() if body is not None else None
            req = urllib.request.Request('http://' + controller + path, data=data, headers=dict(headers, **{'Content-Type': 'application/json'}))
            with opener.open(req, timeout=8) as response:
                raw = response.read()
                return json.loads(raw) if raw else None

        group = args.group
        if not group:
            groups = [name for name, value in request('/proxies').get('proxies', {}).items() if value.get('type') == 'Adaptive']
            if len(groups) != 1:
                raise ValueError('需要一个 adaptive 组；多个组时请使用 --group NAME')
            group = groups[0]
        path = '/proxies/' + urllib.parse.quote(group, safe='')
        if args.command == 'feedback':
            request(path + '/feedback', {'target': args.target, 'reason': args.reason})
            print('已反馈；该目标后续连接重新选路，已有健康连接保持。')
            return 0
        result = request(path + '/quality')
        if args.target:
            result = dict(result, records=[r for r in (result.get('records') or []) if r['target'] == args.target],
                          events=[e for e in (result.get('events') or []) if e['target'] == args.target])
        if args.json:
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return 0
        print('组: ' + group)
        records = (result.get('records') or [])
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
    except urllib.error.HTTPError as error:
        messages = {400: '目标尚未观察到或已被淘汰；先用 proxy quality 查看目标键',
                    401: '控制器认证失败，检查本机配置',
                    404: '当前内核或组不支持目标质量接口；请检查实验内核及 adaptive 配置'}
        print('[proxy] ' + messages.get(error.code, '控制器拒绝请求，HTTP ' + str(error.code)), file=sys.stderr)
    except (OSError, ValueError, KeyError, TypeError) as error:
        message = str(error) if type(error) is ValueError and str(error).startswith('需要一个') else '控制器不可达或响应无效；检查 proxy status 和 adaptive 配置'
        print('[proxy] ' + message, file=sys.stderr)
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
