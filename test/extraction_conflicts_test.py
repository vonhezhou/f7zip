"""解压到已有目录的冲突策略、版本保护与事务回滚。"""
import fcntl
import os
from pathlib import Path
import stat
import tempfile
import threading
import time
import unittest
import zipfile

from native_engine_test import LIB, execute


class ExtractionConflictsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='f7zip-conflicts-')
        self.root = Path(self.temp.name)
        self.archive = self.root / 'bundle.zip'
        self.target = self.root / 'target'
        self.target.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def archive_with(self, files):
        with zipfile.ZipFile(self.archive, 'w') as writer:
            for name, content in files.items():
                writer.writestr(name, content)

    def extract(self, policy=0, **kwargs):
        return execute('extractHere', self.archive, self.target, extraction_policy=policy, **kwargs)

    def assert_clean(self):
        self.assertEqual(list(self.target.glob('.f7zip-*')), [])

    def test_conflict_preflight_then_skip_merge_and_overwrite(self):
        self.archive_with({'folder/keep.txt': 'new', 'folder/added.txt': 'added', 'other.txt': 'other'})
        folder = self.target / 'folder'
        folder.mkdir(mode=0o750)
        (folder / 'keep.txt').write_text('old')
        (folder / 'unrelated.txt').write_text('untouched')
        original_mode = folder.stat().st_mode
        initial = self.extract()
        self.assertEqual(initial['conflicts'], ['folder'])
        self.assertTrue(initial['destinationVersion'])
        self.assertFalse((self.target / 'other.txt').exists())
        merged = self.extract(3, expected_destination_version=initial['destinationVersion'])
        self.assertEqual(merged['conflicts'], ['folder/keep.txt'])
        self.assertFalse((folder / 'added.txt').exists())
        skipped = self.extract(1, expected_destination_version=merged['destinationVersion'])
        self.assertTrue(skipped['ok'], skipped)
        self.assertEqual((folder / 'keep.txt').read_text(), 'old')
        self.assertEqual((folder / 'added.txt').read_text(), 'added')
        self.assertEqual((folder / 'unrelated.txt').read_text(), 'untouched')
        self.assertEqual(folder.stat().st_mode, original_mode)
        self.assertTrue(self.extract(4)['ok'])
        self.assertEqual((folder / 'keep.txt').read_text(), 'new')
        self.assertEqual((folder / 'unrelated.txt').read_text(), 'untouched')
        self.assert_clean()

    def test_merge_disjoint_directories_and_empty_directories(self):
        self.archive_with({'folder/new.txt': 'new', 'folder/empty/': '', 'empty/': ''})
        (self.target / 'folder').mkdir()
        (self.target / 'folder/old.txt').write_text('old')
        self.assertTrue(self.extract(3)['ok'])
        self.assertTrue((self.target / 'empty').is_dir())
        self.assertTrue((self.target / 'folder/empty').is_dir())
        self.assertEqual((self.target / 'folder/old.txt').read_text(), 'old')
        self.assert_clean()

    def test_rename_reserves_incoming_names_and_handles_directories_and_dotfiles(self):
        self.archive_with({'a.txt': 'new', 'a (2).txt': 'natural', 'folder/x': 'x', '.env': 'new-env'})
        (self.target / 'a.txt').write_text('old')
        (self.target / 'folder').mkdir()
        (self.target / 'folder/keep').write_text('keep')
        (self.target / '.env').write_text('old-env')
        result = self.extract(2)
        self.assertTrue(result['ok'], result)
        self.assertEqual((self.target / 'a.txt').read_text(), 'old')
        self.assertEqual((self.target / 'a (2).txt').read_text(), 'natural')
        self.assertEqual((self.target / 'a (3).txt').read_text(), 'new')
        self.assertEqual((self.target / 'folder (2)/x').read_text(), 'x')
        self.assertEqual((self.target / '.env (2)').read_text(), 'new-env')
        self.assert_clean()

    def test_never_follows_destination_symlinks_or_replaces_directories_with_files(self):
        outside = self.root / 'outside'
        outside.mkdir()
        (outside / 'keep').write_text('outside')
        (self.target / 'folder').symlink_to(outside, target_is_directory=True)
        self.archive_with({'folder/keep': 'replacement'})
        for policy in [0, 3, 4]:
            result = self.extract(policy)
            self.assertFalse(result['ok'], result)
        self.assertTrue(self.extract(1)['ok'])
        self.assertTrue(self.extract(2)['ok'])
        self.assertEqual((self.target / 'folder (2)/keep').read_text(), 'replacement')
        self.assertEqual((outside / 'keep').read_text(), 'outside')
        self.archive_with({'directory': 'file'})
        (self.target / 'directory').mkdir()
        self.assertFalse(self.extract(4)['ok'])
        self.assertTrue((self.target / 'directory').is_dir())
        self.assert_clean()

    def test_confirmation_version_detects_changed_files_new_conflicts_and_directory_replacement(self):
        self.archive_with({'folder/keep.txt': 'new', 'new.txt': 'new'})
        folder = self.target / 'folder'
        folder.mkdir()
        file = folder / 'keep.txt'
        file.write_text('old')
        for change in ['file', 'new', 'directory']:
            with self.subTest(change=change):
                initial = self.extract()
                if change == 'file':
                    file.write_text('changed')
                elif change == 'new':
                    (self.target / 'new.txt').write_text('external')
                else:
                    folder.rename(self.target / 'moved')
                    folder.mkdir()
                    file.write_text('replacement')
                result = self.extract(4, expected_destination_version=initial['destinationVersion'])
                self.assertFalse(result['ok'], result)
                self.assertIn('已变化', result['error'])
                self.assertNotEqual(file.read_text(), 'new')
                self.assert_clean()

    def test_failure_after_partial_publication_restores_new_and_replaced_files(self):
        self.archive_with({'a-new.txt': 'added', 'b-existing.txt': 'replacement', 'z-locked.txt': 'replacement'})
        old = self.target / 'b-existing.txt'
        old.write_text('original')
        locked = self.target / 'z-locked.txt'
        locked.write_text('locked')
        os.chflags(locked, stat.UF_IMMUTABLE)
        try:
            result = self.extract(4)
            self.assertFalse(result['ok'], result)
            self.assertFalse((self.target / 'a-new.txt').exists())
            self.assertEqual(old.read_text(), 'original')
            self.assertEqual(locked.read_text(), 'locked')
            self.assert_clean()
        finally:
            os.chflags(locked, 0)
        self.assertTrue(self.extract(4)['ok'])
        self.assertEqual(old.read_text(), 'replacement')
        self.assert_clean()

    def test_cancel_during_publication_restores_all_replaced_files(self):
        self.archive_with({f'{index:04}.txt': 'replacement' for index in range(1500)})
        for index in range(1500):
            (self.target / f'{index:04}.txt').write_text('old')
        job = LIB.f7_job_create()
        responses = []
        worker = threading.Thread(target=lambda: responses.append(self.extract(4, job=job)))
        worker.start()
        try:
            first = self.target / '0000.txt'
            deadline = time.monotonic() + 10
            while first.read_text() == 'old' and worker.is_alive() and time.monotonic() < deadline:
                time.sleep(0.0005)
            self.assertTrue(worker.is_alive(), '任务应在发布期间取消')
            LIB.f7_job_cancel(job)
            worker.join(timeout=15)
            self.assertFalse(worker.is_alive())
            self.assertTrue(responses[0]['cancelled'], responses)
            self.assertTrue(all(path.read_text() == 'old' for path in self.target.glob('*.txt')))
            self.assert_clean()
        finally:
            LIB.f7_job_cancel(job)
            worker.join()
            LIB.f7_job_destroy(job)

    def test_external_write_blocking_rollback_preserves_original_in_recovery_directory(self):
        files = {f'{index:04}.txt': 'replacement' for index in range(1500)}
        files['z-locked.txt'] = 'replacement'
        self.archive_with(files)
        first = self.target / '0000.txt'
        first.write_text('original')
        locked = self.target / 'z-locked.txt'
        locked.write_text('locked')
        os.chflags(locked, stat.UF_IMMUTABLE)
        responses = []
        worker = threading.Thread(target=lambda: responses.append(self.extract(4)))
        worker.start()
        try:
            deadline = time.monotonic() + 10
            while first.read_text() == 'original' and worker.is_alive() and time.monotonic() < deadline:
                time.sleep(0.0005)
            self.assertTrue(worker.is_alive(), '任务应在发布期间修改已发布文件')
            first.write_text('external update')
            worker.join(timeout=15)
            self.assertFalse(worker.is_alive())
            self.assertFalse(responses[0]['ok'], responses)
            recovery = list(self.target.glob('.f7zip-*'))
            self.assertEqual(len(recovery), 1)
            self.assertIn(str(recovery[0]), responses[0]['error'])
            self.assertEqual((recovery[0] / '0000.txt').read_text(), 'original')
            self.assertEqual(first.read_text(), 'external update')
            self.assertFalse((self.target / '0001.txt').exists())
        finally:
            worker.join()
            os.chflags(locked, 0)

    def test_destination_directory_moved_and_replaced_by_symlink_during_publication(self):
        self.archive_with({f'{index:04}.txt': 'replacement' for index in range(1500)})
        for index in range(1500):
            (self.target / f'{index:04}.txt').write_text('old')
        outside = self.root / 'outside'
        outside.mkdir()
        (outside / 'marker').write_text('untouched')
        moved = self.root / 'moved'
        responses = []
        worker = threading.Thread(target=lambda: responses.append(self.extract(4)))
        worker.start()
        try:
            first = self.target / '0000.txt'
            deadline = time.monotonic() + 10
            while first.read_text() == 'old' and worker.is_alive() and time.monotonic() < deadline:
                time.sleep(0.0005)
            self.assertTrue(worker.is_alive(), '任务应在发布期间移动目标目录')
            self.target.rename(moved)
            self.target.symlink_to(outside, target_is_directory=True)
            worker.join(timeout=15)
            self.assertFalse(worker.is_alive())
            self.assertFalse(responses[0]['ok'], responses)
            self.assertTrue(all(path.read_text() == 'old' for path in moved.glob('*.txt')))
            self.assertEqual([path.name for path in outside.iterdir()], ['marker'])
            self.assertEqual(list(moved.glob('.f7zip-*')), [])
        finally:
            worker.join()

    def test_overwrite_never_replaces_source_archive_or_its_hardlink(self):
        self.archive_with({'bundle.zip': 'replacement', 'alias.zip': 'replacement'})
        os.link(self.archive, self.root / 'alias.zip')
        original = self.archive.read_bytes()
        result = execute('extractHere', self.archive, self.root, extraction_policy=4)
        self.assertFalse(result['ok'], result)
        self.assertIn('原压缩包', result['error'])
        self.assertEqual(self.archive.read_bytes(), original)
        self.assertEqual((self.root / 'alias.zip').read_bytes(), original)
        self.assertEqual(list(self.root.glob('.f7zip-*')), [])

    def test_directory_lock_and_selected_flat_extraction(self):
        self.archive_with({'wrapper/a.txt': 'a', 'wrapper/b.txt': 'b'})
        descriptor = os.open(self.target, os.O_RDONLY)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertFalse(self.extract(4)['ok'])
            self.assert_clean()
        finally:
            os.close(descriptor)
        (self.target / 'a.txt').write_text('old')
        result = execute('extractHereFlat', self.archive, self.target, extraction_policy=2, indices=[0])
        self.assertTrue(result['ok'], result)
        self.assertEqual((self.target / 'a (2).txt').read_text(), 'a')
        self.assertFalse((self.target / 'b.txt').exists())
        self.assert_clean()
