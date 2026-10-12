"""Read-only process identity and Linux listener ownership checks."""
import os
import re
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


def check_listener_ownership(pid, ports):
    """On Linux, reject healthy ports belonging to a competing core."""
    if not Path('/proc/net/tcp').exists():
        return False
    owned = set()
    for fd in (Path('/proc') / str(pid) / 'fd').iterdir():
        try:
            match = re.fullmatch(r'socket:\[(\d+)\]', os.readlink(fd))
        except FileNotFoundError:  # An unrelated socket can close during polling.
            continue
        if match:
            owned.add(match[1])
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
