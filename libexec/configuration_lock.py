"""Serialize subscription publication and service qualification across processes.

The CLI writer retains the lock descriptor even if its launcher is killed. A
private owner token permits nested operations; long-lived kernels detach the FD.
"""
import argparse
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import subprocess
import signal
import tempfile
import threading
import time
import uuid

TOKEN = 'PROXY_CONFIGURATION_TOKEN'
FD = 'PROXY_CONFIGURATION_FD'
_held = threading.local()


def owned(root):
    try:
        root = Path(root).resolve()
        owner = json.loads((root / '.configuration-owner.json').read_text())
        if owner['pid'] == os.getpid():
            return (owner['thread'] == threading.get_ident()
                    and getattr(_held, 'tokens', {}).get(str(root)) == owner['token'])
        if owner['token'] != os.environ.get(TOKEN):
            return False
        descriptor = int(os.environ.get(FD, '-1'))
        current = os.fstat(descriptor)
        expected = (root / '.configuration.lock').stat()
        return descriptor > 2 and (current.st_dev, current.st_ino) == (expected.st_dev, expected.st_ino)
    except (OSError, ValueError, KeyError, TypeError):
        return False


@contextmanager
def lock(root, timeout=15):
    root = Path(root).resolve()
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    if owned(root):
        yield json.loads((root / '.configuration-owner.json').read_text())['token']
        return
    descriptor = os.open(root / '.configuration.lock', os.O_CREAT | os.O_RDWR, 0o600)
    acquired = False
    token = uuid.uuid4().hex
    owner_path = root / '.configuration-owner.json'
    try:
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                acquired = True
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError('Proxy configuration is busy')
                time.sleep(.05)
        fd, name = tempfile.mkstemp(dir=root, prefix='.configuration-owner-')
        try:
            with os.fdopen(fd, 'w') as stream:
                json.dump({'token': token, 'pid': os.getpid(), 'thread': threading.get_ident()}, stream)
            os.replace(name, owner_path)
        finally:
            Path(name).unlink(missing_ok=True)
        if not hasattr(_held, 'tokens'):
            _held.tokens = {}
            _held.descriptors = {}
        _held.tokens[str(root)] = token
        _held.descriptors[str(root)] = descriptor
        yield token
    finally:
        if acquired:
            owner_path.unlink(missing_ok=True)
            getattr(_held, 'tokens', {}).pop(str(root), None)
            getattr(_held, 'descriptors', {}).pop(str(root), None)
            # Closing the last shared descriptor releases flock. Explicit LOCK_UN
            # would also unlock a still-running child writer's inherited lease.
        os.close(descriptor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--owned', action='store_true')
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.owned:
        return 0 if owned(args.root) else 1
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        parser.error('a command is required')
    with lock(args.root, timeout=120) as token:
        descriptor = getattr(_held, 'descriptors', {}).get(str(args.root.resolve()), int(os.environ.get(FD, '-1')))
        environment = dict(os.environ, **{TOKEN: token, FD: str(descriptor)})
        process = subprocess.Popen(command, pass_fds=(descriptor,), env=environment, start_new_session=True)
        def forward(signum, _):
            try:os.killpg(process.pid, signum)
            except ProcessLookupError:pass
        previous = {s:signal.signal(s, forward) for s in (signal.SIGINT, signal.SIGTERM)}
        try:
            return process.wait()
        finally:
            if process.poll() is None:
                forward(signal.SIGTERM, None)
                try:process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    forward(signal.SIGKILL, None);process.wait()
            for s, handler in previous.items():signal.signal(s, handler)


if __name__ == '__main__':
    raise SystemExit(main())
