"""通过实际 C ABI 验证压缩结果、失败恢复和解压边界。"""
import bz2
import gzip
import io
import lzma
import tarfile
import struct
import ctypes
import fcntl
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
LIB = ctypes.CDLL(str(ROOT / 'native/lib/libf7zip.dylib'))
LIB.f7_job_create.restype = ctypes.c_void_p
LIB.f7_job_destroy.argtypes = [ctypes.c_void_p]
LIB.f7_job_cancel.argtypes = [ctypes.c_void_p]
LIB.f7_job_export_options.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
LIB.f7_job_extraction_options.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_char_p]
LIB.f7_job_volume_size.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
LIB.f7_job_codepage.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
LIB.f7_free.argtypes = [ctypes.c_void_p]
LIB.f7_run.restype = ctypes.c_void_p
LIB.f7_run.argtypes = [ctypes.c_void_p, *([ctypes.c_char_p] * 6), ctypes.c_int,
                      ctypes.POINTER(ctypes.c_char_p), ctypes.c_int,
                      ctypes.POINTER(ctypes.c_uint32), ctypes.c_int]


def execute(operation, archive, destination='', password='', format='zip', inputs=(), indices=(), job=None, code_page=0, volume_size=0, extraction_policy=0, expected_destination_version='', export_path='', export_version=''):
    owned = job is None
    job = LIB.f7_job_create() if owned else job
    LIB.f7_job_export_options(job, export_path.encode(), export_version.encode())
    LIB.f7_job_extraction_options(job, extraction_policy, expected_destination_version.encode())
    LIB.f7_job_volume_size(job, volume_size)
    LIB.f7_job_codepage(job, code_page)
    strings = [str(value).encode() for value in [ROOT / 'native/lib/7z.so', operation,
               archive, destination, password, format]]
    files = (ctypes.c_char_p * len(inputs))(*(str(value).encode() for value in inputs))
    selection = (ctypes.c_uint32 * len(indices))(*indices)
    pointer = LIB.f7_run(job, *strings, 5, files, len(inputs), selection, len(indices))
    try:
        return json.loads(ctypes.string_at(pointer).decode())
    finally:
        LIB.f7_free(pointer)
        if owned:
            LIB.f7_job_destroy(job)


def update(archive, item, edited, version, password='', job=None, code_page=0):
    owned = job is None
    job = LIB.f7_job_create() if owned else job
    LIB.f7_job_codepage(job, code_page)
    LIB.f7_update.restype = ctypes.c_void_p
    LIB.f7_update.argtypes = [ctypes.c_void_p, *([ctypes.c_char_p] * 6)]
    strings = [str(value).encode() for value in [ROOT / 'native/lib/7z.so', archive,
               item, edited, password, version]]
    pointer = LIB.f7_update(job, *strings)
    try:
        return json.loads(ctypes.string_at(pointer).decode())
    finally:
        LIB.f7_free(pointer)
        if owned:
            LIB.f7_job_destroy(job)


def mutate(archive, action, version, item='', destination='', inputs=(), password='', job=None, code_page=0):
    owned = job is None
    job = LIB.f7_job_create() if owned else job
    LIB.f7_job_codepage(job, code_page)
    LIB.f7_mutate.restype = ctypes.c_void_p
    LIB.f7_mutate.argtypes = [ctypes.c_void_p, *([ctypes.c_char_p] * 7), ctypes.POINTER(ctypes.c_char_p), ctypes.c_int]
    strings = [str(value).encode() for value in [ROOT / 'native/lib/7z.so', archive, action, item, destination, password, version]]
    paths = (ctypes.c_char_p * len(inputs))(*(str(value).encode() for value in inputs))
    pointer = LIB.f7_mutate(job, *strings, paths, len(inputs))
    try:
        return json.loads(ctypes.string_at(pointer).decode())
    finally:
        LIB.f7_free(pointer)
        if owned: LIB.f7_job_destroy(job)


class NativeEngineTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='f7zip-test-')
        self.root = Path(self.temp.name)
        self.source = self.root / '中文目录'
        self.source.mkdir()
        (self.source / '你好.txt').write_text('F7Zip 中文内容 🗂️\n')
        (self.source / 'line\nbreak.txt').write_bytes(b'newline filename')
        (self.source / 'empty').mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def create(self, format='zip', password=''):
        archive = self.root / ('sample.' + format)
        response = execute('compress', archive, format=format, password=password, inputs=[self.source])
        self.assertTrue(response['ok'], response)
        return archive

    def assert_no_staging(self):
        self.assertEqual(list(self.root.glob('.f7zip-*')), [])

    def test_remove_redundant_root_preserves_inner_structure(self):
        for format in ['zip', '7z']:
            with self.subTest(format=format):
                archive = self.create(format=format, password='secret')
                target = self.root / ('flat-' + format)
                self.assertFalse(execute('extractFlat', archive, target, password='wrong')['ok'])
                self.assertFalse(target.exists())
                response = execute('extractFlat', archive, target, password='secret')
                self.assertTrue(response['ok'], response)
                self.assertEqual((target / '你好.txt').read_text(), 'F7Zip 中文内容 🗂️\n')
                self.assertTrue((target / 'empty').is_dir())
                self.assertFalse((target / self.source.name).exists())
                self.assert_no_staging()

    def test_remove_redundant_root_only_removes_one_directory_layer(self):
        cases = [
            ({'root/nested/file.txt': b'content'}, {'nested/file.txt'}),
            ({'root/': b''}, set()),
            ({'file.txt': b'content'}, {'file.txt'}),
            ({'one/a.txt': b'a', 'two/b.txt': b'b'}, {'one/a.txt', 'two/b.txt'}),
            ({'root/a.txt': b'a', '.hidden': b'h'}, {'root/a.txt', '.hidden'}),
            ({}, set()),
        ]
        for index, (entries, expected) in enumerate(cases):
            with self.subTest(entries=entries):
                archive = self.root / f'case-{index}.zip'
                with zipfile.ZipFile(archive, 'w') as output:
                    for name, data in entries.items():
                        output.writestr(name, data)
                target = self.root / f'case-{index}'
                response = execute('extractFlat', archive, target)
                self.assertTrue(response['ok'], response)
                self.assertTrue(target.is_dir())
                self.assertEqual({str(path.relative_to(target)) for path in target.rglob('*')
                                  if path.is_file()}, expected)
                if index == 1:
                    self.assertEqual(list(target.iterdir()), [])
                self.assert_no_staging()

    def test_remove_redundant_root_selection_and_existing_target_protection(self):
        archive = self.root / 'selection.zip'
        with zipfile.ZipFile(archive, 'w') as output:
            output.writestr('root/selected.txt', b'selected')
            output.writestr('other.txt', b'other')
        target = self.root / 'selected'
        self.assertTrue(execute('extractFlat', archive, target, indices=[0])['ok'])
        self.assertEqual((target / 'selected.txt').read_bytes(), b'selected')
        self.assertEqual(list(target.iterdir()), [target / 'selected.txt'])
        archive = self.create()
        target = self.root / 'existing'
        target.mkdir()
        (target / '你好.txt').write_text('keep')
        self.assertFalse(execute('extractHereFlat', archive, target)['ok'])
        self.assertEqual((target / '你好.txt').read_text(), 'keep')
        self.assertEqual({path.name for path in target.iterdir()}, {'你好.txt'})
        (target / '你好.txt').unlink()
        (target / 'keep.txt').write_text('keep')
        self.assertTrue(execute('extractHereFlat', archive, target)['ok'])
        self.assertEqual((target / 'keep.txt').read_text(), 'keep')
        self.assertTrue((target / '你好.txt').is_file())
        self.assertFalse(any(target.glob('.f7zip-*')))
        self.assert_no_staging()

    def test_extract_here_preserves_unrelated_files_and_rejects_collisions(self):
        archive = self.create()
        target = self.root / 'existing'
        target.mkdir()
        existing = target / 'keep.txt'
        existing.write_text('keep')
        response = execute('extractHere', archive, target)
        self.assertTrue(response['ok'], response)
        self.assertEqual((target / '中文目录/你好.txt').read_text(), 'F7Zip 中文内容 🗂️\n')
        self.assertEqual(existing.read_text(), 'keep')
        (target / '中文目录/你好.txt').write_text('changed')
        response = execute('extractHere', archive, target)
        self.assertFalse(response['ok'])
        self.assertFalse(response.get('passwordRequired', False))
        self.assertEqual((target / '中文目录/你好.txt').read_text(), 'changed')
        self.assertEqual(list(target.glob('.f7zip-*')), [])

    def test_extract_here_checks_all_names_before_publishing(self):
        archive = self.root / 'conflicts.zip'
        with zipfile.ZipFile(archive, 'w') as writer:
            writer.writestr('new.txt', 'new')
            writer.writestr('keep.txt', 'replacement')
        target = self.root / 'target'
        target.mkdir()
        (target / 'keep.txt').symlink_to('missing.txt')
        self.assertFalse(execute('extractHere', archive, target)['ok'])
        self.assertFalse((target / 'new.txt').exists())
        self.assertTrue((target / 'keep.txt').is_symlink())
        self.assertEqual(list(target.glob('.f7zip-*')), [])

    def test_extract_here_encrypted_formats_and_wrong_password_retry(self):
        for format in ['zip', 'zip-aes256', '7z', '7z-visible']:
            with self.subTest(format=format):
                archive = self.create(format=format, password='secret')
                target = self.root / ('output-' + format)
                target.mkdir()
                for password in ['', 'wrong']:
                    response = execute('extractHere', archive, target, password=password)
                    self.assertFalse(response['ok'], response)
                    self.assertTrue(response['passwordRequired'], response)
                    self.assertEqual(list(target.iterdir()), [])
                response = execute('extractHere', archive, target, password='secret')
                self.assertTrue(response['ok'], response)
                self.assertTrue((target / '中文目录/你好.txt').exists())

    def test_zip_unicode_roundtrip_and_independent_reader(self):
        archive = self.create()
        with zipfile.ZipFile(archive) as reader:
            self.assertTrue(any('你好.txt' in name for name in reader.namelist()))
            self.assertIsNone(reader.testzip())
        listing = execute('list', archive)
        self.assertTrue(listing['ok'], listing)
        self.assertTrue(any('line\nbreak.txt' in item['path'] for item in listing['items']))
        target = self.root / 'unpacked'
        response = execute('extract', archive, target)
        self.assertTrue(response['ok'], response)
        self.assertEqual((target / '中文目录/你好.txt').read_text(), 'F7Zip 中文内容 🗂️\n')
        self.assert_no_staging()

    def test_7z_encrypted_headers_roundtrip(self):
        archive = self.create('7z', '中文密码🔑')
        self.assertFalse(execute('list', archive)['ok'])
        listing = execute('list', archive, password='中文密码🔑')
        self.assertTrue(listing['ok'], listing)
        self.assertTrue(execute('test', archive, password='中文密码🔑')['ok'])
        target = self.root / 'unpacked'
        self.assertTrue(execute('extract', archive, target, password='中文密码🔑')['ok'])
        self.assertTrue((target / '中文目录/你好.txt').exists())

    def test_zip_password_and_failed_extraction_cleanup(self):
        archive = self.create(password='secret-123')
        target = self.root / 'unpacked'
        response = execute('extract', archive, target, password='wrong')
        self.assertFalse(response['ok'], response)
        self.assertFalse(target.exists())
        self.assert_no_staging()
        self.assertTrue(execute('extract', archive, target, password='secret-123')['ok'])

    def test_extract_selection(self):
        archive = self.create()
        listing = execute('list', archive)['items']
        index = next(item['index'] for item in listing if item['path'].endswith('你好.txt'))
        target = self.root / 'selected'
        self.assertTrue(execute('extract', archive, target, indices=[index])['ok'])
        self.assertTrue((target / '中文目录/你好.txt').exists())
        self.assertFalse((target / '中文目录/line\nbreak.txt').exists())

    def test_path_traversal_rejected(self):
        for name in ['../escaped.txt', '/tmp/f7zip-escaped.txt', 'dir/../../escaped.txt', '..\\escaped.txt']:
            with self.subTest(name=name):
                archive = self.root / 'unsafe.zip'
                with zipfile.ZipFile(archive, 'w') as writer:
                    writer.writestr(name, 'unsafe')
                target = self.root / 'unpacked'
                self.assertFalse(execute('extract', archive, target)['ok'])
                self.assertFalse(target.exists())
                self.assert_no_staging()

    def test_symlink_rejected(self):
        archive = self.root / 'symlink.zip'
        with zipfile.ZipFile(archive, 'w') as writer:
            entry = zipfile.ZipInfo('link')
            entry.create_system = 3
            entry.external_attr = 0o120777 << 16
            writer.writestr(entry, '/tmp')
        target = self.root / 'unpacked'
        self.assertFalse(execute('extract', archive, target)['ok'])
        self.assertFalse(target.exists())

    def test_existing_archive_is_preserved(self):
        archive = self.create()
        original = archive.read_bytes()
        self.assertFalse(execute('compress', archive, inputs=[self.source])['ok'])
        self.assertEqual(archive.read_bytes(), original)

    def test_existing_directory_is_preserved(self):
        archive = self.create()
        target = self.root / 'existing'
        target.mkdir()
        marker = target / 'keep.txt'
        marker.write_text('keep')
        self.assertFalse(execute('extract', archive, target)['ok'])
        self.assertEqual(marker.read_text(), 'keep')

    def test_recursive_output_rejected(self):
        archive = self.source / 'recursive.zip'
        self.assertFalse(execute('compress', archive, inputs=[self.source])['ok'])
        self.assertFalse(archive.exists())
        self.assert_no_staging()

    def test_cancelled_job_has_no_output(self):
        job = LIB.f7_job_create()
        LIB.f7_job_cancel(job)
        try:
            archive = self.root / 'cancelled.zip'
            response = execute('compress', archive, inputs=[self.source], job=job)
            self.assertFalse(response['ok'])
            self.assertTrue(response['cancelled'])
            self.assertFalse(archive.exists())
        finally:
            LIB.f7_job_destroy(job)
        self.assert_no_staging()

    def test_corrupt_archive_leaves_no_output(self):
        archive = self.root / 'corrupt.zip'
        with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_STORED) as writer:
            writer.writestr('content.txt', b'original contents')
        archive.write_bytes(archive.read_bytes().replace(b'original contents', b'modified contents'))
        target = self.root / 'unpacked'
        self.assertFalse(execute('test', archive)['ok'])
        self.assertFalse(execute('extract', archive, target)['ok'])
        self.assertFalse(target.exists())
        self.assert_no_staging()

    def test_cancel_running_job_cleans_partial_archive(self):
        (self.source / 'large.bin').write_bytes(os.urandom(16 * 1024 * 1024))
        archive = self.root / 'running.zip'
        job = LIB.f7_job_create()
        responses = []
        worker = threading.Thread(target=lambda: responses.append(
            execute('compress', archive, inputs=[self.source], job=job)))
        worker.start()
        try:
            deadline = time.monotonic() + 5
            while not list(self.root.glob('.f7zip-*')) and worker.is_alive() and time.monotonic() < deadline:
                time.sleep(0.001)
            self.assertTrue(worker.is_alive(), '任务未进入可取消的执行状态')
            LIB.f7_job_cancel(job)
            worker.join(timeout=10)
            self.assertFalse(worker.is_alive())
            self.assertTrue(responses[0]['cancelled'], responses)
            self.assertFalse(archive.exists())
            self.assert_no_staging()
        finally:
            LIB.f7_job_cancel(job)
            worker.join()
            LIB.f7_job_destroy(job)

    def test_update_preserves_other_entries_and_file_permissions(self):
        archive = self.create()
        archive.chmod(0o640)
        version = execute('list', archive)['version']
        edited = self.root / 'edited.txt'
        edited.write_text('已编辑的内容')
        response = update(archive, '中文目录/你好.txt', edited, version)
        self.assertTrue(response['ok'], response)
        self.assertNotEqual(response['version'], version)
        with zipfile.ZipFile(archive) as reader:
            self.assertEqual(reader.read('中文目录/你好.txt').decode(), '已编辑的内容')
            self.assertEqual(reader.read('中文目录/line\nbreak.txt'), b'newline filename')
        self.assertEqual(archive.stat().st_mode & 0o777, 0o640)
        self.assert_no_staging()

    def test_update_preserves_zip_and_7z_encryption(self):
        for format in ['zip', '7z']:
            with self.subTest(format=format):
                archive = self.create(format, 'secret')
                version = execute('list', archive, password='secret')['version']
                edited = self.root / 'edited.txt'
                edited.write_text('encrypted update')
                response = update(archive, '中文目录/你好.txt', edited, version, password='secret')
                self.assertTrue(response['ok'], response)
                if format == '7z':
                    self.assertFalse(execute('list', archive)['ok'])
                listing = execute('list', archive, password='secret')
                item = next(item for item in listing['items'] if item['path'].endswith('你好.txt'))
                self.assertTrue(item['encrypted'])
                target = self.root / ('updated-' + format)
                self.assertTrue(execute('extract', archive, target, password='secret')['ok'])
                self.assertEqual((target / '中文目录/你好.txt').read_text(), 'encrypted update')
        self.assert_no_staging()

    def test_update_rejects_stale_version_and_preserves_original(self):
        archive = self.create()
        version = execute('list', archive)['version']
        with zipfile.ZipFile(archive, 'a') as writer:
            writer.writestr('external.txt', 'external change')
        original = archive.read_bytes()
        edited = self.root / 'edited.txt'
        edited.write_text('local changes')
        response = update(archive, '中文目录/你好.txt', edited, version)
        self.assertFalse(response['ok'])
        self.assertEqual(archive.read_bytes(), original)
        self.assertEqual(edited.read_text(), 'local changes')
        self.assert_no_staging()

    def test_update_failure_and_cancel_preserve_original(self):
        archive = self.create()
        version = execute('list', archive)['version']
        original = archive.read_bytes()
        response = update(archive, '中文目录/你好.txt', self.root / 'missing.txt', version)
        self.assertFalse(response['ok'])
        self.assertEqual(archive.read_bytes(), original)
        job = LIB.f7_job_create()
        LIB.f7_job_cancel(job)
        try:
            response = update(archive, '中文目录/你好.txt', self.root / 'missing.txt', version, job=job)
            self.assertTrue(response['cancelled'])
            self.assertEqual(archive.read_bytes(), original)
        finally:
            LIB.f7_job_destroy(job)
        self.assert_no_staging()

    def test_update_authenticates_password_before_replacing_single_encrypted_entry(self):
        archive = self.root / 'single.zip'
        source = self.source / '你好.txt'
        self.assertTrue(execute('compress', archive, password='secret', inputs=[source])['ok'])
        version = execute('list', archive, password='secret')['version']
        original = archive.read_bytes()
        edited = self.root / 'edited.txt'
        edited.write_text('new content')
        response = update(archive, '你好.txt', edited, version, password='wrong')
        self.assertFalse(response['ok'])
        self.assertEqual(archive.read_bytes(), original)
        self.assert_no_staging()

    def test_update_rejects_concurrent_writer(self):
        archive = self.create()
        version = execute('list', archive)['version']
        original = archive.read_bytes()
        with archive.open('rb') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            response = update(archive, '中文目录/你好.txt', self.root / 'missing.txt', version)
            self.assertFalse(response['ok'])
        self.assertEqual(archive.read_bytes(), original)

    def test_add_rename_and_remove_directory_tree(self):
        archive = self.create()
        version = execute('list', archive)['version']
        incoming = self.root / 'incoming'
        (incoming / 'nested').mkdir(parents=True)
        (incoming / 'empty').mkdir()
        (incoming / 'nested/new.txt').write_text('new data')
        added = mutate(archive, 'add', version, item='中文目录', inputs=[incoming])
        self.assertTrue(added['ok'], added)
        renamed = mutate(archive, 'rename', added['version'], item='中文目录/incoming', destination='中文目录/renamed')
        self.assertTrue(renamed['ok'], renamed)
        names = [item['path'] for item in renamed['items']]
        self.assertIn('中文目录/renamed/nested/new.txt', names)
        self.assertIn('中文目录/renamed/empty', names)
        removed = mutate(archive, 'remove', renamed['version'], inputs=['中文目录/renamed'])
        self.assertTrue(removed['ok'], removed)
        with zipfile.ZipFile(archive) as reader:
            self.assertFalse(any('renamed' in name for name in reader.namelist()))
            self.assertIn('中文目录/你好.txt', reader.namelist())
        self.assert_no_staging()

    def test_add_conflict_requires_explicit_replace(self):
        archive = self.create()
        version = execute('list', archive)['version']
        original = archive.read_bytes()
        incoming = self.root / '你好.txt'
        incoming.write_text('replacement')
        conflict = mutate(archive, 'add', version, item='中文目录', inputs=[incoming])
        self.assertFalse(conflict['ok'])
        self.assertEqual(conflict['conflicts'], ['中文目录/你好.txt'])
        self.assertEqual(archive.read_bytes(), original)
        replaced = mutate(archive, 'addReplace', version, item='中文目录', inputs=[incoming])
        self.assertTrue(replaced['ok'], replaced)
        with zipfile.ZipFile(archive) as reader:
            self.assertEqual(reader.read('中文目录/你好.txt').decode(), 'replacement')
            self.assertEqual(reader.namelist().count('中文目录/你好.txt'), 1)
        self.assert_no_staging()

    def test_new_folder_and_collision_and_invalid_paths(self):
        archive = self.create()
        created = mutate(archive, 'mkdir', execute('list', archive)['version'], destination='中文目录/新建目录')
        self.assertTrue(created['ok'], created)
        self.assertTrue(next(item for item in created['items'] if item['path'] == '中文目录/新建目录')['directory'])
        original = archive.read_bytes()
        for destination in ['../outside', '/absolute', '中文目录/新建目录', '中文目录/你好.txt/child']:
            with self.subTest(destination=destination):
                response = mutate(archive, 'mkdir', created['version'], destination=destination)
                self.assertFalse(response['ok'])
                self.assertEqual(archive.read_bytes(), original)
        self.assert_no_staging()

    def test_remove_all_and_add_to_empty_archive(self):
        archive = self.create()
        removed = mutate(archive, 'remove', execute('list', archive)['version'], inputs=['中文目录'])
        self.assertTrue(removed['ok'], removed)
        self.assertEqual(removed['items'], [])
        new_file = self.root / 'new.txt'
        new_file.write_text('fresh')
        added = mutate(archive, 'add', removed['version'], inputs=[new_file])
        self.assertTrue(added['ok'], added)
        with zipfile.ZipFile(archive) as reader: self.assertEqual(reader.read('new.txt'), b'fresh')

    def test_mutations_preserve_encryption(self):
        for format in ['zip', '7z']:
            with self.subTest(format=format):
                archive = self.create(format, 'secret')
                version = execute('list', archive, password='secret')['version']
                renamed = mutate(archive, 'rename', version, item='中文目录/你好.txt', destination='中文目录/changed.txt', password='secret')
                self.assertTrue(renamed['ok'], renamed)
                new_file = self.root / 'new.txt'
                new_file.write_text('encrypted new file')
                added = mutate(archive, 'add', renamed['version'], inputs=[new_file], password='secret')
                self.assertTrue(added['ok'], added)
                self.assertTrue(next(item for item in added['items'] if item['path'] == 'new.txt')['encrypted'])
                if format == '7z': self.assertFalse(execute('list', archive)['ok'])
                self.assertTrue(execute('test', archive, password='secret')['ok'])

    def test_failed_mutations_preserve_archive(self):
        archive = self.create()
        version = execute('list', archive)['version']
        original = archive.read_bytes()
        cases = [
            ('rename', '中文目录/你好.txt', '中文目录/line\nbreak.txt', []),
            ('rename', '中文目录', '中文目录/child', []),
            ('add', '', '', [self.root]),
            ('add', '', '', [archive]),
            ('remove', '', '', ['missing']),
        ]
        for action, item, destination, inputs in cases:
            response = mutate(archive, action, version, item=item, destination=destination, inputs=inputs)
            self.assertFalse(response['ok'], response)
            self.assertEqual(archive.read_bytes(), original)
        self.assert_no_staging()

    def test_aes256_zip_roundtrip(self):
        archive = self.root / 'aes.zip'
        self.assertTrue(execute('compress', archive, inputs=[self.source], format='zip-aes256', password='secret')['ok'])
        with zipfile.ZipFile(archive) as reader:
            item = next(item for item in reader.infolist() if item.filename.endswith('你好.txt'))
            self.assertEqual(item.compress_type, 99)
        listing = execute('list', archive)
        item = next(item for item in listing['items'] if item['path'].endswith('你好.txt'))
        self.assertIn('AES-256', item['method'])
        # AES AE-2 使用认证码，CRC32 字段可以缺省。
        self.assertIn(len(item['crc']), [0, 8])
        self.assertTrue(execute('extract', archive, self.root / 'aes-output', password='secret')['ok'])

    def test_archive_comments_survive_mutations(self):
        archive = self.create()
        with zipfile.ZipFile(archive, 'a') as writer:
            writer.comment = b'archive comment'
        listing = execute('list', archive)
        self.assertEqual(listing['comment'], 'archive comment')
        response = mutate(archive, 'rename', listing['version'], item='中文目录/你好.txt', destination='中文目录/renamed.txt')
        self.assertTrue(response['ok'], response)
        with zipfile.ZipFile(archive) as reader:
            self.assertEqual(reader.comment, b'archive comment')
        self.assertEqual(response['comment'], 'archive comment')

    def test_new_creation_formats_readable_by_independent_decoders(self):
        source = self.source / '你好.txt'
        for format, read in [('gz', gzip.decompress), ('xz', lzma.decompress), ('bz2', bz2.decompress)]:
            with self.subTest(format=format):
                archive = self.root / ('payload.' + format)
                response = execute('compress', archive, format=format, inputs=[source])
                self.assertTrue(response['ok'], response)
                self.assertEqual(read(archive.read_bytes()), source.read_bytes())
                self.assertTrue(execute('test', archive)['ok'])
                listing = execute('list', archive)
                self.assertTrue(listing['ok'], listing)
                self.assertFalse(listing['editable'])
                output = self.root / ('output-' + format)
                self.assertTrue(execute('extract', archive, output)['ok'])
                self.assertEqual(next(output.iterdir()).read_bytes(), source.read_bytes())
        archive = self.root / 'payload.tar'
        response = execute('compress', archive, format='tar', inputs=[self.source])
        self.assertTrue(response['ok'], response)
        with tarfile.open(archive) as reader:
            self.assertEqual(reader.extractfile('中文目录/你好.txt').read(), source.read_bytes())
            self.assertTrue(reader.getmember('中文目录/empty').isdir())
        self.assert_no_staging()

    def test_compound_creation_listing_selected_extraction_and_test(self):
        for format in ['tar.gz', 'tar.bz2', 'tar.xz']:
            with self.subTest(format=format):
                archive = self.root / ('compound.' + format)
                response = execute('compress', archive, format=format, inputs=[self.source])
                self.assertTrue(response['ok'], response)
                with tarfile.open(archive) as reader:
                    self.assertEqual(reader.extractfile('中文目录/你好.txt').read(), (self.source / '你好.txt').read_bytes())
                listing = execute('list', archive)
                self.assertTrue(listing['ok'], listing)
                self.assertFalse(listing['editable'])
                item = next(item for item in listing['items'] if item['path'] == '中文目录/你好.txt')
                self.assertTrue(execute('test', archive)['ok'])
                target = self.root / ('selected-' + format)
                self.assertTrue(execute('extract', archive, target, indices=[item['index']])['ok'])
                self.assertEqual((target / item['path']).read_bytes(), (self.source / '你好.txt').read_bytes())
                self.assertEqual(len(list(target.rglob('*.txt'))), 1)
                flat = self.root / ('flat-' + format)
                self.assertTrue(execute('extractFlat', archive, flat)['ok'])
                self.assertTrue((flat / 'empty').is_dir())
                self.assertTrue((flat / '你好.txt').is_file())
        self.assert_no_staging()

    def test_compound_aliases_from_independent_writer(self):
        for extension, mode in [('tgz', 'w:gz'), ('tbz', 'w:bz2'), ('tbz2', 'w:bz2'), ('txz', 'w:xz')]:
            with self.subTest(extension=extension):
                archive = self.root / ('external.' + extension)
                with tarfile.open(archive, mode) as writer:
                    writer.add(self.source, arcname='资料')
                listing = execute('list', archive)
                self.assertTrue(listing['ok'], listing)
                self.assertTrue(any(item['path'] == '资料/你好.txt' for item in listing['items']))
                target = self.root / ('external-' + extension)
                target.mkdir()
                self.assertTrue(execute('extractHereFlat', archive, target)['ok'])
                self.assertEqual((target / '你好.txt').read_bytes(), (self.source / '你好.txt').read_bytes())
        self.assert_no_staging()

    def test_compound_failure_cancellation_and_existing_target_protection(self):
        archive = self.root / 'protected.tar.gz'
        self.assertTrue(execute('compress', archive, format='tar.gz', inputs=[self.source])['ok'])
        existing = self.root / 'existing'
        existing.mkdir()
        marker = existing / 'keep.txt'
        marker.write_bytes(b'keep')
        self.assertFalse(execute('extract', archive, existing)['ok'])
        self.assertEqual(marker.read_bytes(), b'keep')
        with tarfile.open(archive, 'r:gz') as reader:
            self.assertIsNotNone(reader.getmember('中文目录/你好.txt'))
        job = LIB.f7_job_create()
        try:
            LIB.f7_job_cancel(job)
            response = execute('extract', archive, self.root / 'cancelled-compound', job=job)
            self.assertFalse(response['ok'])
            self.assertTrue(response['cancelled'])
            self.assertFalse((self.root / 'cancelled-compound').exists())
        finally:
            LIB.f7_job_destroy(job)
        damaged = self.root / 'damaged.tar.gz'
        damaged.write_bytes(archive.read_bytes()[:30])
        self.assertFalse(execute('extract', damaged, self.root / 'damaged-output')['ok'])
        self.assertFalse((self.root / 'damaged-output').exists())
        self.assert_no_staging()

    def test_compound_archives_reject_unsafe_inner_paths_and_links(self):
        for mode, extension in [('w:gz', 'tgz'), ('w:bz2', 'tbz2'), ('w:xz', 'txz')]:
            for link in [False, True]:
                with self.subTest(mode=mode, link=link):
                    archive = self.root / ('unsafe.' + extension)
                    with tarfile.open(archive, mode) as writer:
                        item = tarfile.TarInfo('link' if link else '../escape.txt')
                        if link:
                            item.type = tarfile.SYMTYPE
                            item.linkname = '../escape.txt'
                            writer.addfile(item)
                        else:
                            item.size = 4
                            writer.addfile(item, io.BytesIO(b'evil'))
                    target = self.root / 'unsafe-result'
                    response = execute('extract', archive, target)
                    self.assertFalse(response['ok'], response)
                    self.assertFalse(target.exists())
                    self.assertFalse((self.root / 'escape.txt').exists())
                    self.assert_no_staging()

    def test_stream_formats_reject_multiple_files_directories_and_passwords(self):
        source = self.source / '你好.txt'
        for format in ['gz', 'xz', 'bz2']:
            for inputs, password in [([self.source], ''), ([source, source], ''), ([source], 'secret')]:
                with self.subTest(format=format, inputs=inputs, password=password):
                    archive = self.root / ('invalid.' + format)
                    response = execute('compress', archive, format=format, inputs=inputs, password=password)
                    self.assertFalse(response['ok'], response)
                    self.assertFalse(archive.exists())
                    self.assert_no_staging()
        for format in ['tar', 'unknown']:
            archive = self.root / ('invalid.' + format)
            self.assertFalse(execute('compress', archive, format=format, inputs=[source], password='secret')['ok'])
            self.assertFalse(archive.exists())
        self.assert_no_staging()

    def legacy_zip(self, name, encoding, names):
        class LegacyInfo(zipfile.ZipInfo):
            def _encodeFilenameFlags(self):
                return self.filename.encode(encoding), self.flag_bits & ~0x800
        archive = self.root / name
        with zipfile.ZipFile(archive, 'w') as writer:
            for path in names:
                writer.writestr(LegacyInfo(path), ('content:' + path).encode())
            writer.writestr('UTF8-中文.txt', b'utf8-marked')
        return archive

    def test_legacy_zip_auto_detection_manual_selection_and_extraction(self):
        cases = [
            ('gb18030', 54936, ['中文目录/测试文档你好世界.txt', '中文目录/另一份文件.txt']),
            ('cp932', 932, ['日本語フォルダ/資料ファイルこんにちは.txt', '日本語フォルダ/報告書.txt']),
            ('big5', 950, ['繁體中文/資料測試檔案.txt']),
            ('cp1252', 1252, ['résumé/café.txt']),
            ('utf8', 65001, ['Unicode中文/文件.txt']),
            ('cp949', 949, ['한글폴더/테스트문서안녕하세요.txt', '한글폴더/자료보고서.txt']),
        ]
        for encoding, code_page, names in cases:
            with self.subTest(encoding=encoding):
                archive = self.legacy_zip('legacy-' + encoding + '.zip', encoding, names)
                for requested in [0, code_page]:
                    listing = execute('list', archive, code_page=requested)
                    self.assertTrue(listing['ok'], listing)
                    self.assertEqual(listing['codePage'], code_page)
                    self.assertEqual({item['path'] for item in listing['items']}, set(names + ['UTF8-中文.txt']))
                    target = self.root / f'output-{encoding}-{requested}'
                    response = execute('extract', archive, target, code_page=requested)
                    self.assertTrue(response['ok'], response)
                    for name in names:
                        self.assertEqual((target / name).read_bytes(), ('content:' + name).encode())
                    self.assertEqual((target / 'UTF8-中文.txt').read_bytes(), b'utf8-marked')
        self.assert_no_staging()

    def test_legacy_zip_edits_keep_decoded_names_and_untouched_content(self):
        names = ['中文目录/测试文档你好世界.txt', '中文目录/另一份文件.txt']
        archive = self.legacy_zip('legacy-edit.zip', 'gb18030', names)
        listing = execute('list', archive, code_page=54936)
        edited = self.root / 'edited.txt'
        edited.write_bytes(b'updated externally')
        response = update(archive, names[0], edited, listing['version'], code_page=54936)
        self.assertTrue(response['ok'], response)
        self.assertEqual({item['path'] for item in response['items']}, set(names + ['UTF8-中文.txt']))
        target = self.root / 'legacy-edited'
        self.assertTrue(execute('extract', archive, target, code_page=54936)['ok'])
        self.assertEqual((target / names[0]).read_bytes(), b'updated externally')
        self.assertEqual((target / names[1]).read_bytes(), ('content:' + names[1]).encode())
        response = mutate(archive, 'rename', response['version'], item=names[1], destination='中文目录/重命名.txt', code_page=54936)
        self.assertTrue(response['ok'], response)
        self.assertIn('中文目录/重命名.txt', {item['path'] for item in response['items']})
        self.assertTrue(execute('test', archive, code_page=54936)['ok'])
        self.assert_no_staging()

    def test_zip_encoding_detects_zip64_and_self_extracting_prefix(self):
        names = ['中文目录/测试文档你好世界.txt', '中文目录/另一份文件.txt']
        original = self.legacy_zip('container.zip', 'gb18030', names).read_bytes()
        end = original.rfind(b'PK\x05\x06')
        central_size, central_offset = struct.unpack_from('<II', original, end + 12)
        zip64_end = struct.pack('<IQHHIIQQQQ', 0x06064b50, 44, 45, 45, 0, 0, 3, 3, central_size, central_offset)
        locator = struct.pack('<IIQI', 0x07064b50, 0, end, 1)
        end_record = bytearray(original[end:])
        struct.pack_into('<HHII', end_record, 8, 0xffff, 0xffff, 0xffffffff, 0xffffffff)
        zip64 = self.root / 'zip64.zip'
        zip64.write_bytes(original[:end] + zip64_end + locator + end_record)
        sfx = self.root / 'prefixed.zip'
        sfx.write_bytes(b'F7Zip prefix for test\n' * 4 + original)
        for archive in [zip64, sfx]:
            with self.subTest(archive=archive):
                listing = execute('list', archive)
                self.assertTrue(listing['ok'], listing)
                self.assertEqual(listing['codePage'], 54936)
                self.assertEqual({item['path'] for item in listing['items']}, set(names + ['UTF8-中文.txt']))
        self.assertFalse(execute('list', zip64, code_page=99999)['ok'])

    def test_zip_encoding_remains_isolated_between_concurrent_jobs(self):
        import concurrent.futures
        chinese = ['中文目录/测试文档你好世界.txt']
        japanese = ['日本語フォルダ/資料ファイルこんにちは.txt']
        archives = [self.legacy_zip('chinese.zip', 'gb18030', chinese),
                    self.legacy_zip('japanese.zip', 'cp932', japanese)]
        def read(index):
            expected = chinese if index % 2 == 0 else japanese
            page = 54936 if index % 2 == 0 else 932
            result = execute('list', archives[index % 2], code_page=page)
            self.assertTrue(result['ok'], result)
            self.assertEqual({item['path'] for item in result['items']}, set(expected + ['UTF8-中文.txt']))
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(read, range(20)))

    def test_empty_input_rejected(self):
        response = execute('compress', self.root / 'empty.zip')
        self.assertFalse(response['ok'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
