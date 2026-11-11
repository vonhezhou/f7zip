"""更新模式的时间规则、同步边界、元数据及失败恢复。"""
import os
from pathlib import Path
import tempfile
import shutil
import subprocess
import threading
import time
import unittest
import zipfile

from native_engine_test import LIB, execute, mutate


class UpdateModesTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='f7zip-update-modes-')
        self.root = Path(self.temp.name)
        self.source = self.root / 'docs'
        self.source.mkdir()
        for name in ('newer.txt', 'older.txt', 'same.txt', 'deleted.txt'):
            path = self.source / name
            path.write_text('original ' + name)
            os.utime(path, (1700000000, 1700000000))
        self.outside = self.root / 'outside.txt'
        self.outside.write_text('preserve outside selected scope')

    def tearDown(self):
        self.temp.cleanup()

    def archive(self, format='zip', password=''):
        archive = self.root / ('sample.' + format)
        response = execute('compress', archive, format=format, password=password,
                           inputs=[self.source, self.outside])
        self.assertTrue(response['ok'], response)
        return archive

    def change_sources(self):
        for name, mtime in [('newer.txt', 1700000100), ('older.txt', 1699999900), ('same.txt', 1700000000)]:
            path = self.source / name
            path.write_text('changed ' + name)
            os.utime(path, (mtime, mtime))
        (self.source / 'deleted.txt').unlink()
        (self.source / 'added.txt').write_text('added')
        (self.source / 'empty').mkdir()

    def update(self, archive, mode, inputs=None, **kwargs):
        version = execute('list', archive, password=kwargs.get('password', ''))['version']
        return mutate(archive, mode, version, inputs=inputs or [self.source], **kwargs)

    def contents(self, archive, password=''):
        destination = self.root / ('extract-' + str(time.monotonic_ns()))
        response = execute('extract', archive, destination=destination, password=password)
        self.assertTrue(response['ok'], response)
        return Path(response['path'])

    def test_time_modes_add_or_freshen_with_old_equal_and_missing_entries(self):
        for format in ('zip', '7z'):
            for mode in ('updateNewer', 'updateExisting'):
                with self.subTest(format=format, mode=mode):
                    archive = self.archive(format)
                    self.change_sources()
                    before = archive.read_bytes()
                    response = self.update(archive, mode)
                    self.assertTrue(response['ok'], response)
                    self.assertEqual(Path(response['backup']).read_bytes(), before)
                    result = self.contents(archive)
                    self.assertEqual((result / 'docs/newer.txt').read_text(), 'changed newer.txt')
                    for name in ('older.txt', 'same.txt', 'deleted.txt'):
                        self.assertEqual((result / 'docs' / name).read_text(), 'original ' + name)
                    self.assertEqual((result / 'docs/added.txt').exists(), mode == 'updateNewer')
                    self.assertEqual((result / 'docs/empty').is_dir(), mode == 'updateNewer')
                    self.assertEqual((result / self.outside.name).read_bytes(), self.outside.read_bytes())
                    archive.unlink()
                    # 每轮恢复原始来源。
                    shutil.rmtree(self.source)
                    self.source.mkdir()
                    for name in ('newer.txt', 'older.txt', 'same.txt', 'deleted.txt'):
                        path = self.source / name
                        path.write_text('original ' + name)
                        os.utime(path, (1700000000, 1700000000))

    def test_sync_replaces_older_and_equal_files_removes_missing_and_preserves_outside(self):
        for format in ('zip', '7z'):
            with self.subTest(format=format):
                archive = self.archive(format)
                if (self.source / 'deleted.txt').exists():
                    self.change_sources()
                response = self.update(archive, 'syncDirectory')
                self.assertTrue(response['ok'], response)
                result = self.contents(archive)
                for name in ('newer.txt', 'older.txt', 'same.txt'):
                    self.assertEqual((result / 'docs' / name).read_text(), 'changed ' + name)
                self.assertFalse((result / 'docs/deleted.txt').exists())
                self.assertTrue((result / 'docs/empty').is_dir())
                self.assertEqual((result / self.outside.name).read_bytes(), self.outside.read_bytes())
                self.assertTrue(Path(response['backup']).exists())

    def test_empty_sync_preserves_explicit_directory_with_implicit_original(self):
        archive = self.root / 'implicit.zip'
        with zipfile.ZipFile(archive, 'w') as writer:
            writer.writestr('docs/only.txt', 'remove')
            writer.writestr('other.txt', 'keep')
        for path in self.source.iterdir():
            path.unlink()
        response = self.update(archive, 'syncDirectory')
        self.assertTrue(response['ok'], response)
        with zipfile.ZipFile(archive) as reader:
            self.assertIn('docs/', reader.namelist())
            self.assertNotIn('docs/only.txt', reader.namelist())
            self.assertEqual(reader.read('other.txt'), b'keep')

    def test_prefix_and_multiple_sync_roots(self):
        archive = self.root / 'prefix.zip'
        with zipfile.ZipFile(archive, 'w') as writer:
            writer.writestr('container/docs/stale.txt', 'delete')
            writer.writestr('container/extra/stale.txt', 'delete')
            writer.writestr('docs/stale.txt', 'keep')
            writer.writestr('container/other.txt', 'keep')
        extra = self.root / 'extra'
        extra.mkdir()
        (extra / 'new.txt').write_text('new')
        version = execute('list', archive)['version']
        response = mutate(archive, 'syncDirectory', version, item='container', inputs=[self.source, extra])
        self.assertTrue(response['ok'], response)
        with zipfile.ZipFile(archive) as reader:
            self.assertIn('container/docs/newer.txt', reader.namelist())
            self.assertIn('container/extra/new.txt', reader.namelist())
            self.assertNotIn('container/docs/stale.txt', reader.namelist())
            self.assertNotIn('container/extra/stale.txt', reader.namelist())
            self.assertEqual(reader.read('docs/stale.txt'), b'keep')
            self.assertEqual(reader.read('container/other.txt'), b'keep')

    def test_noop_does_not_replace_archive_or_create_backup(self):
        archive = self.archive()
        version = execute('list', archive)['version']
        before = archive.read_bytes()
        response = self.update(archive, 'updateExisting')
        self.assertTrue(response['ok'], response)
        self.assertEqual(response['version'], version)
        self.assertEqual(archive.read_bytes(), before)
        self.assertFalse(list(self.root.glob('*.f7zip-backup-*')))

    def test_encrypted_sync_preserves_password_and_backup(self):
        for format in ('zip-aes256', '7z'):
            archive = self.archive(format, 'secret')
            self.change_sources() if (self.source / 'deleted.txt').exists() else None
            before = archive.read_bytes()
            response = self.update(archive, 'syncDirectory', password='secret')
            self.assertTrue(response['ok'], response)
            self.assertEqual(Path(response['backup']).read_bytes(), before)
            result = self.contents(archive, 'secret')
            self.assertEqual((result / 'docs/newer.txt').read_text(), 'changed newer.txt')
            self.assertFalse((result / 'docs/deleted.txt').exists())
            listed = execute('list', archive, password='secret')
            self.assertTrue(all(item['encrypted'] for item in listed['items'] if not item['directory']))
            self.assertFalse(execute('test', archive, password='wrong')['ok'])

    def test_invalid_source_stale_version_cancel_and_retry_preserve_original(self):
        archive = self.archive()
        version = execute('list', archive)['version']
        before = archive.read_bytes()
        cases = [('syncDirectory', [self.outside], version),
                 ('syncDirectory', [self.source], 'stale'),
                 ('syncDirectory', [self.source, self.source], version)]
        link = self.source / 'link'
        link.symlink_to(self.outside)
        cases.append(('updateNewer', [self.source], version))
        for mode, inputs, expected in cases:
            response = mutate(archive, mode, expected, inputs=inputs)
            self.assertFalse(response['ok'], response)
            self.assertEqual(archive.read_bytes(), before)
            self.assertFalse(list(self.root.glob('.f7zip-*')))
        link.unlink()
        job = LIB.f7_job_create()
        try:
            LIB.f7_job_cancel(job)
            response = mutate(archive, 'syncDirectory', version, inputs=[self.source], job=job)
            self.assertTrue(response['cancelled'], response)
            self.assertEqual(archive.read_bytes(), before)
        finally:
            LIB.f7_job_destroy(job)
        self.assertTrue(self.update(archive, 'syncDirectory')['ok'])

    def test_source_change_during_staged_sync_aborts_publication(self):
        archive = self.archive('7z')
        before = archive.read_bytes()
        version = execute('list', archive)['version']
        (self.source / 'large.bin').write_bytes(os.urandom(16 * 1024 * 1024))
        responses = []
        worker = threading.Thread(target=lambda: responses.append(mutate(
            archive, 'syncDirectory', version, inputs=[self.source])))
        worker.start()
        deadline = time.monotonic() + 5
        while not list(self.root.glob('.f7zip-*/update-input-*')) and worker.is_alive() and time.monotonic() < deadline:
            time.sleep(.001)
        self.assertTrue(worker.is_alive())
        (self.source / 'concurrent.txt').write_text('new during operation')
        worker.join(timeout=20)
        self.assertFalse(worker.is_alive())
        self.assertFalse(responses[0]['ok'], responses)
        self.assertIn('来源发生变化', responses[0]['error'])
        self.assertEqual(archive.read_bytes(), before)
        self.assertFalse(list(self.root.glob('.f7zip-*')))

    def test_sync_updates_and_removes_associated_metadata(self):
        def attribute(path, value):
            subprocess.run(['/usr/bin/xattr', '-w', 'com.f7zip.update', value, str(path)], check=True)
        attribute(self.source, 'old directory')
        attribute(self.source / 'newer.txt', 'old file')
        attribute(self.source / 'deleted.txt', 'delete metadata')
        archive = self.archive()
        attribute(self.source, 'new directory')
        attribute(self.source / 'newer.txt', 'new file')
        (self.source / 'deleted.txt').unlink()
        response = self.update(archive, 'syncDirectory')
        self.assertTrue(response['ok'], response)
        result = self.contents(archive)
        self.assertEqual(subprocess.check_output(['/usr/bin/xattr', '-p', 'com.f7zip.update', str(result / 'docs')]).strip(), b'new directory')
        self.assertEqual(subprocess.check_output(['/usr/bin/xattr', '-p', 'com.f7zip.update', str(result / 'docs/newer.txt')]).strip(), b'new file')
        self.assertFalse((result / 'docs/deleted.txt').exists())
        self.assertFalse((result / '__MACOSX').exists())
        subprocess.run(['/usr/bin/xattr', '-d', 'com.f7zip.update', str(self.source)], check=True)
        subprocess.run(['/usr/bin/xattr', '-d', 'com.f7zip.update', str(self.source / 'newer.txt')], check=True)
        response = self.update(archive, 'syncDirectory')
        self.assertTrue(response['ok'], response)
        listed = execute('list', archive)
        self.assertFalse(any(item['path'].startswith('__MACOSX/') for item in listed['items'] if not item['directory']))

    def test_cancel_active_sync_cleans_partial_copy_and_retry_succeeds(self):
        archive = self.archive('7z')
        before = archive.read_bytes()
        version = execute('list', archive)['version']
        (self.source / 'large.bin').write_bytes(os.urandom(16 * 1024 * 1024))
        responses = []
        job = LIB.f7_job_create()
        worker = threading.Thread(target=lambda: responses.append(mutate(
            archive, 'syncDirectory', version, inputs=[self.source], job=job)))
        worker.start()
        try:
            deadline = time.monotonic() + 5
            while not list(self.root.glob('.f7zip-*/update-input-*')) and worker.is_alive() and time.monotonic() < deadline:
                time.sleep(.001)
            self.assertTrue(worker.is_alive())
            LIB.f7_job_cancel(job)
            worker.join(timeout=10)
            self.assertFalse(worker.is_alive())
            self.assertTrue(responses[0]['cancelled'], responses)
            self.assertEqual(archive.read_bytes(), before)
            self.assertFalse(list(self.root.glob('.f7zip-*')))
        finally:
            LIB.f7_job_cancel(job)
            worker.join()
            LIB.f7_job_destroy(job)
        (self.source / 'large.bin').unlink()
        self.assertTrue(self.update(archive, 'syncDirectory')['ok'])

    def test_zip_dos_precision_and_sevenzip_subsecond_updates(self):
        file = self.source / 'newer.txt'
        os.utime(file, ns=(1700000001000000000, 1700000001000000000))
        archive = self.archive()
        before = archive.read_bytes()
        version = execute('list', archive)['version']
        response = self.update(archive, 'updateNewer', inputs=[file], item='docs')
        self.assertTrue(response['ok'], response)
        self.assertEqual(archive.read_bytes(), before)
        self.assertEqual(response['version'], version)
        archive = self.archive('7z')
        file.write_text('subsecond update')
        os.utime(file, ns=(1700000001500000000, 1700000001500000000))
        response = self.update(archive, 'updateExisting', inputs=[file], item='docs')
        self.assertTrue(response['ok'], response)
        result = self.contents(archive)
        self.assertEqual((result / 'docs/newer.txt').read_text(), 'subsecond update')
