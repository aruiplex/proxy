#!/usr/bin/env python3
"""Delegate lifecycle to the installed supervisor for this exact configuration.

Exit 3 means the caller should use the standalone lifecycle. Any other failure
must be propagated: a failed supervisor action must never spawn a second core.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

NOT_HANDLED = 3
UNIT = 'proxy-mihomo.service'


def supervisor(root):
    marker = root / 'supervisor.json'
    if not marker.exists():
        return 'user', UNIT
    data = json.loads(marker.read_text())
    expected = 'proxy-mihomo-%s.service' % os.getuid()
    if data != {'schema': 1, 'scope': 'system', 'unit': expected}:
        raise RuntimeError('invalid supervisor identity')
    return 'system', expected


def owned_unit(root, command, cgroup, scope='user', unit=UNIT):
    result = subprocess.run([command, '--' + scope, 'show', unit, '--property=LoadState,PIDFile,ControlGroup,User'],
                            capture_output=True, text=True, timeout=8)
    if result.returncode:
        # An installed unit with an unreachable manager must not silently be
        # bypassed. No unit on this machine remains a standalone installation.
        paths = ([Path.home() / '.config/systemd/user' / unit,
                  Path('/etc/systemd/user') / unit, Path('/usr/lib/systemd/user') / unit]
                 if scope == 'user' else [Path('/etc/systemd/system') / unit])
        if scope == 'system' or any(path.exists() for path in paths):
            raise RuntimeError('cannot inspect the installed supervisor')
        return None
    properties = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
    if properties.get('LoadState') != 'loaded':
        if scope == 'system':
            raise RuntimeError('selected system supervisor is not installed')
        return None
    pid_file = properties.get('PIDFile')
    if not pid_file or Path(pid_file).resolve() != (root / 'mihomo.pid').resolve():
        if scope == 'system':
            raise RuntimeError('system supervisor owns another configuration')
        return None
    if scope == 'system':
        import pwd
        if properties.get('User') not in (str(os.getuid()), pwd.getpwuid(os.getuid()).pw_name):
            raise RuntimeError('system supervisor runs as another user')
    group = properties.get('ControlGroup')
    # ExecStart invokes proxy start; inside this unit use the normal locked
    # worker rather than recursively waiting for systemctl start of ourselves.
    if group and any(item.split(':', 2)[-1] == group or item.split(':', 2)[-1].startswith(group + '/')
                     for item in cgroup.splitlines()):
        return None
    return unit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('action', choices=['start', 'stop', 'restart'])
    args = parser.parse_args()
    command = shutil.which('systemctl')
    proc = Path('/proc/self/cgroup')
    if not command or not proc.exists():
        if (args.root / 'supervisor.json').exists():
            print('[proxy] 已选择的 systemd 监督器不可用；未启动另一实例。', file=sys.stderr)
            return 1
        return NOT_HANDLED
    try:
        scope, selected = supervisor(args.root)
        unit = owned_unit(args.root, command, proc.read_text(), scope, selected)
        if not unit:
            return NOT_HANDLED
        result = subprocess.run([command, '--' + scope, '--no-ask-password', args.action, unit], capture_output=True, timeout=75)
        if result.returncode:
            print('[proxy] systemd 操作失败；未绕过监督器启动另一实例，请检查服务日志与控制权限。', file=sys.stderr)
            return 1
        print('systemd: %s %s 完成；启动后仍需独立业务验收。' % (args.action, unit))
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        print('[proxy] 无法完成 systemd 操作；保留监督器管理，请检查用户服务。', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
