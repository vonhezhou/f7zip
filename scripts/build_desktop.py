#!/usr/bin/env python3
"""在目标系统上编译并打包桌面应用，供本地构建和 GitHub Actions 复用。"""
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / 'dist'


def run(arguments, **kwargs):
    subprocess.run([str(value) for value in arguments], check=True, cwd=ROOT, **kwargs)



def main():
    os.chdir(ROOT)
    system = platform.system()
    DIST.mkdir(exist_ok=True)
    if system == 'Darwin':
        run(['bash', 'scripts/build_macos.sh'])
        name = f'F7Zip-macos-{platform.machine()}'
        run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', DIST / 'F7Zip.app', DIST / f'{name}.zip'])
        return
    if system not in ('Windows', 'Linux'):
        raise RuntimeError(f'尚不支持此构建系统 {system}')
    run([sys.executable, 'scripts/build_native.py'])
    flutter = shutil.which('flutter')
    if not flutter:
        raise RuntimeError('未找到 Flutter，请将 Flutter SDK 的 bin 目录加入 PATH')
    run([flutter, 'pub', 'get'])
    run([flutter, 'build', system.lower(), '--release'])
    arch = platform.machine().lower()
    arch = {'amd64': 'x64', 'x86_64': 'x64', 'aarch64': 'arm64'}.get(arch, arch)
    name = f'F7Zip-{system.lower()}-{arch}'
    if system == 'Windows':
        source = ROOT / 'build/windows' / arch / 'runner/Release'
    else:
        source = ROOT / 'build/linux' / arch / 'release/bundle'
    if not source.is_dir():
        raise RuntimeError(f'未找到 Flutter 产物 {source}')
    output = DIST / name
    if output.exists():
        shutil.rmtree(output)
    shutil.copytree(source, output)
    for filename in ('LICENSE', 'THIRD_PARTY_NOTICES.md'):
        shutil.copy2(ROOT / filename, output / filename)
    if system == 'Windows':
        shutil.make_archive(str(DIST / name), 'zip', root_dir=DIST, base_dir=name)
    else:
        with tarfile.open(DIST / f'{name}.tar.gz', 'w:gz') as archive:
            archive.add(output, arcname=name)
    run([sys.executable, 'scripts/package_sources.py'])
    print(output)


if __name__ == '__main__':
    main()
