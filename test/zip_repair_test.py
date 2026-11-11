"""真实 ZIP 损坏样本、独立解码、加密、取消与原文件保护。"""
import ctypes
import io
import json
from pathlib import Path
import struct
import tempfile
import threading
import time
import unittest
import zipfile

from native_engine_test import LIB, execute

LIB.f7_job_progress.argtypes = [ctypes.c_void_p]
LIB.f7_job_progress.restype = ctypes.c_void_p


class StreamingBuffer(io.BytesIO):
    def seek(self, *args):
        raise OSError('streaming')


class ZipRepairTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='f7zip-zip-repair-')
        self.root = Path(self.temp.name)
        self.source = self.root / 'broken.zip'
        self.output = self.root / 'repaired.zip'

    def tearDown(self):
        self.temp.cleanup()

    def archive(self, entries=None, streaming=False, method=zipfile.ZIP_DEFLATED):
        buffer = StreamingBuffer() if streaming else io.BytesIO()
        with zipfile.ZipFile(buffer, 'w', method) as archive:
            for name, data in entries or [('a.txt', b'first' * 100), ('b.txt', b'second' * 100)]:
                archive.writestr(name, data)
        data = buffer.getvalue()
        self.source.write_bytes(data)
        return data

    def without_directory(self, data):
        return data[:data.index(b'PK\x01\x02')]

    def repair(self, **kwargs):
        before = self.source.read_bytes()
        result = execute('repairZip', self.source, destination=self.output, **kwargs)
        self.assertEqual(self.source.read_bytes(), before)
        self.assertEqual([path for path in self.root.iterdir() if path.name.startswith('.f7zip-')], [])
        return result

    def contents(self):
        with zipfile.ZipFile(self.output) as archive:
            self.assertIsNone(archive.testzip())
            return {name: archive.read(name) for name in archive.namelist()}

    def test_missing_and_corrupt_central_directory_and_self_extracting_prefix(self):
        original = self.archive([('中文😀.txt', b'payload'), ('empty/', b'')])
        for data in [self.without_directory(original), original.replace(b'PK\x01\x02', b'BAD!'),
                     b'MZ stub prefix' + self.without_directory(original)]:
            self.source.write_bytes(data)
            result = self.repair()
            self.assertTrue(result['ok'], result)
            self.assertEqual(result['recovered'], 2)
            self.assertEqual(result['rejected'], 0)
            self.assertEqual(self.contents(), {'中文😀.txt': b'payload', 'empty/': b''})
            self.output.unlink()

    def test_corrupt_data_is_skipped_and_later_entries_survive(self):
        data = bytearray(self.archive([('a', b'good'), ('bad', b'broken' * 100), ('z', b'last')]))
        second = data.index(b'PK\x03\x04', 4)
        offset = second + 30 + struct.unpack_from('<H', data, second + 26)[0]
        data[offset] ^= 0x80
        self.source.write_bytes(data)
        result = self.repair()
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['recovered'], 2)
        self.assertEqual(result['rejected'], 1)
        self.assertEqual(result['skipped'][0]['entry'], 'bad')
        self.assertEqual(self.contents(), {'a': b'good', 'z': b'last'})

    def test_broken_first_header_size_does_not_hide_later_records(self):
        data = bytearray(self.archive())
        struct.pack_into('<I', data, 18, len(data) - 50)
        self.source.write_bytes(data)
        result = self.repair()
        self.assertTrue(result['ok'], result)
        self.assertEqual(self.contents(), {'b.txt': b'second' * 100})
        self.assertGreaterEqual(result['rejected'], 1)

    def test_signed_and_unsigned_data_descriptors_with_embedded_markers(self):
        entries = [('raw', b'contains PK\x03\x04 inside PK\x07\x08 data'), ('tail', b'tail')]
        data = self.without_directory(self.archive(entries, streaming=True, method=zipfile.ZIP_STORED))
        signature = b'PK\x07\x08'
        position = data.index(signature, data.index(signature) + 4)
        for content in [data, data[:position] + data[position + 4:]]:
            self.source.write_bytes(content)
            result = self.repair()
            self.assertTrue(result['ok'], result)
            self.assertEqual(self.contents(), dict(entries))
            self.output.unlink()

    def test_unsafe_duplicate_unicode_and_tree_conflicts_are_skipped(self):
        entries = [('ok', b'good'), ('../escape', b'bad'), ('ok', b'duplicate'),
                   ('file', b'file'), ('file/child', b'bad'), ('café', b'nfc'), ('cafe\u0301', b'nfd')]
        self.archive(entries)
        result = self.repair()
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['recovered'], 3)
        self.assertEqual(result['rejected'], 4)
        self.assertEqual(self.contents(), {'ok': b'good', 'file': b'file', 'café': b'nfc'})

    def test_encryption_preserved_wrong_password_retry(self):
        source = self.root / 'secret.txt'
        source.write_text('private payload')
        for format in ['zip', 'zip-aes256']:
            self.source.unlink(missing_ok=True)
            created = execute('compress', self.source, inputs=[source], password='secret', format=format)
            self.assertTrue(created['ok'], created)
            self.source.write_bytes(self.without_directory(self.source.read_bytes()))
            for password in ['', 'wrong']:
                failed = self.repair(password=password)
                self.assertFalse(failed['ok'], failed)
                self.assertTrue(failed['passwordRequired'], failed)
                self.assertFalse(self.output.exists())
            result = self.repair(password='secret')
            self.assertTrue(result['ok'], result)
            listed = execute('list', self.output)
            self.assertTrue(listed['items'][0]['encrypted'])
            self.assertTrue(execute('test', self.output, password='secret')['ok'])
            self.assertFalse(execute('test', self.output, password='wrong')['ok'])

            self.output.unlink()

    def test_zip64_and_excessive_declared_output_are_skipped(self):
        for declared in [0xffffffff, 513 * 1048576]:
            data = bytearray(self.archive())
            struct.pack_into('<I', data, 22, declared)
            self.source.write_bytes(data)
            result = self.repair()
            self.assertTrue(result['ok'], result)
            self.assertEqual(self.contents(), {'b.txt': b'second' * 100})
            self.assertEqual(result['rejected'], 1)
            self.output.unlink()

    def test_existing_output_invalid_input_and_symlink_source_are_preserved(self):
        self.archive()
        self.output.write_bytes(b'keep')
        self.assertFalse(self.repair()['ok'])
        self.assertEqual(self.output.read_bytes(), b'keep')
        self.output.unlink()
        self.source.write_bytes(b'not a zip')
        self.assertFalse(self.repair()['ok'])
        self.assertFalse(self.output.exists())
        real = self.root / 'real.zip'
        self.source.rename(real)
        self.source.symlink_to(real)
        self.assertFalse(self.repair()['ok'])

    def active(self, mutate=None):
        # 扫描完整 64 MiB，确保取消和源变化发生在真实运行期间。
        self.archive([('large', b'x' * (64 * 1048576))], method=zipfile.ZIP_STORED)
        job = LIB.f7_job_create()
        result = []
        worker = threading.Thread(target=lambda: result.append(
            execute('repairZip', self.source, destination=self.output, job=job)))
        try:
            worker.start()
            deadline = time.monotonic() + 10
            active = False
            while worker.is_alive() and time.monotonic() < deadline:
                pointer = LIB.f7_job_progress(job)
                try:
                    progress = json.loads(ctypes.string_at(pointer))
                finally:
                    LIB.f7_free(pointer)
                if progress['completed'] >= 1048576:
                    active = True
                    if mutate:
                        mutate()
                    else:
                        LIB.f7_job_cancel(job)
                    break
                time.sleep(0.001)
            worker.join(20)
            self.assertFalse(worker.is_alive())
            self.assertTrue(active)
            self.assertFalse(result[0]['ok'], result)
            self.assertFalse(self.output.exists())
            self.assertFalse(list(self.root.glob('.f7zip-*')))
            return result[0]
        finally:
            worker.join()
            LIB.f7_job_destroy(job)

    def test_active_cancel_cleans_and_retry_succeeds(self):
        result = self.active()
        self.assertTrue(result['cancelled'])
        self.assertTrue(self.repair()['ok'])

    def test_source_change_during_repair_prevents_publish(self):
        self.active(mutate=lambda: self.source.touch())

    def test_output_parent_move_preserves_replacement(self):
        parent = self.root / 'output'
        parent.mkdir()
        self.output = parent / 'repaired.zip'
        moved = self.root / 'moved'
        def move():
            parent.rename(moved)
            parent.mkdir()
            (parent / 'keep').write_bytes(b'keep')
        self.active(mutate=move)
        self.assertEqual(list(moved.iterdir()), [])
        self.assertEqual((parent / 'keep').read_bytes(), b'keep')
