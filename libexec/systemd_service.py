#!/usr/bin/env python3
"""Delegate lifecycle to an existing user unit for this exact configuration.

Exit 3 means the caller should use the standalone lifecycle. Any other failure
must be propagated: a failed supervisor action must never spawn a second core.
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

NOT_HANDLED = 3
UNIT = 'proxy-mihomo.service'


def owned_unit(root, command, cgroup):
    result = subprocess.run([command, '--user', 'show', UNIT, '--property=LoadState,PIDFile,ControlGroup'],
                            capture_output=True, text=True, timeout=8)
    if result.returncode:
        # An installed unit with an unreachable manager must not silently be
        # bypassed. No unit on this machine remains a standalone installation.
        paths = [Path.home() / '.config/systemd/user' / UNIT,
                 Path('/etc/systemd/user') / UNIT, Path('/usr/lib/systemd/user') / UNIT]
        if any(path.exists() for path in paths):
            raise RuntimeError('cannot inspect the installed supervisor')
        return None
    properties = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
    if properties.get('LoadState') != 'loaded':
        return None
    pid_file = properties.get('PIDFile')
    if not pid_file or Path(pid_file).resolve() != (root / 'mihomo.pid').resolve():
        return None
    group = properties.get('ControlGroup')
    # ExecStart invokes proxy start; inside this unit use the normal locked
    # worker rather than recursively waiting for systemctl start of ourselves.
    if group and any(item.split(':', 2)[-1] == group or item.split(':', 2)[-1].startswith(group + '/')
                     for item in cgroup.splitlines()):
        return None
    return UNIT


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('action', choices=['start', 'stop', 'restart'])
    args = parser.parse_args()
    command = shutil.which('systemctl')
    proc = Path('/proc/self/cgroup')
    if not command or not proc.exists():
        return NOT_HANDLED
    try:
        unit = owned_unit(args.root, command, proc.read_text())
        if not unit:
            return NOT_HANDLED
        result = subprocess.run([command, '--user', args.action, unit], capture_output=True, timeout=75)
        if result.returncode:
            print('[proxy] systemd 操作失败；未绕过监督器启动另一实例，请检查用户服务日志。', file=sys.stderr)
            return 1
        print('systemd: %s %s 完成；启动后仍需独立业务验收。' % (args.action, unit))
        return 0
    except (OSError, RuntimeError, subprocess.SubprocessError):
        print('[proxy] 无法完成 systemd 操作；保留监督器管理，请检查用户服务。', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
