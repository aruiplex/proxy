"""Read-only process identity and Linux listener ownership checks."""
import os
import re
import subprocess
from pathlib import Path


def pid_identity(pid):
    os.kill(pid, 0)
    proc = Path('/proc') / str(pid) / 'stat'
    if proc.exists():
        # comm may contain spaces or parentheses; fields start after the last ).
        fields = proc.read_text().rsplit(')', 1)[1].split()
        if fields[0] == 'Z':
            raise OSError('core is a zombie')
        return fields[19]  # starttime: field 22, after pid and comm
    return str(pid)


def _service_listener_ownership(pid, ports, proc=Path('/proc'), cgroups=Path('/sys/fs/cgroup')):
    """Capability-bearing cores hide fd links; accept only a single-PID unit.

    Socket cgroup + UID comes from kernel diagnostics, never process argv.
    Ambiguous membership or missing kernel metadata stays a failed check.
    """
    identity = pid_identity(pid)
    rows = (proc / str(pid) / 'cgroup').read_text().splitlines()
    group = next((r[3:] for r in rows if r.startswith('0::')), '')
    match = re.fullmatch(r'/system.slice/proxy-mihomo-([0-9]+)\.service', group)
    if not match:
        raise OSError('no verifiable managed service cgroup')
    uid = int(match[1])
    status = (proc / str(pid) / 'status').read_text()
    actual_uid = re.search(r'(?m)^Uid:\s+([0-9]+)', status)
    if not actual_uid or int(actual_uid[1]) != uid:
        raise OSError('service UID does not match process')
    members = cgroups / group.lstrip('/') / 'cgroup.procs'
    def exclusive():
        return {int(p) for p in members.read_text().split()} == {pid}
    if not exclusive():
        raise OSError('service contains another possible listener owner')
    query = ' or '.join('sport = :%d' % port for port in sorted(ports))
    try:
        result = subprocess.run(['ss', '-H', '-ltn', '-e', '--cgroup', query], capture_output=True, text=True, timeout=3)
    except subprocess.SubprocessError as error:
        raise OSError('socket cgroup diagnostics unavailable') from error
    if result.returncode:
        raise OSError('socket cgroup diagnostics failed')
    found = set()
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) < 5 or fields[0] != 'LISTEN':
            raise OSError('unsupported socket diagnostic format')
        port = int(fields[3].rsplit(':', 1)[-1])
        owner = re.search(r'\buid:([0-9]+)\b', line)
        scope = re.search(r'\bcgroup:(\S+)', line)
        if port in ports:
            if not owner or int(owner[1]) != uid or not scope or scope[1] != group:
                raise OSError('listener belongs to another service')
            found.add(port)
    if found != ports or not exclusive() or pid_identity(pid) != identity:
        raise OSError('listener ownership changed during check')
    return True


def check_listener_ownership(pid, ports):
    """On Linux, reject healthy ports belonging to a competing core."""
    if not Path('/proc/net/tcp').exists():
        return False
    owned = set()
    try:
        for fd in (Path('/proc') / str(pid) / 'fd').iterdir():
            try:
                match = re.fullmatch(r'socket:\[(\d+)\]', os.readlink(fd))
            except FileNotFoundError:  # An unrelated socket can close during polling.
                continue
            if match:
                owned.add(match[1])
    except PermissionError:
        return _service_listener_ownership(pid, ports)
    found = set()
    for table in ('/proc/net/tcp', '/proc/net/tcp6'):
        path = Path(table)
        if not path.exists():
            continue
        for line in path.read_text().splitlines()[1:]:
            fields = line.split()
            port = int(fields[1].rsplit(':', 1)[1], 16)
            if fields[3] == '0A' and fields[9] in owned and port in ports:
                found.add(port)
    if found != ports:
        raise OSError('required listener is not owned by the expected core')
    return True
