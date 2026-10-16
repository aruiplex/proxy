"""Prepare an inspectable Linux supervisor installation; never activate it."""
import argparse
import hashlib
import json
import os
import pwd
import shlex
import subprocess
from pathlib import Path
from tun_config import defaults, render


def quote(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%').replace('$', '$$') + '"'


def unit_text(root, cli, user):
    return '''# proxy-managed-linux-tun v1
[Unit]
Description=Managed Mihomo for %s with Linux TUN capabilities
After=network-online.target
Wants=network-online.target
ConditionPathExists=%s
StartLimitIntervalSec=120
StartLimitBurst=10

[Service]
Type=forking
User=%s
Group=%s
Environment=%s
Environment=%s
Environment=PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
ExecStart=/usr/bin/bash %s start
ExecStop=/usr/bin/bash %s stop
PIDFile=%s
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
NoNewPrivileges=true
UMask=0077
Restart=on-failure
RestartSec=3
TimeoutStartSec=60
TimeoutStopSec=20
KillMode=control-group

[Install]
WantedBy=multi-user.target
''' % (user.pw_name, str(root / 'supervisor.json').replace('%', '%%'), user.pw_uid, user.pw_gid,
       quote('HOME=' + user.pw_dir), quote('CONF_DIR=' + str(root)),
       quote(cli), quote(cli), str(root / 'mihomo.pid').replace('%', '%%'))


def policy_text(user, unit):
    return '''// proxy-managed-linux-tun v1
polkit.addRule(function(action, subject) {
    if (action.id === "org.freedesktop.systemd1.manage-units" &&
        subject.user === %s && action.lookup("unit") === %s &&
        ["start", "stop", "restart"].indexOf(action.lookup("verb")) >= 0) {
        return polkit.Result.YES;
    }
});
''' % (json.dumps(user.pw_name), json.dumps(unit))


def prepare(root, cli, kernel, output):
    user = pwd.getpwuid(os.getuid())
    if user.pw_uid == 0:
        raise ValueError('prepare must run as the application user')
    root, cli, kernel = root.resolve(), cli.resolve(), kernel.resolve()
    if any('\n' in str(p) or '\r' in str(p) for p in (root, cli, kernel)):
        raise ValueError('invalid installation path')
    if (root / 'kernels/undo.json').exists():
        raise ValueError('finish the pending kernel transaction first')
    raw = (root / 'config.yaml').read_text()
    prefs = defaults(user.pw_uid)
    candidate = render(raw, prefs)
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    unit = 'proxy-mihomo-%s.service' % user.pw_uid
    files = {'candidate.yaml': candidate, 'tun.json': json.dumps(prefs, indent=2) + '\n',
             'supervisor.json': json.dumps({'schema': 1, 'scope': 'system', 'unit': unit}) + '\n',
             unit: unit_text(root, cli, user), '49-proxy-mihomo-%s.rules' % user.pw_uid: policy_text(user, unit)}
    for name, content in files.items():
        (output / name).write_text(content)
        (output / name).chmod(0o600)
    check = subprocess.run([str(kernel), '-t', '-d', str(root), '-f', str(output / 'candidate.yaml')],
                           capture_output=True, timeout=30)
    if check.returncode:
        raise ValueError('native candidate validation failed; production unchanged')
    install = '''#!/usr/bin/env bash
# Install reviewed supervisor files only. No service stop/start or config edits.
set -euo pipefail
[[ $(id -u) == 0 ]] || { echo 'Run this reviewed installer with sudo.' >&2; exit 1; }
stage=$(cd -- "$(dirname -- "$0")" && pwd)
unit=%s
rule=%s
for target in "/etc/systemd/system/$unit" "/etc/polkit-1/rules.d/$rule"; do
  if [[ -e "$target" ]] && ! head -1 "$target" | grep -q 'proxy-managed-linux-tun v1'; then
    echo "Refusing to overwrite foreign file: $target" >&2; exit 1
  fi
done
[[ -d /etc/polkit-1/rules.d ]] || { echo 'polkit rules directory missing' >&2; exit 1; }
systemd-analyze verify "$stage/$unit"
install -o root -g root -m 644 "$stage/$unit" "/etc/systemd/system/$unit"
install -o root -g root -m 644 "$stage/$rule" "/etc/polkit-1/rules.d/$rule"
systemctl daemon-reload
systemctl enable "$unit"
echo 'Supervisor installed; current user proxy is unchanged. TUN activation remains a separate guarded step.'
''' % (shlex.quote(unit), shlex.quote('49-proxy-mihomo-%s.rules' % user.pw_uid))
    (output / 'install-supervisor.sh').write_text(install)
    (output / 'install-supervisor.sh').chmod(0o700)
    record = {'schema': 1, 'root': str(root), 'cli': str(cli), 'kernel': str(kernel),
              'uid': user.pw_uid, 'unit': unit, 'original_config_sha256': hashlib.sha256(raw.encode()).hexdigest(),
              'kernel_sha256': hashlib.sha256(kernel.read_bytes()).hexdigest(),
              'scope': 'host applications of this UID; LAN/Tailscale and other UIDs bypass capture',
              'candidate_validated': True, 'activated': False}
    record['artifacts'] = {name: hashlib.sha256((output / name).read_bytes()).hexdigest()
                           for name in [*files, 'install-supervisor.sh']}
    (output / 'plan.json').write_text(json.dumps(record, indent=2) + '\n')
    (output / 'plan.json').chmod(0o600)
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('root', 'cli', 'kernel', 'output'):
        parser.add_argument('--' + name, required=True, type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        result = prepare(args.root, args.cli, args.kernel, args.output)
    except (OSError, ValueError, subprocess.SubprocessError):
        parser.exit(1, '[proxy] Linux TUN 准备失败；未修改现用配置或服务。\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
