#!/usr/bin/env python3
"""下载固定版本源码，编译本机架构的 7-Zip 与 C ABI 桥接库。"""
import concurrent.futures
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / 'native/vendor'
ENGINE = VENDOR / '7zip'
BIT7Z = VENDOR / 'bit7z'
LIB = ROOT / 'native/lib'
OBJECTS = VENDOR / 'objects'
SOURCE_HASH = '3e596155744af055a77fc433c703d54e3ea9212246287b5b1436a6beac060f16'
BIT7Z_SOURCE_HASH = '5a79f9cd2f7bc17ae4088a6b7ac9b5b08476082c1404c98c50ae52aa441559ae'
BIT7Z_COMMIT = '0f03717920442abcdba80183534931c867feb9c0'


def run(args, **kwargs):
    subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def main():
    VENDOR.mkdir(parents=True, exist_ok=True)
    LIB.mkdir(parents=True, exist_ok=True)
    OBJECTS.mkdir(parents=True, exist_ok=True)
    archive = VENDOR / '7zip.tar.xz'
    bundled_engine = ROOT / 'third_party/7zip.tar.xz'
    if not archive.exists() and bundled_engine.exists():
        shutil.copy2(bundled_engine, archive)
    if not archive.exists():
        urllib.request.urlretrieve('https://www.7-zip.org/a/7z2600-src.tar.xz', archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SOURCE_HASH:
        raise RuntimeError('7-Zip 源码校验失败，请删除 native/vendor/7zip.tar.xz 后重新构建')
    if not ENGINE.exists():
        ENGINE.mkdir()
        with tarfile.open(archive) as source:
            source.extractall(ENGINE)
    bundled_bit7z = ROOT / 'third_party/bit7z-source.tar.gz'
    if not BIT7Z.exists():
        if bundled_bit7z.exists():
            if hashlib.sha256(bundled_bit7z.read_bytes()).hexdigest() != BIT7Z_SOURCE_HASH:
                raise RuntimeError('bit7z 源码校验失败')
            with tarfile.open(bundled_bit7z) as source:
                source.extractall(VENDOR)
        else:
            run(['git', 'clone', '--depth', '1', '--branch', 'v4.0.10',
                 'https://github.com/rikyoz/bit7z.git', BIT7Z])
    if (BIT7Z / '.git').exists():
        commit = subprocess.check_output(['git', '-C', str(BIT7Z), 'rev-parse', 'HEAD'], text=True).strip()
        if commit != BIT7Z_COMMIT:
            raise RuntimeError('bit7z 版本不匹配')
    bundle = ENGINE / 'CPP/7zip/Bundles/Format7zF'
    deployment_stamp = bundle / '_o/f7zip-deployment-12'
    if not deployment_stamp.exists():
        shutil.rmtree(bundle / '_o', ignore_errors=True)
    build_env = dict(os.environ, MACOSX_DEPLOYMENT_TARGET='12.0')
    run(['make', '-j8', '-f', 'makefile.gcc', 'CXX=clang++', 'CC=clang'], cwd=bundle, env=build_env)
    deployment_stamp.touch()
    shutil.copy2(bundle / '_o/7z.so', LIB / '7z.so')
    flags = ['-std=c++17', '-O2', '-fPIC', '-mmacosx-version-min=12.0',
             '-DBIT7Z_AUTO_FORMAT', '-DBIT7Z_DETECT_FROM_EXTENSION', '-DUNICODE', '-D_UNICODE',
             '-D_LARGEFILE64_SOURCE', '-D_LARGEFILE_SOURCE', '-D_REENTRANT',
             '-DEXTERNAL_CODECS', '-DENV_UNIX', '-DBREAK_HANDLER', '-DUSE_WIN_FILE',
             '-I' + str(BIT7Z / 'include'), '-I' + str(BIT7Z / 'include/bit7z'),
             '-I' + str(BIT7Z / 'src'), '-I' + str(ENGINE / 'CPP')]
    sources = sorted((BIT7Z / 'src').rglob('*.cpp')) + [ROOT / 'native/f7zip.cpp']

    def compile_source(source):
        name = str(source.relative_to(ROOT / 'native')).replace('/', '_') + '.o'
        output = OBJECTS / name
        if not output.exists() or output.stat().st_mtime < max(source.stat().st_mtime, Path(__file__).stat().st_mtime):
            run(['clang++', *flags, '-c', source, '-o', output])
        return output

    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        objects = list(pool.map(compile_source, sources))
    run(['clang++', '-dynamiclib', '-mmacosx-version-min=12.0', *objects,
         '-o', LIB / 'libf7zip.dylib', '-install_name', '@rpath/libf7zip.dylib'])
    licenses = LIB / 'licenses'
    licenses.mkdir(exist_ok=True)
    shutil.copy2(ENGINE / 'DOC/License.txt', licenses / '7zip.txt')
    shutil.copy2(ENGINE / 'DOC/copying.txt', licenses / 'LGPL-2.1.txt')
    shutil.copy2(BIT7Z / 'LICENSE', licenses / 'bit7z-MPL-2.0.txt')
    print('Native libraries ready at', LIB)


if __name__ == '__main__':
    main()
