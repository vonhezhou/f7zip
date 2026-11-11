"""高级创建参数通过真实 ABI 验证，独立解码器校验常用格式。"""
import gzip
import lzma
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest
import zipfile

from native_engine_test import LIB, execute


class CompressionParametersTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='f7zip-parameters-')
        self.root = Path(self.temp.name)
        self.source = self.root / 'payload.txt'
        self.data = b'advanced compression parameters\n' * 10000
        self.source.write_bytes(self.data)

    def tearDown(self):
        self.temp.cleanup()

    def create(self, format, method='auto', dictionary=0, threads=0, solid=-1, **kwargs):
        archive = self.root / ('output.' + format)
        response = execute('compress', archive, inputs=[self.source], format=format,
                           compression_parameters=(method, dictionary, threads, solid), **kwargs)
        self.assertTrue(response['ok'], response)
        return archive

    def test_zip_methods_read_by_independent_decoder(self):
        for method, number in [('Copy', 0), ('Deflate', 8), ('BZip2', 12), ('LZMA', 14)]:
            with self.subTest(method=method):
                archive = self.create('zip', method, dictionary=1 if method == 'LZMA' else 0, threads=2)
                with zipfile.ZipFile(archive) as reader:
                    self.assertEqual(reader.getinfo(self.source.name).compress_type, number)
                    self.assertEqual(reader.read(self.source.name), self.data)
                archive.unlink()

    def test_extra_zip_methods_and_sevenzip_methods_round_trip(self):
        for format, methods in [('zip', ['Deflate64', 'PPMd']),
                                ('7z', ['Copy', 'LZMA', 'LZMA2', 'PPMd', 'BZip2'])]:
            for method in methods:
                with self.subTest(format=format, method=method):
                    dictionary = 1 if method in ('LZMA', 'LZMA2', 'PPMd') else 0
                    archive = self.create(format, method, dictionary, threads=2)
                    listed = execute('list', archive)
                    self.assertTrue(listed['ok'], listed)
                    item = next(item for item in listed['items'] if item['path'] == self.source.name)
                    self.assertIn(method.upper(), item['method'].upper())
                    target = self.root / (format + method)
                    extracted = execute('extract', archive, destination=target)
                    self.assertTrue(extracted['ok'], extracted)
                    self.assertEqual((Path(extracted['path']) / self.source.name).read_bytes(), self.data)
                    archive.unlink()

    def test_stream_dictionary_and_compound_tar(self):
        archive = self.create('xz', dictionary=1, threads=2)
        self.assertEqual(lzma.decompress(archive.read_bytes()), self.data)
        archive = self.create('tar.xz', dictionary=1, threads=2)
        output = subprocess.check_output(['/usr/bin/tar', '-xOf', archive, self.source.name])
        self.assertEqual(output, self.data)
        archive = self.create('gz')
        self.assertEqual(gzip.decompress(archive.read_bytes()), self.data)

    def test_solid_block_enables_cross_file_compression(self):
        self.data = os.urandom(300000)
        self.source.write_bytes(self.data)
        other = self.root / 'second.txt'
        other.write_bytes(self.data)
        sizes = []
        for block in (0, 16):
            archive = self.root / f'solid-{block}.7z'
            response = execute('compress', archive, format='7z', inputs=[self.source, other],
                               compression_parameters=('LZMA2', 1, 2, block))
            self.assertTrue(response['ok'], response)
            sizes.append(archive.stat().st_size)
            self.assertTrue(execute('test', archive)['ok'])
            output = subprocess.check_output(['/usr/bin/tar', '-xOf', archive, other.name])
            self.assertEqual(output, self.data)
        self.assertLess(sizes[1], sizes[0] * .7)

    def test_invalid_combinations_leave_no_files_and_retry_succeeds(self):
        for format, method, dictionary, threads, solid, level in [
            ('zip', 'LZMA2', 0, 0, -1, 5), ('7z', 'Deflate', 0, 0, -1, 5),
            ('xz', 'LZMA2', 0, 0, -1, 5), ('tar', 'auto', 0, 1, -1, 5),
            ('gz', 'auto', 0, 1, -1, 5), ('zip', 'Deflate', 1, 0, -1, 5),
            ('7z', 'LZMA2', 3, 0, -1, 5), ('7z', 'auto', 257, 0, -1, 5),
            ('7z', 'auto', 0, 65, -1, 5), ('7z', 'auto', 0, 0, 17, 5),
            ('zip', 'auto', 0, 0, 16, 5), ('7z', 'Copy', 0, 0, 16, 5),
            ('7z', 'auto', 0, 0, 16, 0), ('zip', 'Deflate', 0, 0, -1, 0),
            ('zip', 'unknown', 0, 0, -1, 5), ('zip', 'auto', 0, 0, -1, 123),
        ]:
            with self.subTest(format=format, method=method, dictionary=dictionary,
                              threads=threads, solid=solid, level=level):
                before = set(self.root.iterdir())
                response = execute('compress', self.root / ('invalid.' + format), format=format,
                                   inputs=[self.source], level=level,
                                   compression_parameters=(method, dictionary, threads, solid))
                self.assertFalse(response['ok'], response)
                self.assertEqual(set(self.root.iterdir()), before)
                self.assertEqual(self.source.read_bytes(), self.data)
        self.create('7z', 'LZMA2', 1, 1, 16)

    def test_existing_group_and_cancel_preserve_sources(self):
        archive = self.root / 'output.7z'
        archive.write_bytes(b'existing')
        response = execute('compress', archive, format='7z', inputs=[self.source],
                           compression_parameters=('LZMA2', 1, 1, 16))
        self.assertFalse(response['ok'])
        self.assertEqual(archive.read_bytes(), b'existing')
        archive.unlink()
        job = LIB.f7_job_create()
        try:
            LIB.f7_job_cancel(job)
            response = execute('compress', archive, job=job, format='7z', inputs=[self.source],
                               compression_parameters=('LZMA2', 1, 1, 16))
            self.assertTrue(response['cancelled'], response)
            self.assertFalse(archive.exists())
            self.assertEqual(set(self.root.iterdir()), {self.source})
        finally:
            LIB.f7_job_destroy(job)

    def test_cancel_active_compression_cleans_output_and_allows_retry(self):
        self.source.write_bytes(os.urandom(16 * 1024 * 1024))
        archive = self.root / 'cancel.7z'
        responses = []
        job = LIB.f7_job_create()
        worker = threading.Thread(target=lambda: responses.append(execute(
            'compress', archive, format='7z', inputs=[self.source], job=job,
            compression_parameters=('LZMA2', 1, 1, 16))))
        worker.start()
        try:
            deadline = time.monotonic() + 5
            while not list(self.root.glob('.f7zip-*')) and worker.is_alive() and time.monotonic() < deadline:
                time.sleep(.001)
            self.assertTrue(worker.is_alive())
            LIB.f7_job_cancel(job)
            worker.join(timeout=10)
            self.assertFalse(worker.is_alive())
            self.assertTrue(responses[0]['cancelled'], responses)
            self.assertEqual(set(self.root.iterdir()), {self.source})
        finally:
            LIB.f7_job_cancel(job)
            worker.join()
            LIB.f7_job_destroy(job)
        self.source.write_bytes(self.data)
        self.create('7z', 'LZMA2', 1, 1, 16)
