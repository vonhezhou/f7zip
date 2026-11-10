"""Finder 文件承诺导出的内容根、源版本与无覆盖发布。"""
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import threading
import time
import unittest
import zipfile

from native_engine_test import execute, LIB


class ArchiveExportTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='f7zip-export-')
        self.root = Path(self.temp.name)
        self.archive = self.root / 'bundle.zip'
        with zipfile.ZipFile(self.archive, 'w') as writer:
            writer.writestr('wrapper/folder/data.txt', b'payload')
            writer.writestr('wrapper/folder/other.txt', b'other')
            writer.writestr('outside.txt', b'outside')

    def tearDown(self):
        self.temp.cleanup()

    def export(self, path, destination=None, **kwargs):
        listing = execute('list', self.archive)
        indices = [item['index'] for item in listing['items'] if item['path'] == path or item['path'].startswith(path + '/')]
        return execute('export', self.archive, destination or self.root / 'result',
                       export_path=path, export_version=listing['version'], indices=indices, **kwargs)

    def assert_clean(self):
        self.assertEqual(list(self.root.glob('.f7zip-*')), [])

    def test_nested_file_exports_exact_filename_without_ancestor_folders(self):
        output = self.root / 'renamed.txt'
        result = self.export('wrapper/folder/data.txt', output)
        self.assertTrue(result['ok'], result)
        self.assertEqual(output.read_bytes(), b'payload')
        self.assertFalse((self.root / 'wrapper').exists())
        self.assert_clean()

    def test_implicit_directory_exports_exact_root_and_children(self):
        output = self.root / 'Finder renamed folder'
        result = self.export('wrapper/folder', output)
        self.assertTrue(result['ok'], result)
        self.assertEqual((output / 'data.txt').read_bytes(), b'payload')
        self.assertEqual((output / 'other.txt').read_bytes(), b'other')
        self.assertFalse((output / 'wrapper').exists())
        self.assert_clean()

    def test_existing_files_directories_and_dangling_links_are_preserved(self):
        output = self.root / 'conflict'
        for type in ['file', 'directory', 'symlink']:
            with self.subTest(type=type):
                if type == 'file': output.write_bytes(b'keep')
                elif type == 'directory': output.mkdir()
                else: output.symlink_to('missing')
                result = self.export('wrapper/folder/data.txt', output)
                self.assertFalse(result['ok'], result)
                if type == 'file': self.assertEqual(output.read_bytes(), b'keep')
                if type == 'directory': output.rmdir()
                else: output.unlink()
                self.assert_clean()

    def test_source_version_change_is_rejected_then_new_drag_can_retry(self):
        listing = execute('list', self.archive)
        with zipfile.ZipFile(self.archive, 'a') as writer:
            writer.writestr('new.txt', b'new')
        result = execute('export', self.archive, self.root / 'result', export_path='wrapper/folder/data.txt',
                         export_version=listing['version'], indices=[0])
        self.assertFalse(result['ok'], result)
        self.assertIn('已变化', result['error'])
        self.assertFalse((self.root / 'result').exists())
        self.assertTrue(self.export('wrapper/folder/data.txt')['ok'])
        self.assert_clean()

    def test_export_scope_indices_and_version_are_required(self):
        listing = execute('list', self.archive)
        for path, indices, version in [('..', [0], listing['version']), ('wrapper', [2], listing['version']),
                                       ('wrapper', [], listing['version']), ('wrapper', [0], '')]:
            result = execute('export', self.archive, self.root / 'result', export_path=path,
                             export_version=version, indices=indices)
            self.assertFalse(result['ok'], result)
            self.assertFalse((self.root / 'result').exists())
            self.assert_clean()

    def test_file_export_keeps_resource_fork_and_attributes(self):
        source = self.root / 'source'
        source.mkdir()
        file = source / 'metadata'
        file.write_bytes(b'payload')
        subprocess.run(['/usr/bin/xattr', '-w', 'com.apple.ResourceFork', 'resource data', str(file)], check=True)
        self.archive.unlink()
        self.assertTrue(execute('compress', self.archive, inputs=[source])['ok'])
        output = self.root / 'exported'
        result = self.export('source/metadata', output)
        self.assertTrue(result['ok'], result)
        value = subprocess.check_output(['/usr/bin/xattr', '-p', 'com.apple.ResourceFork', str(output)], text=True)
        self.assertEqual(value.strip(), 'resource data')
        self.assert_clean()

    def test_export_directory_can_be_renamed_with_parent_referencing_symlinks(self):
        self.archive = self.root / 'links.tar'
        with tarfile.open(self.archive, 'w') as writer:
            item = tarfile.TarInfo('wrapper/data')
            item.size = 7
            writer.addfile(item, io.BytesIO(b'payload'))
            item = tarfile.TarInfo('wrapper/alias')
            item.type = tarfile.SYMTYPE
            item.linkname = '../wrapper/data'
            writer.addfile(item)
        output = self.root / 'renamed'
        result = self.export('wrapper', output)
        self.assertTrue(result['ok'], result)
        self.assertEqual((output / 'alias').read_bytes(), b'payload')
        self.assertEqual(os.readlink(output / 'alias'), 'data')
        self.assert_clean()

    def test_encrypted_multivolume_export_checks_all_source_volumes(self):
        source = self.root / 'payload'
        source.write_bytes(os.urandom(12000))
        archive = self.root / 'volumes.7z'
        created = execute('compress', archive, format='7z', password='secret', inputs=[source], volume_size=1000)
        self.assertTrue(created['ok'], created)
        first = Path(created['path'])
        listing = execute('list', first, password='secret')
        output = self.root / 'exported-volume'
        result = execute('export', first, output, password='secret', indices=[0],
                         export_path='payload', export_version=listing['version'])
        self.assertTrue(result['ok'], result)
        self.assertEqual(output.read_bytes(), source.read_bytes())
        second = Path(str(archive) + '.002')
        second.write_bytes(second.read_bytes() + b'changed')
        result = execute('export', first, self.root / 'changed-output', password='secret', indices=[0],
                         export_path='payload', export_version=listing['version'])
        self.assertFalse(result['ok'], result)
        self.assertIn('已变化', result['error'])
        self.assertFalse((self.root / 'changed-output').exists())
        self.assert_clean()

    def test_running_export_cancellation_cleans_partial_result(self):
        with zipfile.ZipFile(self.archive, 'w') as writer:
            writer.writestr('large.bin', os.urandom(32 * 1024 * 1024))
        job = LIB.f7_job_create()
        responses = []
        worker = threading.Thread(target=lambda: responses.append(self.export('large.bin', job=job)))
        worker.start()
        try:
            deadline = time.monotonic() + 10
            while not list(self.root.glob('.f7zip-*')) and worker.is_alive() and time.monotonic() < deadline:
                time.sleep(0.0005)
            self.assertTrue(worker.is_alive(), '任务应在暂存解压阶段取消')
            LIB.f7_job_cancel(job)
            worker.join(timeout=15)
            self.assertFalse(worker.is_alive())
            self.assertTrue(responses[0]['cancelled'], responses)
            self.assertFalse((self.root / 'result').exists())
            self.assert_clean()
        finally:
            LIB.f7_job_cancel(job)
            worker.join()
            LIB.f7_job_destroy(job)
