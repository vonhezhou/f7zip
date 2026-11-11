#!/usr/bin/env python3
"""以指定的独立 7zz 验证 SFX 数据、密码与归档式读取。"""
import argparse
from pathlib import Path
import subprocess
import tempfile

from native_engine_test import ROOT, execute


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sevenzip', type=Path, required=True)
    args = parser.parse_args()
    binary = args.sevenzip.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix='f7zip-sfx-cross-') as directory:
        root = Path(directory)
        source = root / '资料😀.txt'
        data = b'cross-tool SFX payload\n' * 1000
        source.write_bytes(data)
        password = 'cross-中文😀'
        module = ROOT / 'native/sfx/7z-x86.sfx'
        for index, method in enumerate(['Copy', 'LZMA2', 'LZMA', 'PPMd']):
            archive = root / f'created-{method}.exe'
            result = execute('compress', archive, inputs=[source], format='sfx', password=password,
                             compression_parameters=(method, 0, 2, -1))
            assert result['ok'], result
            subprocess.run([str(binary), 't', '-p' + password, str(archive)], capture_output=True, check=True)
            output = root / f'output-{index}'
            subprocess.run([str(binary), 'x', '-p' + password, str(archive), '-o' + str(output)], capture_output=True, check=True)
            assert (output / source.name).read_bytes() == data
            print(f'F7Zip {method} SFX → 独立 7zz 内容与 Unicode 密码验证通过')
        external = root / 'external.7z'
        subprocess.run([str(binary), 'a', '-t7z', '-mhe=on', '-p' + password, str(external), str(source)], capture_output=True, check=True)
        wrapped = root / 'external.exe'
        wrapped.write_bytes(module.read_bytes() + external.read_bytes())
        output = root / 'external-output'
        result = execute('extract', wrapped, destination=output, password=password)
        assert result['ok'], result
        assert (output / source.name).read_bytes() == data
        print('独立 7zz 加密载荷 → F7Zip SFX 读取验证通过')


if __name__ == '__main__':
    main()
