"""ZIPX 与 WIM 创建的格式、参数、元数据和失败边界。"""
import ctypes
import os
from pathlib import Path
import tempfile
import subprocess
import threading
import time
import unittest
import zipfile

from native_engine_test import LIB, execute


class ExtraFormatsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='f7zip-extra-formats-')
        self.root = Path(self.temp.name)
        self.source = self.root / '中文😀.txt'
        self.data = b'extra format payload\n' * 1000
        self.source.write_bytes(self.data)

    def tearDown(self):
        self.temp.cleanup()

    def create(self, format, **kwargs):
        return execute('compress', self.root / ('output.' + format), format=format,
                       inputs=[self.source], level=0 if format == 'wim' else 5, **kwargs)

    def test_zipx_default_lzma_and_bzip2_independent_python_reading(self):
        for method, zip_method in [('auto', zipfile.ZIP_LZMA), ('BZip2', zipfile.ZIP_BZIP2)]:
            result = self.create('zipx', compression_parameters=(method, 0, 0, -1))
            self.assertTrue(result['ok'], result)
            with zipfile.ZipFile(result['path']) as archive:
                self.assertEqual(archive.getinfo(self.source.name).compress_type, zip_method)
                self.assertEqual(archive.read(self.source.name), self.data)
                self.assertIsNone(archive.testzip())
            Path(result['path']).unlink()

    def test_zipx_ppmd_encryption_and_stored_mode(self):
        result = self.create('zipx-aes256', password='secret', compression_parameters=('PPMd', 1, 2, -1))
        self.assertTrue(result['ok'], result)
        self.assertTrue(execute('test', result['path'], password='secret')['ok'])
        self.assertFalse(execute('test', result['path'], password='wrong')['ok'])
        listed = execute('list', result['path'])
        self.assertIn('PPMd', listed['items'][0]['method'])
        self.assertTrue(listed['items'][0]['encrypted'])
        stored = self.root / 'stored.zipx'
        result = execute('compress', stored, format='zipx', level=0, inputs=[self.source])
        self.assertTrue(result['ok'], result)
        with zipfile.ZipFile(stored) as archive:
            self.assertEqual(archive.getinfo(self.source.name).compress_type, zipfile.ZIP_STORED)
            self.assertEqual(archive.read(self.source.name), self.data)

    def test_wim_signature_store_readonly_and_metadata_roundtrip(self):
        self.source.chmod(0o751)
        subprocess.run(['/usr/bin/xattr', '-w', 'com.f7zip.extra', 'metadata', str(self.source)], check=True)
        result = self.create('wim')
        self.assertTrue(result['ok'], result)
        archive = Path(result['path'])
        self.assertEqual(archive.read_bytes()[:8], b'MSWIM\x00\x00\x00')
        listed = execute('list', archive)
        self.assertTrue(listed['ok'], listed)
        self.assertFalse(listed['editable'])
        data_entry = next(item for item in listed['items'] if item['path'] == self.source.name)
        self.assertEqual(data_entry['method'], 'Copy')
        output = self.root / 'extracted'
        extracted = execute('extract', archive, destination=output)
        self.assertTrue(extracted['ok'], extracted)
        restored = output / self.source.name
        self.assertEqual(restored.read_bytes(), self.data)
        self.assertEqual(restored.stat().st_mode & 0o777, 0o751)
        self.assertEqual(subprocess.check_output(['/usr/bin/xattr', '-p', 'com.f7zip.extra', str(restored)]).strip(), b'metadata')

    def test_wim_empty_directory_multiple_inputs_and_unicode_normalization(self):
        empty = self.root / 'empty'
        empty.mkdir()
        source = self.root / 'cafe\u0301.txt'
        source.write_bytes(b'normalized')
        archive = self.root / 'multiple.wim'
        result = execute('compress', archive, format='wim', level=0,
                         inputs=[source, empty], filename_normalization=1)
        self.assertTrue(result['ok'], result)
        output = self.root / 'normalized'
        extracted = execute('extract', archive, destination=output)
        self.assertTrue(extracted['ok'], extracted)
        self.assertEqual((output / 'café.txt').read_bytes(), b'normalized')
        self.assertTrue((output / 'empty').is_dir())

    def test_invalid_parameters_and_existing_output_protection(self):
        for format, options in [
            ('wim', {'password': 'secret'}),
            ('wim', {'volume_size': 1048576}),
            ('wim', {'compression_parameters': ('auto', 0, 2, -1)}),
            ('wim', {'compression_parameters': ('LZMA', 0, 0, -1)}),
            ('zipx', {'compression_parameters': ('Deflate', 0, 0, -1)}),
        ]:
            result = self.create(format, **options)
            self.assertFalse(result['ok'], result)
            self.assertFalse(list(self.root.glob('output.*')))
        self.assertFalse(execute('compress', self.root / 'bad.wim', format='wim', inputs=[self.source])['ok'])
        for format in ['wim', 'zipx']:
            output = self.root / ('output.' + format)
            output.write_bytes(b'keep existing')
            self.assertFalse(self.create(format)['ok'])
            self.assertEqual(output.read_bytes(), b'keep existing')
            output.unlink()
        self.assertFalse(list(self.root.glob('.f7zip-*')))

    def test_zipx_volume_creation_reading_and_missing_volume(self):
        self.source.write_bytes(os.urandom(2200000))
        result = self.create('zipx', volume_size=1048576)
        self.assertTrue(result['ok'], result)
        self.assertTrue(str(result['path']).endswith('.001'))
        self.assertTrue(execute('test', result['path'])['ok'])
        Path(str(result['path'])[:-3] + '002').unlink()
        self.assertFalse(execute('test', result['path'])['ok'])

    def test_active_cancel_zipx_and_wim_cleanup_and_retry(self):
        self.source.write_bytes(os.urandom(32 * 1048576))
        for format in ['zipx', 'wim']:
            job = LIB.f7_job_create()
            result = []
            worker = threading.Thread(target=lambda: result.append(self.create(format, job=job)))
            try:
                worker.start()
                deadline = time.monotonic() + 5
                active = False
                while worker.is_alive() and time.monotonic() < deadline:
                    if list(self.root.glob('.f7zip-*')):
                        active = True
                        LIB.f7_job_cancel(job)
                        break
                    time.sleep(0.001)
                worker.join(30)
                self.assertFalse(worker.is_alive())
                self.assertTrue(active)
                self.assertFalse(result[0]['ok'], result)
                self.assertTrue(result[0]['cancelled'], result)
                self.assertFalse(list(self.root.glob('output.*')))
                self.assertFalse(list(self.root.glob('.f7zip-*')))
            finally:
                worker.join()
                LIB.f7_job_destroy(job)
            retried = self.create(format)
            self.assertTrue(retried['ok'], retried)
            Path(retried['path']).unlink()
