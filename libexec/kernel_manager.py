#!/usr/bin/env python3
"""Pinned, staged mihomo releases. Only activate/rollback change local selection.

The configuration stays at its existing path. A durable undo journal protects
multi-file changes; an unfinished transaction blocks normal core resolution.
"""
import argparse
import contextlib
import fcntl
import gzip
import hashlib
import json
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
import uuid
from pathlib import Path


class KernelError(Exception):
    pass


def digest(path):
    with Path(path).open('rb') as stream:
        checksum = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            checksum.update(chunk)
        return checksum.hexdigest()


def atomic(path, data, mode=0o600):
    path = Path(path)
    fd, name = tempfile.mkstemp(prefix='.kernel-write-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(name, mode)
        os.replace(name, path)
        sync_dir(path.parent)
    finally:
        Path(name).unlink(missing_ok=True)


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def encode(data):
    return (json.dumps(data, ensure_ascii=False, indent=2) + '\n').encode()


def host_platform():
    arch = {'x86_64': 'amd64', 'aarch64': 'arm64', 'arm64': 'arm64', 'armv7l': 'armv7'}.get(platform.machine(), platform.machine())
    return {'os': platform.system().lower(), 'arch': arch}


def version(binary):
    try:
        result = subprocess.run([str(binary), '-v'], capture_output=True, text=True, timeout=10, check=True)
    except (OSError, subprocess.SubprocessError):
        raise KernelError('候选内核不能在当前系统运行') from None
    line = result.stdout.splitlines()[0] if result.stdout else ''
    if not re.match(r'^Mihomo Meta \S+ ', line):
        raise KernelError('候选文件不是可运行的 mihomo')
    return line


def clone_resource_paths(text, original, clone):
    """Rebase named filesystem fields within the copied home, only for -t."""
    fields = {'external-ui', 'path', 'certificate', 'private-key'}
    prefix = str(original) + '/'
    def mapped(value):
        return str(clone) + '/' + value[len(prefix):] if isinstance(value, str) and value.startswith(prefix) else value
    try:
        config = json.loads(text)
    except ValueError:
        config = None
    if isinstance(config, dict):
        def walk(value):
            if isinstance(value, dict):
                return {key: mapped(item) if key in fields else walk(item) for key,item in value.items()}
            if isinstance(value, list): return [walk(item) for item in value]
            return value
        return json.dumps(walk(config), ensure_ascii=False)
    from adaptive_config import scalar
    lines = []
    for line in text.splitlines(keepends=True):
        match = re.match(r'^([ \t]*(?:-\s+)?(?:external-ui|path|certificate|private-key):[ \t]*)(.*?)(\r?\n?)$', line)
        if match:
            value = scalar(match[2])
            changed = mapped(value)
            if changed != value:
                line = match[1] + json.dumps(changed, ensure_ascii=False) + match[3]
        lines.append(line)
    return ''.join(lines)


def request(url):
    if urllib.parse.urlsplit(url).scheme != 'https':
        raise KernelError('发行资产 URL 必须使用 HTTPS')
    try:
        response = urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'proxy-kernel-manager'}), timeout=30)
        if urllib.parse.urlsplit(response.url).scheme != 'https':
            response.close()
            raise KernelError('拒绝降级为非 HTTPS 的下载')
        return response
    except (OSError, ValueError):
        raise KernelError('发行资产下载失败，当前版本保持不变') from None


def official_manifest(tag):
    if not re.fullmatch(r'v\d+\.\d+\.\d+', tag):
        raise KernelError('官方版本需要明确指定，例如 v1.19.32')
    hp = host_platform()
    # Prefer the compatible amd64 asset rather than guessing CPU feature flags.
    variant = '-compatible' if hp['arch'] == 'amd64' else ''
    asset_name = f"mihomo-{hp['os']}-{hp['arch']}{variant}-{tag}.gz"
    api_path = f'repos/MetaCubeX/mihomo/releases/tags/{tag}'
    try:
        with request('https://api.github.com/' + api_path) as response:
            release = json.load(response)
    except KernelError:
        # Shared networks often exhaust the anonymous GitHub API limit. Reuse
        # an already authenticated gh installation without reading its secrets.
        if not shutil.which('gh'):
            raise KernelError('GitHub API 不可达或匿名额度耗尽；可使用已登录的 gh，或提供本地 manifest') from None
        try:
            result = subprocess.run(['gh', 'api', api_path], capture_output=True, text=True, timeout=30, check=True)
            release = json.loads(result.stdout)
        except (OSError, subprocess.SubprocessError, ValueError):
            raise KernelError('GitHub 发行信息获取失败；请提供本地 manifest') from None
    if release.get('tag_name') != tag:
        raise KernelError('发行信息与指定 tag 不匹配')
    for asset in release.get('assets', []):
        if asset.get('name') == asset_name:
            checksum = asset.get('digest', '')
            if not re.fullmatch(r'sha256:[0-9a-f]{64}', checksum):
                raise KernelError('官方资产没有 SHA-256；请提供带可信摘要的本地 manifest')
            return {'schema': 1, 'source': {'id': 'MetaCubeX/mihomo', 'kind': 'official'}, 'version': tag,
                    'platform': hp, 'asset': {'url': asset['browser_download_url'], 'sha256': checksum[7:], 'compression': 'gzip'}}
    raise KernelError('该版本没有当前平台的兼容资产')


class Manager:
    STATE_FILES = ('config.yaml', 'proxy.conf', 'cache.db', 'adaptive.json')

    def __init__(self, root):
        self.root = Path(root).absolute()
        self.store = self.root / 'kernels'
        self.state_path = self.store / 'state.json'
        self.journal = self.store / 'undo.json'
        self.state = {'schema': 1, 'active': None, 'previous': None, 'prepared': None}

    @contextlib.contextmanager
    def locked(self):
        self.store.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.store, 0o700)
        with (self.store / 'lock').open('a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise KernelError('另一个内核管理操作正在执行') from None
            if self.journal.exists():
                self.ensure_stopped()
                self.recover()
            if self.state_path.exists():
                self.state = json.loads(self.state_path.read_text())
            yield

    def save(self):
        atomic(self.state_path, encode(self.state))

    def directory(self, record):
        name = record['directory']
        if not re.fullmatch(r'release-[0-9a-f]{32}', name):
            raise KernelError('内核状态中的发行目录无效')
        return self.store / name

    def ensure_stopped(self):
        # Match runtime directories/configs, not just executable names. This
        # also catches older or renamed binaries that share our state directory.
        pid_file = self.root / 'mihomo.pid'
        if pid_file.exists():
            try:
                pid = int(pid_file.read_text().strip())
                if pid > 0:
                    os.kill(pid, 0)
                    raise KernelError('该配置目录记录了运行中的进程；先 proxy stop，再启用或回退')
            except ProcessLookupError:
                pass
            except PermissionError:
                raise KernelError('无法确认特权内核已停止；先停机再启用或回退') from None
            except ValueError:
                pass
        processes = subprocess.run(['ps', '-ax', '-o', 'pid=,command='], capture_output=True, text=True, check=True).stdout
        for line in processes.splitlines():
            try:
                pid, command = line.strip().split(None, 1)
                if int(pid) == os.getpid():
                    continue
                cmdline = Path('/proc') / pid / 'cmdline'
                if cmdline.exists():
                    argv = [s.decode(errors='replace') for s in cmdline.read_bytes().split(b'\0') if s]
                else:
                    argv = shlex.split(command)
                for i in range(len(argv) - 1):
                    if argv[i] in ('-d', '-f'):
                        wanted = self.root if argv[i] == '-d' else self.root / 'config.yaml'
                        if Path(argv[i + 1]).resolve() == wanted.resolve():
                            raise KernelError('该配置目录仍有内核运行；先 proxy stop，再启用或回退。不会自动重启')
            except (ValueError, OSError):
                continue

    def validate(self, binary, config):
        # Test mode can initialize providers/files. Clone the runtime home so
        # rejected candidates cannot modify the active cache or providers.
        with tempfile.TemporaryDirectory(prefix='.kernel-validate-', dir=self.store) as temporary:
            home = Path(temporary) / 'home'
            shutil.copytree(self.root, home, symlinks=True,
                            ignore=lambda path, names: ['kernels', 'mihomo.log', 'mihomo.pid'] if Path(path) == self.root else [])
            candidate = home / 'candidate.yaml'
            candidate.write_text(clone_resource_paths(Path(config).read_text(), self.root, home))
            sidecar = Path(config).parent
            if sidecar.parent == self.store:
                saved_cache = sidecar / 'cache.db'
                (home / 'cache.db').unlink(missing_ok=True)
                if saved_cache.exists():
                    shutil.copyfile(saved_cache, home / 'cache.db')
            environment = dict(os.environ)
            environment.pop('SAFE_PATHS', None)
            try:
                subprocess.run([str(binary), '-t', '-d', str(home), '-f', str(candidate)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30, check=True, env=environment)
            except (OSError, subprocess.SubprocessError):
                raise KernelError('候选配置校验失败或超时；当前内核和配置保持不变') from None

    def prepare(self, manifest, manifest_dir, config=None, switch_source=False, preference_file=None):
        if manifest.get('schema') != 1 or manifest.get('platform') != host_platform():
            raise KernelError('manifest schema 或平台不匹配')
        source = manifest.get('source', {})
        if source.get('kind') not in ('official', 'custom', 'manual', 'gz', 'brew', 'existing') or not source.get('id'):
            raise KernelError('manifest 必须记录明确的内核来源')
        active = self.state['active']
        if active and any(active['source'].get(key) != source.get(key) for key in ('id','kind')) and not switch_source:
            raise KernelError('升级必须保持来源；切换来源需要显式 --switch-source')
        asset = manifest.get('asset', {})
        if not re.fullmatch(r'[0-9a-f]{64}', asset.get('sha256', '')):
            raise KernelError('manifest 必须包含资产 SHA-256')
        if bool(asset.get('path')) == bool(asset.get('url')):
            raise KernelError('资产必须且只能指定 path 或 url')
        compression = asset.get('compression', 'none')
        if compression not in ('none', 'gzip'):
            raise KernelError('只支持二进制或 gzip 资产')
        if not manifest.get('version'):
            raise KernelError('manifest 必须固定版本')
        directory = self.store / ('release-' + uuid.uuid4().hex)
        directory.mkdir(mode=0o700)
        try:
            downloaded = directory / 'asset'
            if asset.get('path'):
                shutil.copyfile(Path(manifest_dir) / asset['path'], downloaded)
            else:
                with request(asset['url']) as response, downloaded.open('wb') as output:
                    shutil.copyfileobj(response, output)
            if digest(downloaded) != asset['sha256']:
                raise KernelError('资产 SHA-256 不匹配；当前版本保持不变')
            binary = directory / 'mihomo'
            if compression == 'gzip':
                with gzip.open(downloaded, 'rb') as stream, binary.open('wb') as output:
                    shutil.copyfileobj(stream, output)
            else:
                shutil.copyfile(downloaded, binary)
            binary.chmod(0o700)
            actual = version(binary)
            label = actual.split()[2]
            declared = manifest['version']
            # Older official builds display 1.x.y while their release tag uses v1.x.y.
            same_release = (re.fullmatch(r'v?\d+\.\d+\.\d+', label)
                            and re.fullmatch(r'v?\d+\.\d+\.\d+', declared)
                            and label.lstrip('v') == declared.lstrip('v'))
            if label != declared and not same_release:
                raise KernelError('二进制实际版本与 manifest 不匹配')
            candidate = directory / 'config.yaml'
            chosen = Path(config) if config else self.root / 'config.yaml'
            if not chosen.is_file():
                chosen = Path(__file__).resolve().parents[1] / 'templates/config.minimal.yaml'
            shutil.copyfile(chosen, candidate)
            candidate.chmod(0o600)
            preference_path = Path(preference_file) if preference_file else self.root / 'adaptive.json'
            if preference_path.exists():
                from adaptive_config import preferences, render
                preference_data = preferences(preference_path)
                candidate.write_text(render(candidate.read_text(), preference_data))
                shutil.copyfile(preference_path, directory / 'adaptive.json')
                (directory / 'adaptive.json').chmod(0o600)
            self.validate(binary, candidate)
            record = {'directory': directory.name, 'source': source, 'version': manifest['version'],
                      'actual_version': actual, 'platform': host_platform(), 'asset_sha256': asset['sha256'],
                      'binary_sha256': digest(binary), 'config_sha256': digest(candidate),
                      'base_files': {name: digest(self.root / name) if (self.root / name).exists() else None for name in self.STATE_FILES if name != 'cache.db'}}
            record['preferences_sha256'] = digest(directory / 'adaptive.json') if (directory / 'adaptive.json').exists() else None
            atomic(directory / 'manifest.json', encode(manifest))
            atomic(directory / 'release.json', encode(record))
            downloaded.unlink()
            self.state['prepared'] = record
            self.save()
            return record
        except BaseException:
            shutil.rmtree(directory)
            raise

    def verify(self, record):
        directory = self.directory(record)
        if digest(directory / 'mihomo') != record['binary_sha256']:
            raise KernelError('保存的内核摘要不匹配')
        if version(directory / 'mihomo') != record['actual_version']:
            raise KernelError('保存的内核版本已改变')
        return directory

    def snapshot(self, binary, source):
        directory = self.store / ('release-' + uuid.uuid4().hex)
        directory.mkdir(mode=0o700)
        shutil.copyfile(binary, directory / 'mihomo')
        (directory / 'mihomo').chmod(0o700)
        actual = version(directory / 'mihomo')
        for name in self.STATE_FILES:
            path = self.root / name
            if path.exists():
                shutil.copyfile(path, directory / name)
                (directory / name).chmod(0o600)
        if not (directory / 'config.yaml').exists():
            raise KernelError('当前内核缺少兼容配置，不能保存回退版本')
        record = {'directory': directory.name, 'source': source, 'version': actual.split()[2],
                  'actual_version': actual, 'platform': host_platform(), 'asset_sha256': digest(directory / 'mihomo'),
                  'binary_sha256': digest(directory / 'mihomo'), 'config_sha256': digest(directory / 'config.yaml')}
        self.validate(directory / 'mihomo', directory / 'config.yaml')
        atomic(directory / 'release.json', encode(record))
        return record

    def backup(self):
        undo = {'state': self.state, 'files': {}}
        directory = self.store / ('undo-' + uuid.uuid4().hex)
        directory.mkdir(mode=0o700)
        for name in self.STATE_FILES:
            path = self.root / name
            undo['files'][name] = path.exists()
            if path.exists():
                atomic(directory / name, path.read_bytes())
        undo['directory'] = directory.name
        atomic(self.journal, encode(undo))

    def recover(self):
        undo = json.loads(self.journal.read_text())
        if not re.fullmatch(r'undo-[0-9a-f]{32}', undo['directory']):
            raise KernelError('恢复目录无效')
        directory = self.store / undo['directory']
        for name, existed in undo['files'].items():
            if name not in self.STATE_FILES:
                raise KernelError('恢复文件无效')
            if existed:
                atomic(self.root / name, (directory / name).read_bytes())
            else:
                (self.root / name).unlink(missing_ok=True)
        self.state = undo['state']
        self.save()
        self.finish()

    def finish(self):
        undo = json.loads(self.journal.read_text())
        self.journal.unlink()
        sync_dir(self.store)
        shutil.rmtree(self.store / undo['directory'])

    def current_binary(self):
        if self.state['active']:
            return self.verify(self.state['active']) / 'mihomo', self.state['active']['source']
        conf = self.root / 'proxy.conf'
        values = dict(line.split('=', 1) for line in conf.read_text().splitlines() if '=' in line) if conf.exists() else {}
        binary = values.get('bin')
        if binary:
            kind = values.get('install_method', 'existing')
            if kind not in ('manual', 'gz', 'brew', 'existing', 'github'):
                raise KernelError('旧安装来源无效')
            source = {'id': 'MetaCubeX/mihomo' if kind == 'github' else kind, 'kind': 'official' if kind == 'github' else kind}
            return Path(binary), source
        return None, None

    def select(self, rollback=False):
        self.ensure_stopped()
        target = self.state['previous' if rollback else 'prepared']
        if not target:
            raise KernelError('没有可回退版本' if rollback else '先准备候选版本: proxy kernel prepare')
        if not rollback:
            for name, expected in target.get('base_files', {}).items():
                current = digest(self.root / name) if (self.root / name).exists() else None
                if current != expected:
                    raise KernelError('准备后本机配置或偏好已改变；重新 prepare 再启用，避免覆盖新设置')
        directory = self.verify(target)
        if digest(directory / 'config.yaml') != target['config_sha256']:
            raise KernelError('保存的兼容配置摘要不匹配')
        saved_preferences = directory / 'adaptive.json'
        if not rollback and (digest(saved_preferences) if saved_preferences.exists() else None) != target.get('preferences_sha256'):
            raise KernelError('候选选路偏好摘要不匹配')
        self.validate(directory / 'mihomo', directory / 'config.yaml')
        binary, source = self.current_binary()
        previous = self.snapshot(binary, source) if binary and (self.root / 'config.yaml').exists() else None
        self.backup()
        try:
            for name in self.STATE_FILES:
                saved = directory / name
                if saved.exists():
                    atomic(self.root / name, saved.read_bytes())
                elif rollback or name == 'cache.db':
                    (self.root / name).unlink(missing_ok=True)
            # Keep existing non-kernel settings. Rollback restores their snapshot.
            conf = self.root / 'proxy.conf'
            lines = conf.read_text().splitlines() if conf.exists() else []
            lines = [line for line in lines if not line.startswith(('bin=', 'install_method=', 'controller=', 'secret='))]
            config_text = (self.root / 'config.yaml').read_text()
            try:
                options = json.loads(config_text)
            except ValueError:
                options = {}
                for key in ('external-controller', 'secret'):
                    match = re.search(r'^' + key + r':[ \t]*(.*)$', config_text, re.M)
                    if match:
                        value = match[1].strip()
                        if value.startswith('"'):
                            value = json.loads(value)
                        elif value.startswith("'") and value.endswith("'"):
                            value = value[1:-1].replace("''", "'")
                        else:
                            value = value.split(' #', 1)[0].strip()
                        options[key] = value
            controller = str(options.get('external-controller', '127.0.0.1:9090')).replace('0.0.0.0:', '127.0.0.1:', 1)
            secret = str(options.get('secret') or '')
            if any(c in controller + secret for c in '\r\n'):
                raise KernelError('控制器配置不能包含换行')
            lines += ['controller=' + controller, 'secret=' + secret]
            lines += ['bin=' + str(directory / 'mihomo'), 'install_method=managed']
            atomic(conf, ('\n'.join(lines) + '\n').encode())
            self.state = dict(self.state, active=target, previous=previous, prepared=None if not rollback else self.state['prepared'])
            self.save()
        except BaseException:
            self.recover()
            raise
        self.finish()
        return target


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True)
    sub = parser.add_subparsers(dest='command', required=True)
    prepare = sub.add_parser('prepare')
    group = prepare.add_mutually_exclusive_group(required=True)
    group.add_argument('--manifest', type=Path)
    group.add_argument('--official', metavar='VERSION')
    group.add_argument('--bin', type=Path)
    group.add_argument('--gzip', type=Path)
    prepare.add_argument('--source', default='local')
    prepare.add_argument('--kind', choices=['custom', 'manual', 'gz', 'brew', 'existing'], default='custom')
    prepare.add_argument('--config', type=Path)
    prepare.add_argument('--preferences', type=Path)
    prepare.add_argument('--switch-source', action='store_true')
    start = sub.add_parser('start')
    start.add_argument('--cli', required=True, type=Path)
    for command in ['activate', 'rollback', 'status']:
        sub.add_parser(command)
    args = parser.parse_args()
    manager = Manager(args.root)
    try:
        with manager.locked():
            if args.command == 'start':
                environment = dict(os.environ, PROXY_KERNEL_START_LOCKED='1')
                return subprocess.call(['bash', str(args.cli), 'start'], env=environment)
            if args.command == 'prepare':
                if args.manifest:
                    manifest = json.loads(args.manifest.read_text())
                    base = args.manifest.absolute().parent
                elif args.official:
                    manifest = official_manifest(args.official)
                    base = Path('.')
                elif args.gzip:
                    asset = args.gzip.absolute()
                    with tempfile.TemporaryDirectory(prefix='.kernel-gzip-version-', dir=manager.store) as temporary:
                        binary = Path(temporary) / 'mihomo'
                        with gzip.open(asset, 'rb') as stream, binary.open('wb') as output:
                            shutil.copyfileobj(stream, output)
                        binary.chmod(0o700)
                        actual = version(binary).split()[2]
                    manifest = {'schema': 1, 'source': {'id': args.source, 'kind': args.kind}, 'version': actual,
                                'platform': host_platform(), 'asset': {'path': str(asset), 'sha256': digest(asset), 'compression': 'gzip'}}
                    base = Path('.')
                else:
                    binary = args.bin.absolute()
                    manifest = {'schema': 1, 'source': {'id': args.source, 'kind': args.kind}, 'version': version(binary).split()[2],
                                'platform': host_platform(), 'asset': {'path': str(binary), 'sha256': digest(binary)}}
                    base = Path('.')
                output = manager.prepare(manifest, base, args.config, args.switch_source, args.preferences)
            elif args.command in ('activate', 'rollback'):
                output = manager.select(rollback=args.command == 'rollback')
            else:
                output = dict(manager.state)
                if not manager.state['active']:
                    binary, source = manager.current_binary()
                    if binary:
                        actual = version(binary)
                        output['legacy'] = {'version': actual.split()[2], 'actual_version': actual, 'source': source}
            print(json.dumps(output, ensure_ascii=False, indent=2))
    except (KernelError, OSError, ValueError, KeyError, TypeError) as error:
        # Do not print raw file contents, subprocess logs or URLs with tokens.
        message = str(error) if isinstance(error, KernelError) else '内核管理失败：检查 manifest、文件权限及本地状态'
        print('[proxy] ' + message, file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
