"""有界自有归档候选搜索、源版本、取消与数据只读保护。"""
import ctypes
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest

from native_engine_test import LIB, execute

LIB.f7_job_progress.argtypes = [ctypes.c_void_p]
LIB.f7_job_progress.restype = ctypes.c_void_p


class PasswordSearchTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='f7zip-password-search-')
        self.root = Path(self.temp.name)
        self.source = self.root / 'source.txt'
        self.source.write_text('private payload')
        self.archive = self.root / 'encrypted.zip'

    def tearDown(self):
        self.temp.cleanup()

    def create(self, format='zip', password='secret'):
        result = execute('compress', self.archive, inputs=[self.source], format=format, password=password)
        self.assertTrue(result['ok'], result)
        info = execute('passwordSearchInfo', self.archive)
        self.assertTrue(info['ok'], info)
        return info['version']

    def search(self, version, words, **kwargs):
        return execute('passwordSearch', self.archive, inputs=words, export_version=version, **kwargs)

    def test_four_encryption_modes_exhaustion_found_and_no_plaintext_result(self):
        for format in ['zip', 'zip-aes256', '7z', '7z-visible']:
            with self.subTest(format=format):
                password = 'ascii-12' if format.startswith('zip') else '中文😀-12'
                version = self.create(format, password)
                before = self.archive.read_bytes()
                exhausted = self.search(version, ['wrong', 'also wrong'])
                self.assertEqual(exhausted, {'ok': True, 'found': -1, 'tested': 2})
                found = self.search(version, ['wrong', password, 'unused'])
                self.assertEqual(found, {'ok': True, 'found': 1, 'tested': 2})
                self.assertNotIn(password, json.dumps(found, ensure_ascii=False))
                self.assertEqual(self.archive.read_bytes(), before)
                self.assertFalse(list(self.root.glob('.f7zip-*')))
                self.archive.unlink()

    def test_invalid_batches_and_stale_source_version(self):
        version = self.create()
        for words in [[], ['a'] * 9, ['a' * 4097]]:
            result = self.search(version, words)
            self.assertFalse(result['ok'], result)
        self.assertFalse(self.search('', ['secret'])['ok'])
        self.archive.touch()
        self.assertFalse(self.search(version, ['secret'])['ok'])

    def test_plain_archive_unsupported_formats_symlinks_and_input_size_limits(self):
        version = self.create(password='')
        self.assertFalse(self.search(version, ['anything'])['ok'])
        self.archive.unlink()
        self.assertTrue(execute('compress', self.archive, inputs=[self.source], format='tar')['ok'])
        self.assertFalse(execute('passwordSearchInfo', self.archive)['ok'])
        self.archive.unlink()
        real = self.root / 'real.zip'
        self.archive.symlink_to(real)
        real.write_bytes(b'not an archive')
        self.assertFalse(execute('passwordSearchInfo', self.archive)['ok'])
        self.archive.unlink()
        with self.archive.open('wb') as file:
            file.truncate(513 * 1048576)
        self.assertFalse(execute('passwordSearchInfo', self.archive)['ok'])

    def test_declared_unpacked_budget_is_enforced_before_testing(self):
        import struct
        version = self.create()
        data = bytearray(self.archive.read_bytes())
        central = data.index(b'PK\x01\x02')
        struct.pack_into('<I', data, central + 24, 257 * 1048576)
        struct.pack_into('<I', data, 22, 257 * 1048576)
        self.archive.write_bytes(data)
        info = execute('passwordSearchInfo', self.archive)
        self.assertTrue(info['ok'], info)
        result = self.search(info['version'], ['secret'])
        self.assertFalse(result['ok'], result)
        self.assertIn('256 MiB', result['error'])

    def active(self, mutate=False):
        version = self.create('7z')
        job = LIB.f7_job_create()
        result = []
        worker = threading.Thread(target=lambda: result.append(
            self.search(version, [f'candidate-{time.time_ns()}-{index}' for index in range(8)], job=job)))
        try:
            worker.start()
            deadline = time.monotonic() + 5
            started = False
            while worker.is_alive() and time.monotonic() < deadline:
                pointer = LIB.f7_job_progress(job)
                try:
                    progress = json.loads(ctypes.string_at(pointer))
                finally:
                    LIB.f7_free(pointer)
                if progress['total'] == 8:
                    started = True
                    if mutate:
                        self.archive.touch()
                    else:
                        LIB.f7_job_cancel(job)
                    break
                time.sleep(0.0001)
            worker.join(15)
            self.assertFalse(worker.is_alive())
            self.assertTrue(started, result)
            self.assertFalse(result[0]['ok'], result)
            self.assertFalse(list(self.root.glob('.f7zip-*')))
            return result[0]
        finally:
            worker.join()
            LIB.f7_job_destroy(job)

    def test_active_cancel_and_retry(self):
        result = self.active()
        self.assertTrue(result['cancelled'])
        version = execute('passwordSearchInfo', self.archive)['version']
        self.assertEqual(self.search(version, ['secret'])['found'], 0)

    def test_source_change_during_search_is_rejected(self):
        self.active(mutate=True)
