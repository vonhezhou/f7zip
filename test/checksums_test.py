"""真实 ABI 的流式摘要、清单发布与取消/并发保护。"""
import hashlib
import ctypes
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest
import zlib

from native_engine_test import LIB, execute


class ChecksumsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='f7zip-checksums-')
        self.root = Path(self.temp.name).resolve()
        self.source = self.root / '123.txt'
        self.source.write_bytes(b'123456789')

    def tearDown(self):
        self.temp.cleanup()

    def test_known_vectors_and_multibuffer_sha256_crc32(self):
        empty = self.root / 'empty'
        empty.touch()
        large = self.root / 'large.bin'
        data = os.urandom(2 * 1024 * 1024 + 17)
        large.write_bytes(data)
        response = execute('checksum', '', inputs=[self.source, empty, large])
        self.assertTrue(response['ok'], response)
        first, zero, binary = response['files']
        self.assertEqual(first['crc32'], 'CBF43926')
        self.assertEqual(first['crc64'], '995DC9BBDF1939FA')
        self.assertEqual(first['sha256'], hashlib.sha256(b'123456789').hexdigest())
        self.assertEqual(zero['crc32'], '00000000')
        self.assertEqual(zero['crc64'], '0000000000000000')
        self.assertEqual(zero['sha256'], hashlib.sha256(b'').hexdigest())
        self.assertEqual(binary['crc32'], f'{zlib.crc32(data):08X}')
        self.assertEqual(binary['sha256'], hashlib.sha256(data).hexdigest())

    def test_sha256_manifest_independent_verification_and_all_algorithms(self):
        for algorithm, digest in [('sha256', hashlib.sha256(self.source.read_bytes()).hexdigest()),
                                  ('crc32', 'CBF43926'), ('crc64', '995DC9BBDF1939FA')]:
            with self.subTest(algorithm=algorithm):
                target = self.root / (algorithm + '.txt')
                response = execute('checksumSave', target, format=algorithm, inputs=[self.source])
                self.assertTrue(response['ok'], response)
                self.assertIn(f'{digest} *123.txt\n', target.read_text())
                if algorithm == 'sha256':
                    result = subprocess.run(['/usr/bin/shasum', '-a', '256', '-c', target.name], cwd=self.root,
                                            capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_manifest_unicode_newline_backslash_and_carriage_return(self):
        for name in ['中文.txt', 'line\nbreak.txt', 'back\\slash', 'end\r']:
            with self.subTest(name=name):
                source = self.root / name
                source.write_bytes(b'payload')
                target = self.root / 'SHA256SUMS'
                response = execute('checksumSave', target, format='sha256', inputs=[source])
                self.assertTrue(response['ok'], response)
                digest = hashlib.sha256(b'payload').hexdigest()
                escaped = name.replace('\\', '\\\\').replace('\n', '\\n').replace('\r', '\\r')
                self.assertEqual(target.read_bytes().decode(), ('\\' if escaped != name else '') + digest + ' *' + escaped + '\n')
                target.unlink()

    def test_verify_reports_missing_and_nonregular_but_hashes_existing_files(self):
        folder = self.root / 'directory'
        folder.mkdir()
        nested = folder / 'file.txt'
        nested.write_text('nested')
        response = execute('checksumVerify', '', destination=self.root,
                           inputs=[self.source, self.root / 'missing', folder, nested])
        self.assertTrue(response['ok'], response)
        self.assertEqual(response['files'][0]['crc32'], 'CBF43926')
        self.assertIn('error', response['files'][1])
        self.assertIn('error', response['files'][2])
        self.assertEqual(response['files'][3]['sha256'], hashlib.sha256(b'nested').hexdigest())

    def test_boundary_and_existing_manifest_protection(self):
        target = self.root / 'SHA256SUMS'
        target.write_bytes(b'existing')
        response = execute('checksumSave', target, format='sha256', inputs=[self.source])
        self.assertFalse(response['ok'], response)
        self.assertEqual(target.read_bytes(), b'existing')
        below = self.root / 'below'
        below.mkdir()
        response = execute('checksumSave', below / 'SUMS', inputs=[self.source], format='sha256')
        self.assertFalse(response['ok'], response)
        self.assertFalse((below / 'SUMS').exists())
        response = execute('checksumVerify', '', destination=below, inputs=[self.source])
        self.assertFalse(response['ok'], response)
        link = self.root / 'link'
        link.symlink_to(below, target_is_directory=True)
        (below / 'file').write_text('data')
        response = execute('checksumVerify', '', destination=self.root, inputs=[link / 'file'])
        self.assertFalse(response['ok'], response)
        response = execute('checksum', '', inputs=[link])
        self.assertFalse(response['ok'], response)
        self.assertFalse(list(self.root.glob('.f7zip-*')))

    def test_active_cancel_and_source_change_leave_no_manifest_and_retry_succeeds(self):
        self.source.write_bytes(b'data' * (16 * 1024 * 1024))
        for cancel in (True, False):
            with self.subTest(cancel=cancel):
                job = LIB.f7_job_create()
                target = self.root / 'SUMS'
                responses = []
                worker = threading.Thread(target=lambda: responses.append(execute(
                    'checksumSave', target, format='sha256', inputs=[self.source], job=job)))
                worker.start()
                try:
                    LIB.f7_job_progress.argtypes = [ctypes.c_void_p]
                    LIB.f7_job_progress.restype = ctypes.c_void_p
                    deadline = time.monotonic() + 5
                    while worker.is_alive() and time.monotonic() < deadline:
                        pointer = LIB.f7_job_progress(job)
                        try:
                            progress = json.loads(ctypes.string_at(pointer))
                        finally:
                            LIB.f7_free(pointer)
                        if progress['completed'] > 0: break
                        time.sleep(.001)
                    self.assertTrue(worker.is_alive())
                    if cancel: LIB.f7_job_cancel(job)
                    else: self.source.touch()
                    worker.join(timeout=10)
                    self.assertFalse(worker.is_alive())
                    self.assertFalse(responses[0]['ok'], responses)
                    if cancel: self.assertTrue(responses[0]['cancelled'])
                    else: self.assertIn('来源发生变化', responses[0]['error'])
                    self.assertFalse(target.exists())
                    self.assertFalse(list(self.root.glob('.f7zip-*')))
                finally:
                    LIB.f7_job_cancel(job)
                    worker.join()
                    LIB.f7_job_destroy(job)
        self.source.write_bytes(b'123456789')
        self.assertTrue(execute('checksumSave', self.root / 'SUMS', format='sha256', inputs=[self.source])['ok'])
