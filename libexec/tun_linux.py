"""Reload Linux TUN only through the installed capability-bearing supervisor."""
import argparse
import json
import os
import shutil
import subprocess
import tempfile
import urllib.request
from pathlib import Path
from systemd_service import supervisor, owned_unit
from tun_config import defaults, render, verify


def reload_config(root):
    settings = dict(line.split('=', 1) for line in (root / 'proxy.conf').read_text().splitlines() if '=' in line)
    headers = {'Content-Type': 'application/json'}
    if settings.get('secret'):
        headers['Authorization'] = 'Bearer ' + settings['secret']
    request = urllib.request.Request('http://' + settings.get('controller', '127.0.0.1:9090') + '/configs?force=true',
        data=json.dumps({'path': str(root / 'config.yaml')}).encode(), headers=headers, method='PUT')
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=15) as response:
        if response.status not in (200, 204):
            raise ValueError('reload rejected')


def atomic(path, data):
    fd, name = tempfile.mkstemp(prefix='.tun.', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'w') as output:
            output.write(data)
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def toggle(root, kernel, enabled):
    scope, unit = supervisor(root)
    if scope != 'system' or not owned_unit(root, shutil.which('systemctl'), Path('/proc/self/cgroup').read_text(), scope, unit):
        raise ValueError('Linux TUN needs its installed supervisor')
    settings_file = root / 'tun.json'
    settings = json.loads(settings_file.read_text()) if settings_file.exists() else defaults(os.getuid())
    settings['enabled'] = enabled
    config = root / 'config.yaml'
    old = config.read_text()
    candidate = render(old, settings)
    with tempfile.TemporaryDirectory(prefix='.tun-validation-', dir=str(root)) as directory:
        temporary = Path(directory) / 'config.yaml'
        temporary.write_text(candidate)
        check = subprocess.run([str(kernel), '-t', '-d', str(root), '-f', str(temporary)], capture_output=True, timeout=30)
        if check.returncode:
            raise ValueError('native configuration rejected')
    if config.read_text() != old:
        raise ValueError('configuration changed concurrently')
    atomic(root / 'config.yaml.bak', old)
    atomic(config, candidate)
    try:
        reload_config(root)
        verify(root, settings)
        atomic(settings_file, json.dumps(settings, indent=2) + '\n')
    except Exception:
        atomic(config, old)
        try:
            reload_config(root)
        except Exception:
            raise RuntimeError('TUN rollback could not reload the previous configuration') from None
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--kernel', required=True, type=Path)
    parser.add_argument('mode', choices=['on', 'off'])
    args = parser.parse_args()
    os.umask(0o077)
    try:
        toggle(args.root, args.kernel, args.mode == 'on')
    except RuntimeError:
        parser.exit(1, '[proxy] TUN 恢复重载失败；检查监督器与现用配置，未启动第二实例。\n')
    except (OSError, ValueError, TypeError, subprocess.SubprocessError):
        parser.exit(1, '[proxy] TUN 更新失败；未绕过监督器启动实例，检查配置和服务日志。\n')
    print('TUN 偏好已更新为 %s；仍需独立检查真实网络和业务。' % args.mode)


if __name__ == '__main__':
    main()
