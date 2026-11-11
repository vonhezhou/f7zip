#!/usr/bin/env python3
"""固定语料与 SHA-256 验证的热缓存基准，所有工作文件均在临时目录。"""
import argparse
import concurrent.futures
import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


class Engine:
    def __init__(self):
        self.library = ctypes.CDLL(str(ROOT / 'native/lib/libf7zip.dylib'))
        self.library.f7_job_create.restype = ctypes.c_void_p
        self.library.f7_job_destroy.argtypes = [ctypes.c_void_p]
        self.library.f7_free.argtypes = [ctypes.c_void_p]
        self.library.f7_run.restype = ctypes.c_void_p
        self.library.f7_run.argtypes = [ctypes.c_void_p, *([ctypes.c_char_p] * 6), ctypes.c_int,
                                       ctypes.POINTER(ctypes.c_char_p), ctypes.c_int,
                                       ctypes.POINTER(ctypes.c_uint32), ctypes.c_int]

    def run(self, operation, archive, destination='', indices=()):
        job = self.library.f7_job_create()
        selection = (ctypes.c_uint32 * len(indices))(*indices)
        values = [ROOT / 'native/lib/7z.so', operation, archive, destination, '', 'zip']
        pointer = self.library.f7_run(job, *(str(value).encode() for value in values),
                                      5, None, 0, selection, len(indices))
        try:
            result = json.loads(ctypes.string_at(pointer))
            if not result['ok']:
                raise RuntimeError(result)
            return result
        finally:
            self.library.f7_free(pointer)
            self.library.f7_job_destroy(job)


def cli(*arguments):
    result = subprocess.run([str(ROOT / 'native/lib/f7zip'), *map(str, arguments)],
                            capture_output=True, text=True, check=True)
    response = json.loads(result.stdout)
    if not response['ok']:
        raise RuntimeError(response)
    return response


def files_digest(directory):
    return {path.relative_to(directory).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(directory.rglob('*')) if path.is_file()}


def corpus(directory, kind, size):
    directory.mkdir()
    count = {'tiny': 1, 'small': 256, 'mixed': 32, 'single': 1}[kind]
    length = {'tiny': 32, 'small': 4096}.get(kind, size // count)
    generator = random.Random(20261110)
    expected = {}
    for index in range(count):
        # 每个文件交替使用高可压缩文本和固定种子的伪随机字节。
        block = (b'F7Zip benchmark payload\n' * 3000) if index % 2 == 0 else generator.randbytes(65536)
        path = directory / f'file-{index:04d}.bin'
        with path.open('wb') as output:
            left = length
            while left:
                chunk = block[:min(left, len(block))]
                output.write(chunk)
                left -= len(chunk)
        os.utime(path, (1700000000, 1700000000))
        expected[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
    os.utime(directory, (1700000000, 1700000000))
    return expected, count * length


def measure(action, repetitions):
    samples = []
    for index in range(repetitions):
        started = time.perf_counter()
        action(index)
        samples.append(time.perf_counter() - started)
    return {'seconds': samples, 'medianSeconds': statistics.median(samples)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repetitions', type=int, default=3)
    parser.add_argument('--size-mib', type=int, default=32)
    parser.add_argument('--workers', type=int, default=4)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.repetitions < 1 or args.size_mib < 1 or not 1 <= args.workers <= 16:
        parser.error('重复次数和大小必须大于零，并发数必须为 1–16')
    engine = Engine()
    report = {'schema': 1, 'platform': platform.platform(), 'machine': platform.machine(),
              'logicalProcessors': os.cpu_count(), 'sizeMiB': args.size_mib,
              'repetitions': args.repetitions, 'workers': args.workers,
              'cache': 'warm, no cache flush, setup and SHA-256 verification excluded',
              'artifacts': {name: hashlib.sha256((ROOT / 'native/lib' / name).read_bytes()).hexdigest()
                            for name in ['f7zip', '7z.so', 'libf7zip.dylib']}, 'cases': []}
    with tempfile.TemporaryDirectory(prefix='f7zip-benchmark-') as temporary:
        root = Path(temporary)
        for kind in ['tiny', 'small', 'mixed', 'single']:
            source = root / kind
            expected, size = corpus(source, kind, args.size_mib * 1048576)
            for format in ['zip', '7z']:
                archives = []
                def compress(index):
                    archive = root / f'{kind}-{index}.{format}'
                    cli('compress', '--quiet', '--format', format, archive, source)
                    archives.append(archive)
                compression = measure(compress, args.repetitions)
                archive = archives[0]
                # 引擎测试同时预热归档，首次动态库加载不进入 ABI 解压计时。
                engine.run('test', archive)
                outputs = []
                def extract(index):
                    destination = root / f'{kind}-{format}-out-{index}'
                    result = cli('extract', '--quiet', archive, destination)
                    outputs.append(Path(result['path']) / source.name)
                extraction = measure(extract, args.repetitions)
                for output in outputs:
                    if files_digest(output) != expected:
                        raise RuntimeError('解压结果 SHA-256 不一致')
                case = {'corpus': kind, 'format': format, 'bytes': size,
                        'files': len(expected), 'corpusSha256': hashlib.sha256(
                            json.dumps(expected, sort_keys=True).encode()).hexdigest(),
                        'archiveBytes': archive.stat().st_size,
                        'compress': compression, 'extract': extraction}
                if format == 'zip':
                    items = [item for item in engine.run('list', archive)['items'] if not item['directory']]
                    for workers in sorted({1, min(args.workers, len(items))}):
                        shards = [items[index::workers] for index in range(workers)]
                        destinations = []
                        def parallel(index):
                            outputs = [root / f'{kind}-abi-{workers}-{index}-{shard}' for shard in range(workers)]
                            with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
                                futures = [pool.submit(engine.run, 'extract', archive, destination,
                                                       [item['index'] for item in items])
                                           for destination, items in zip(outputs, shards)]
                                for future in futures:
                                    future.result()
                            destinations.extend(outputs)
                        case[f'zipAbiWorkers{workers}'] = measure(parallel, args.repetitions)
                        for index in range(args.repetitions):
                            actual = {}
                            for destination in destinations[index * workers:(index + 1) * workers]:
                                actual.update(files_digest(destination / source.name))
                            if actual != expected:
                                raise RuntimeError('并行实验结果 SHA-256 不一致')
                report['cases'].append(case)
                print(f'{kind} {format}: compress={compression["medianSeconds"]:.4f}s '
                      f'extract={extraction["medianSeconds"]:.4f}s', flush=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    main()
