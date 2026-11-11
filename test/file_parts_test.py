"""普通文件分割和合并的校验、顺序、发布及失败保护。"""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest

from native_engine_test import LIB, execute

LIB.f7_job_progress.argtypes = [ctypes.c_void_p]
LIB.f7_job_progress.restype = ctypes.c_void_p


class FilePartsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='f7zip-parts-')
        self.root = Path(self.temp.name)
        self.source = self.root / '中文\n😀.bin'
        self.data = bytes(range(256)) * 100
        self.source.write_bytes(self.data)
        self.prefix = self.root / 'pieces'
        self.destination = self.root / 'restored.bin'

    def tearDown(self):
        self.temp.cleanup()

    def split(self, size=7000, prefix=None):
        result = execute('splitFile', self.source, destination=prefix or self.prefix, volume_size=size)
        self.assertTrue(result['ok'], result)
        return result

    def join(self, source, **kwargs):
        return execute('joinFile', source, destination=self.destination, **kwargs)

    def manifest(self, split):
        return json.loads(Path(split['manifest']).read_text())

    def test_round_trip_independent_hashes_permissions_and_time(self):
        self.source.chmod(0o751)
        os.utime(self.source, ns=(1700000000987654321, 1700000000987654321))
        before = self.source.stat()
        result = self.split()
        metadata = self.manifest(result)
        self.assertEqual(result['count'], 4)
        self.assertEqual(metadata['sha256'], hashlib.sha256(self.data).hexdigest())
        combined = b''
        for index, part in enumerate(metadata['parts']):
            self.assertEqual(part['name'], f'pieces.{index + 1:03}')
            data = (self.root / part['name']).read_bytes()
            self.assertEqual(part['sha256'], hashlib.sha256(data).hexdigest())
            self.assertEqual(part['size'], len(data))
            combined += data
        self.assertEqual(combined, self.data)
        info = execute('partsInfo', result['path'])
        self.assertTrue(info['ok'], info)
        joined = self.join(info['manifest'], export_version=info['version'])
        self.assertTrue(joined['ok'], joined)
        self.assertEqual(self.destination.read_bytes(), self.data)
        self.assertEqual(self.destination.stat().st_mode & 0o777, 0o751)
        self.assertEqual(self.destination.stat().st_mtime_ns, before.st_mtime_ns)
        self.assertEqual(self.source.read_bytes(), self.data)
        self.assertFalse(list(self.root.glob('.f7zip-*')))

    def test_empty_exact_boundary_and_unicode_prefix(self):
        for data in (b'', b'123456', b'1234567'):
            self.source.write_bytes(data)
            prefix = self.root / ('分片\n😀-' + str(len(data)))
            result = self.split(3, prefix)
            self.assertEqual(result['count'], max(1, (len(data) + 2) // 3))
            joined = self.join(result['path'])
            self.assertTrue(joined['ok'], joined)
            self.assertEqual(self.destination.read_bytes(), data)
            self.destination.unlink()

    def test_missing_wrong_extra_and_reordered_parts_fail_without_output(self):
        result = self.split()
        metadata = self.manifest(result)
        last = self.root / metadata['parts'][-1]['name']
        saved = last.read_bytes()
        last.unlink()
        failed = self.join(result['path'])
        self.assertFalse(failed['ok'], failed)
        self.assertIn(last.name, failed['error'])
        self.assertFalse(self.destination.exists())
        last.write_bytes(saved)
        wrong = self.root / metadata['parts'][0]['name']
        original = wrong.read_bytes()
        wrong.write_bytes(b'x' * len(original))
        failed = self.join(result['path'])
        self.assertFalse(failed['ok'], failed)
        self.assertIn('SHA-256', failed['error'])
        self.assertFalse(self.destination.exists())
        wrong.write_bytes(original)
        extra = self.root / 'pieces.999'
        extra.write_bytes(b'extra')
        failed = self.join(result['path'])
        self.assertFalse(failed['ok'], failed)
        self.assertIn(extra.name, failed['error'])
        extra.unlink()
        failed = self.join(self.root / 'pieces.002')
        self.assertFalse(failed['ok'], failed)
        manifest = Path(result['manifest'])
        metadata['parts'][0], metadata['parts'][1] = metadata['parts'][1], metadata['parts'][0]
        manifest.write_text(json.dumps(metadata))
        self.assertFalse(self.join(result['path'])['ok'])
        self.assertFalse(list(self.root.glob('.f7zip-*')))

    def test_manifest_integrity_types_boundaries_and_total_hash(self):
        result = self.split()
        manifest = Path(result['manifest'])
        original = self.manifest(result)
        for key, value in [('version', 2), ('partSize', 0), ('size', True), ('size', 1.0),
                           ('permissions', 0o4777), ('modifiedNanoseconds', 1000000000),
                           ('prefix', '../outside'), ('name', '/outside'), ('sha256', 'g' * 64)]:
            with self.subTest(key=key, value=value):
                metadata = dict(original)
                metadata[key] = value
                manifest.write_text(json.dumps(metadata))
                failed = self.join(result['path'])
                self.assertFalse(failed['ok'], failed)
                self.assertFalse(self.destination.exists())
        metadata = dict(original)
        metadata['sha256'] = '0' * 64
        manifest.write_text(json.dumps(metadata))
        failed = self.join(result['path'])
        self.assertFalse(failed['ok'], failed)
        self.assertIn('合并结果 SHA-256', failed['error'])
        manifest.write_bytes(b'x' * (4 * 1024 * 1024 + 1))
        self.assertFalse(self.join(result['path'])['ok'])
        self.assertFalse(list(self.root.glob('.f7zip-*')))

    def test_stale_manifest_symlinks_and_existing_outputs_preserved(self):
        result = self.split()
        info = execute('partsInfo', result['path'])
        manifest = Path(result['manifest'])
        raw = manifest.read_bytes()
        manifest.write_bytes(raw + b'\n')
        failed = self.join(result['path'], export_version=info['version'])
        self.assertFalse(failed['ok'], failed)
        self.assertIn('清单已变化', failed['error'])
        manifest.write_bytes(raw)
        first = Path(result['path'])
        saved = first.read_bytes()
        first.unlink()
        first.symlink_to(self.source)
        self.assertFalse(self.join(first)['ok'])
        first.unlink()
        first.write_bytes(saved)
        manifest.unlink()
        self.assertFalse(self.join(first)['ok'])
        manifest.symlink_to(self.source)
        self.assertFalse(self.join(first)['ok'])
        manifest.unlink()
        manifest.write_bytes(raw)
        self.destination.write_bytes(b'existing')
        self.assertFalse(self.join(first)['ok'])
        self.assertEqual(self.destination.read_bytes(), b'existing')
        self.assertEqual(self.source.read_bytes(), self.data)

    def test_split_rejects_existing_group_invalid_sizes_and_unwritable_target(self):
        for size in (0, 2097151 * 1048576 + 1):
            failed = execute('splitFile', self.source, destination=self.prefix, volume_size=size)
            self.assertFalse(failed['ok'], failed)
        self.source.write_bytes(b'x' * 10001)
        self.assertFalse(execute('splitFile', self.source, destination=self.prefix, volume_size=1)['ok'])
        self.source.write_bytes(self.data)
        tail = self.root / 'pieces.999'
        tail.write_bytes(b'keep')
        self.assertFalse(execute('splitFile', self.source, destination=self.prefix, volume_size=7000)['ok'])
        self.assertEqual(tail.read_bytes(), b'keep')
        tail.unlink()
        directory = self.root / 'readonly'
        directory.mkdir()
        directory.chmod(0o500)
        try:
            failed = execute('splitFile', self.source, destination=directory / 'parts', volume_size=7000)
            self.assertFalse(failed['ok'], failed)
            self.assertEqual(list(directory.iterdir()), [])
        finally:
            directory.chmod(0o700)
        self.assertFalse(execute('splitFile', self.root, destination=self.prefix, volume_size=7000)['ok'])
        self.assertEqual(self.source.read_bytes(), self.data)
        self.assertFalse(list(self.root.glob('.f7zip-*')))

    def active_operation(self, operation, source, destination, mutate=None):
        job = LIB.f7_job_create()
        responses = []
        worker = threading.Thread(target=lambda: responses.append(execute(
            operation, source, destination=destination, volume_size=16 * 1024 * 1024, job=job)))
        worker.start()
        try:
            deadline = time.monotonic() + 5
            progressed = False
            while worker.is_alive() and time.monotonic() < deadline:
                pointer = LIB.f7_job_progress(job)
                try:
                    progress = json.loads(ctypes.string_at(pointer))
                finally:
                    LIB.f7_free(pointer)
                if progress['completed'] > 0:
                    progressed = True
                    break
                time.sleep(.001)
            self.assertTrue(progressed)
            self.assertTrue(worker.is_alive())
            if mutate: mutate()
            else: LIB.f7_job_cancel(job)
            worker.join(timeout=10)
            self.assertFalse(worker.is_alive())
            self.assertFalse(responses[0]['ok'], responses)
            if not mutate: self.assertTrue(responses[0]['cancelled'])
            self.assertFalse(Path(destination).exists())
            self.assertFalse(list(self.root.glob('.f7zip-*')))
        finally:
            LIB.f7_job_cancel(job)
            worker.join()
            LIB.f7_job_destroy(job)

    def test_active_cancel_split_and_join_cleanup_and_retry(self):
        with self.source.open('wb') as file:
            file.truncate(64 * 1024 * 1024)
        self.active_operation('splitFile', self.source, self.root / 'cancel-split')
        self.assertFalse(list(self.root.glob('cancel-split*')))
        result = self.split(16 * 1024 * 1024)
        self.active_operation('joinFile', result['path'], self.destination)
        joined = self.join(result['path'])
        self.assertTrue(joined['ok'], joined)
        self.assertEqual(self.destination.stat().st_size, self.source.stat().st_size)
        self.assertEqual(hashlib.sha256(self.destination.read_bytes()).hexdigest(), result['sha256'])

    def test_source_change_during_split_and_join_does_not_publish(self):
        with self.source.open('wb') as file:
            file.truncate(64 * 1024 * 1024)
        self.active_operation('splitFile', self.source, self.root / 'changed-split', mutate=lambda: self.source.touch())
        self.assertFalse(list(self.root.glob('changed-split*')))
        result = self.split(16 * 1024 * 1024)
        last = self.root / self.manifest(result)['parts'][-1]['name']
        self.active_operation('joinFile', result['path'], self.destination, mutate=lambda: last.touch())
        self.assertTrue(self.join(result['path'])['ok'])

    def test_output_directory_move_preserves_replacement_and_cleans_staging(self):
        with self.source.open('wb') as file:
            file.truncate(64 * 1024 * 1024)
        output = self.root / 'output'
        output.mkdir()
        moved = self.root / 'moved'
        def move_directory():
            output.rename(moved)
            output.mkdir()
            (output / 'keep.txt').write_bytes(b'keep replacement')
        self.active_operation('splitFile', self.source, output / 'parts', mutate=move_directory)
        self.assertEqual((output / 'keep.txt').read_bytes(), b'keep replacement')
        self.assertEqual(list(moved.iterdir()), [])
        self.assertEqual([path.name for path in output.iterdir()], ['keep.txt'])
        self.assertTrue(execute('splitFile', self.source, destination=output / 'parts', volume_size=16 * 1024 * 1024)['ok'])

    def test_canonical_equivalent_group_names_remain_verifiable(self):
        prefix = self.root / 'café'
        result = self.split(7000, prefix)
        metadata = self.manifest(result)
        for part in metadata['parts']:
            path = self.root / part['name']
            path.rename(self.root / part['name'].replace('é', 'é'))
        info = execute('partsInfo', str(result['path']).replace('é', 'é'))
        self.assertTrue(info['ok'], info)
        joined = self.join(info['manifest'])
        self.assertTrue(joined['ok'], joined)
        self.assertEqual(self.destination.read_bytes(), self.data)
