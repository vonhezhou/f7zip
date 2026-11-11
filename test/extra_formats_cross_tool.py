#!/usr/bin/env python3
"""使用指定的独立 7zz 程序双向验证 ZIPX 与 WIM。"""
import argparse
from pathlib import Path
import subprocess
import tempfile

from native_engine_test import execute


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sevenzip', type=Path, required=True)
    args = parser.parse_args()
    binary = args.sevenzip.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix='f7zip-cross-formats-') as temporary:
        root = Path(temporary)
        source = root / '中文😀.txt'
        payload = b'cross-tool content\n' * 1000
        source.write_bytes(payload)
        cases = [('zipx', method) for method in ['auto', 'BZip2', 'PPMd']] + [('wim', 'auto')]
        for format, method in cases:
            archive = root / f'created-{method}.{format}'
            created = execute('compress', archive, inputs=[source], format=format,
                              level=0 if format == 'wim' else 5,
                              compression_parameters=(method, 0, 0, -1))
            assert created['ok'], created
            subprocess.run([str(binary), 't', str(archive)], capture_output=True, check=True)
            output = root / f'external-{format}-{method}'
            subprocess.run([str(binary), 'x', str(archive), '-o' + str(output)], capture_output=True, check=True)
            assert (output / source.name).read_bytes() == payload
            external = root / f'external-created-{method}.{format}'
            command = [str(binary), 'a', '-t' + ('zip' if format == 'zipx' else 'wim'), str(external), str(source)]
            if format == 'zipx':
                command.append('-mm=' + ('LZMA' if method == 'auto' else method))
            subprocess.run(command, capture_output=True, check=True)
            restored = root / f'own-{format}-{method}'
            result = execute('extract', external, destination=restored)
            assert result['ok'], result
            assert (restored / source.name).read_bytes() == payload
            print(f'{format} {method}: 双向完整性与内容验证通过')


if __name__ == '__main__':
    main()
