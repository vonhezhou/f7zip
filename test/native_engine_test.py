"""通过实际 C ABI 验证压缩结果、失败恢复和解压边界。"""
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
LIB.f7_free.argtypes = [ctypes.c_void_p]
LIB.f7_run.restype = ctypes.c_void_p
LIB.f7_run.argtypes = [ctypes.c_void_p, *([ctypes.c_char_p] * 6), ctypes.c_int,
                      ctypes.POINTER(ctypes.c_char_p), ctypes.c_int,
                      ctypes.POINTER(ctypes.c_uint32), ctypes.c_int]


def execute(operation, archive, destination='', password='', format='zip', inputs=(), indices=(), job=None):
    owned = job is None
    job = LIB.f7_job_create() if owned else job
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


def update(archive, item, edited, version, password='', job=None):
    owned = job is None
    job = LIB.f7_job_create() if owned else job
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


def mutate(archive, action, version, item='', destination='', inputs=(), password='', job=None):
    owned = job is None
    job = LIB.f7_job_create() if owned else job
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

    def test_empty_input_rejected(self):
        response = execute('compress', self.root / 'empty.zip')
        self.assertFalse(response['ok'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
