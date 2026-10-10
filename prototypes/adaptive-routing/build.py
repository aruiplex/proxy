#!/usr/bin/env python3
"""Build the pinned experimental kernel in a fresh isolated directory."""
import argparse
import contextlib
import hashlib
import json
import os
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(args, directory, environment):
    subprocess.run(args, cwd=directory, env=environment, check=True)


def build(directory, output, source_archive, go, skip_tests):
    manifest = json.loads((ROOT / "baseline.json").read_text())
    patch = ROOT / "mihomo.patch"
    if digest(patch) != manifest["patch_sha256"]:
        raise ValueError("patch digest does not match baseline.json")
    archive = directory / "source.tar.gz"
    if source_archive:
        shutil.copyfile(source_archive, archive)
    else:
        with urllib.request.urlopen(manifest["source_url"], timeout=60) as response, archive.open("wb") as dest:
            shutil.copyfileobj(response, dest)
    if digest(archive) != manifest["source_sha256"]:
        raise ValueError("official source archive digest mismatch")
    with tarfile.open(archive, "r:gz") as source:
        for member in source.getmembers():
            parts = Path(member.name).parts
            if not parts or parts[0] != manifest["source_directory"] or ".." in parts or not (member.isfile() or member.isdir()):
                raise ValueError("unsafe source archive member")
        source.extractall(directory, filter="data")
    source_dir = directory / manifest["source_directory"]
    environment = dict(os.environ, GOTOOLCHAIN=manifest["go_toolchain"], GIT_CEILING_DIRECTORIES=str(directory))
    # Do not let an enclosing checkout or inherited Git worktree redirect apply.
    for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE"]:
        environment.pop(key, None)
    run(["git", "apply", "--check", str(patch)], source_dir, environment)
    run(["git", "apply", str(patch)], source_dir, environment)
    if not skip_tests:
        run([go, "test", "-race", "./adapter/outboundgroup", "-run", "Adaptive", "-count=1"], source_dir, environment)
        # Includes parser/configuration regression tests. The optional upstream
        # full suite has host-specific prerequisites; see README.
        run([go, "test", "./adapter/outboundgroup", "./hub/route", "./tunnel", "./config", "./constant"], source_dir, environment)
    binary = directory / "mihomo-adaptive"
    run([go, "build", "-buildvcs=false", "-trimpath", "-ldflags", f"-X github.com/metacubex/mihomo/constant.Version={manifest['version']}", "-o", str(binary), "."], source_dir, environment)
    # Publish atomically without overwriting an installed or user-owned binary.
    with tempfile.NamedTemporaryFile(dir=output.parent, prefix=".adaptive-build-") as pending:
        with binary.open("rb") as source:
            shutil.copyfileobj(source, pending)
        pending.flush()
        os.chmod(pending.name, 0o755)
        os.link(pending.name, output)
    print(json.dumps({"binary": str(output), "sha256": digest(output), "baseline": manifest,
        "version": subprocess.check_output([str(output), "-v"], text=True).strip()}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="new binary path; existing files are refused")
    parser.add_argument("--work-dir", type=Path, help="fresh directory to retain source and build state")
    parser.add_argument("--source-archive", type=Path, help="reuse a local archive; SHA-256 is still verified")
    parser.add_argument("--go", default="go", help="Go launcher, with pinned GOTOOLCHAIN")
    parser.add_argument("--skip-tests", action="store_true", help="build only; no validation claim")
    args = parser.parse_args()
    output = args.output.absolute()
    if output.exists() or output.is_symlink():
        parser.error("output already exists; choose a fresh path")
    if not output.parent.is_dir():
        parser.error("output parent directory must already exist")
    with contextlib.ExitStack() as stack:
        if args.work_dir:
            directory = args.work_dir.absolute()
            directory.mkdir(parents=True, exist_ok=False)
        else:
            directory = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix="mihomo-adaptive-build-")))
        build(directory, output, args.source_archive, args.go, args.skip_tests)


if __name__ == "__main__":
    main()
