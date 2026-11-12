"""在三个目标系统上验证真实 C ABI、CLI、Unicode、失败保护与编辑往返。"""
import ctypes
import json
import hashlib
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
NATIVE = Path(os.environ.get('F7ZIP_NATIVE_DIR', ROOT / 'native/lib')).resolve()
SYSTEM = platform.system()
LIBRARY = {'Windows': 'f7zip.dll', 'Darwin': 'libf7zip.dylib', 'Linux': 'libf7zip.so'}[SYSTEM]
ENGINE = NATIVE / ('7z.dll' if SYSTEM == 'Windows' else '7z.so')
CLI = NATIVE / ('f7zip-cli.exe' if SYSTEM == 'Windows' else 'f7zip' if SYSTEM == 'Darwin' else 'f7zip-cli')
DLL_DIRECTORY = os.add_dll_directory(str(NATIVE)) if SYSTEM == 'Windows' else None
LIB = ctypes.CDLL(str(NATIVE / LIBRARY))
LIB.f7_job_create.restype = ctypes.c_void_p
LIB.f7_job_destroy.argtypes = [ctypes.c_void_p]
LIB.f7_job_volume_size.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
LIB.f7_free.argtypes = [ctypes.c_void_p]
LIB.f7_run.restype = ctypes.c_void_p
LIB.f7_run.argtypes = [ctypes.c_void_p, *([ctypes.c_char_p] * 6), ctypes.c_int,
                      ctypes.POINTER(ctypes.c_char_p), ctypes.c_int, ctypes.POINTER(ctypes.c_uint32), ctypes.c_int]
LIB.f7_mutate.restype = ctypes.c_void_p
LIB.f7_mutate.argtypes = [ctypes.c_void_p, *([ctypes.c_char_p] * 7), ctypes.POINTER(ctypes.c_char_p), ctypes.c_int]


def response(pointer):
    try:
        return json.loads(ctypes.string_at(pointer).decode('utf-8'))
    finally:
        LIB.f7_free(pointer)


def execute(operation, archive, destination='', password='', format='zip', inputs=(), volume_size=0):
    job = LIB.f7_job_create()
    LIB.f7_job_volume_size(job, volume_size)
    files = (ctypes.c_char_p * len(inputs))(*(str(value).encode('utf-8') for value in inputs))
    try:
        strings = [str(value).encode('utf-8') for value in [ENGINE, operation, archive, destination, password, format]]
        return response(LIB.f7_run(job, *strings, 0 if format == 'wim' else 5, files, len(files), None, 0))
    finally:
        LIB.f7_job_destroy(job)


class DesktopNativeSmoke(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='f7zip-desktop-')
        self.root = Path(self.temporary.name)
        self.source = self.root / '中文 😀.txt'
        self.source.write_bytes('跨平台内容\n'.encode('utf-8') * 128)

    def tearDown(self):
        self.temporary.cleanup()

    def success(self, result):
        self.assertTrue(result['ok'], result)
        return result

    def test_formats_and_cli_unicode_round_trip(self):
        for format in ('zip', '7z', 'zipx', 'wim', 'tar', 'tar.gz', 'tar.bz2', 'tar.xz', 'gz', 'xz', 'bz2', 'sfx'):
            with self.subTest(format=format):
                archive = self.root / f'归档.{format}'
                self.success(execute('compress', archive, format=format, inputs=[self.source]))
                self.success(execute('list', archive))
                process = subprocess.run([str(CLI), 'test', '--quiet', str(archive)], capture_output=True, encoding='utf-8', timeout=30)
                self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
                output = self.root / f'output-{format}'
                self.success(execute('extract', archive, output))
                files = [file for file in output.rglob('*') if file.is_file()]
                self.assertEqual(len(files), 1, files)
                self.assertEqual(files[0].read_bytes(), self.source.read_bytes())

    def test_encryption_and_existing_output_protection(self):
        for format in ('zip-aes256', '7z'):
            archive = self.root / f'secret.{format}'
            password = 'private-value' if format == 'zip-aes256' else '密码😀'
            self.success(execute('compress', archive, password=password, format=format, inputs=[self.source]))
            self.assertFalse(execute('test', archive, password='wrong')['ok'])
            self.success(execute('test', archive, password=password))
            before = archive.read_bytes()
            self.assertFalse(execute('compress', archive, inputs=[self.source])['ok'])
            self.assertEqual(archive.read_bytes(), before)

    def test_traversal_is_rejected_before_publication(self):
        names = ['../escaped.txt']
        if SYSTEM == 'Windows':
            names += ['name:stream', 'CON.txt', 'trailing.', 'trailing ']
        for index, name in enumerate(names):
            archive = self.root / f'unsafe-{index}.zip'
            with zipfile.ZipFile(archive, 'w') as writer:
                writer.writestr(name, 'unsafe')
            self.assertFalse(execute('extract', archive, self.root / f'output-{index}')['ok'])
        self.assertFalse((self.root / 'escaped.txt').exists())

    def test_split_join_and_sha256_match_independent_implementation(self):
        checksum = self.success(execute('checksum', '', inputs=[self.source]))
        self.assertEqual(checksum['files'][0]['sha256'], hashlib.sha256(self.source.read_bytes()).hexdigest())
        split = self.success(execute('splitFile', self.source, self.root / '分片', volume_size=128))
        self.assertTrue(self.source.is_file(), list(self.root.iterdir()))
        self.assertTrue(Path(split['manifest']).is_file(), (split, list(self.root.iterdir())))
        self.assertTrue(Path(split['path']).is_file(), (split, list(self.root.iterdir())))
        output = self.root / '恢复 😀.txt'
        self.success(execute('joinFile', split['path'], output))
        self.assertEqual(output.read_bytes(), self.source.read_bytes())
        self.assertFalse(execute('joinFile', split['path'], output)['ok'])
        self.assertEqual(output.read_bytes(), self.source.read_bytes())

    def test_editor_preserves_original_and_publishes_valid_archive(self):
        archive = self.root / 'editable.zip'
        self.success(execute('compress', archive, inputs=[self.source]))
        listing = self.success(execute('list', archive))
        job = LIB.f7_job_create()
        strings = [str(value).encode('utf-8') for value in [ENGINE, archive, 'rename', self.source.name,
                   '改名 😀.txt', '', listing['version']]]
        try:
            self.success(response(LIB.f7_mutate(job, *strings, None, 0)))
        finally:
            LIB.f7_job_destroy(job)
        self.success(execute('test', archive))
        with zipfile.ZipFile(archive) as reader:
            self.assertEqual(reader.read('改名 😀.txt'), self.source.read_bytes())
        self.assertTrue(list(self.root.glob('editable.zip.f7zip-backup-*')))


if __name__ == '__main__':
    unittest.main()
