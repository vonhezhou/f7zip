"""按实际解码结果选择解压目标，复用冲突事务和根目录设置。"""
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile

from native_engine_test import execute, LIB


class SmartExtractionTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='f7zip-smart-')
        self.root = Path(self.temp.name).resolve()
        self.archive = self.root / 'bundle.zip'
        self.parent = self.root / 'output'
        self.parent.mkdir()
        self.destination = self.parent / 'bundle'

    def tearDown(self):
        self.temp.cleanup()

    def archive_with(self, entries):
        with zipfile.ZipFile(self.archive, 'w') as writer:
            for name, content in entries.items():
                writer.writestr(name, content)

    def extract(self, flat=False, **kwargs):
        return execute('extractSmartFlat' if flat else 'extractSmart', self.archive, self.destination, **kwargs)

    def assert_clean(self):
        self.assertEqual(list(self.parent.rglob('.f7zip-*')), [])

    def test_single_file_goes_directly_to_parent_and_ignores_unrelated_named_folder(self):
        self.archive_with({'file.txt': 'payload'})
        self.destination.mkdir()
        (self.destination / 'keep').write_text('keep')
        result = self.extract()
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['path'], str(self.parent / 'file.txt'))
        self.assertEqual((self.parent / 'file.txt').read_text(), 'payload')
        self.assertEqual((self.destination / 'keep').read_text(), 'keep')
        self.assert_clean()

    def test_single_directory_is_published_without_an_extra_archive_folder(self):
        self.archive_with({'project/a': 'a', 'project/b': 'b'})
        result = self.extract()
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['path'], str(self.parent / 'project'))
        self.assertFalse(self.destination.exists())
        self.assertEqual((self.parent / 'project/a').read_text(), 'a')
        self.assert_clean()

    def test_multiple_roots_use_archive_folder_and_reuse_existing_directory_with_conflicts(self):
        self.archive_with({'a': 'a', 'b': 'b'})
        self.destination.mkdir()
        (self.destination / 'a').write_text('old')
        initial = self.extract()
        self.assertFalse(initial['ok'], initial)
        self.assertEqual(initial['conflicts'], ['a'])
        self.assertFalse((self.destination / 'b').exists())
        result = self.extract(extraction_policy=1, expected_destination_version=initial['destinationVersion'])
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['path'], str(self.destination))
        self.assertEqual((self.destination / 'a').read_text(), 'old')
        self.assertEqual((self.destination / 'b').read_text(), 'b')
        self.assert_clean()

    def test_root_removal_happens_before_smart_target_selection(self):
        self.archive_with({'wrapper/a': 'a', 'wrapper/b': 'b'})
        result = self.extract(flat=True)
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['path'], str(self.destination))
        self.assertEqual((self.destination / 'a').read_text(), 'a')
        self.archive_with({'wrapper/only': 'one'})
        result = self.extract(flat=True)
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['path'], str(self.parent / 'only'))
        self.assertEqual((self.parent / 'only').read_text(), 'one')
        self.assert_clean()

    def test_rename_reports_actual_result_and_overwrite_uses_confirmation_version(self):
        self.archive_with({'file.txt': 'new'})
        file = self.parent / 'file.txt'
        file.write_text('old')
        initial = self.extract()
        self.assertFalse(initial['ok'])
        result = self.extract(extraction_policy=2, expected_destination_version=initial['destinationVersion'])
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['path'], str(self.parent / 'file (2).txt'))
        self.assertEqual(file.read_text(), 'old')
        initial = self.extract()
        result = self.extract(extraction_policy=4, expected_destination_version=initial['destinationVersion'])
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['path'], str(file))
        self.assertEqual(file.read_text(), 'new')
        self.assert_clean()

    def test_selected_items_define_shape_and_empty_archive_still_creates_folder(self):
        self.archive_with({'a': 'a', 'b': 'b'})
        result = self.extract(indices=[1])
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['path'], str(self.parent / 'b'))
        self.assertFalse((self.parent / 'a').exists())
        self.archive_with({})
        result = self.extract()
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['path'], str(self.destination))
        self.assertTrue(self.destination.is_dir())
        self.assert_clean()

    def test_metadata_sidecars_do_not_change_single_file_shape(self):
        source = self.root / 'payload'
        source.write_bytes(b'data')
        subprocess.run(['/usr/bin/xattr', '-w', 'com.f7zip.test', 'metadata', str(source)], check=True)
        self.assertTrue(execute('compress', self.archive, inputs=[source])['ok'])
        result = self.extract()
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['path'], str(self.parent / 'payload'))
        attribute = subprocess.check_output(['/usr/bin/xattr', '-p', 'com.f7zip.test', result['path']], text=True)
        self.assertEqual(attribute.strip(), 'metadata')
        self.assertFalse(self.destination.exists())
        self.assertFalse((self.parent / '__MACOSX').exists())
        self.assert_clean()

    def test_cancelled_smart_job_leaves_parent_untouched(self):
        self.archive_with({'a': 'a'})
        job = LIB.f7_job_create()
        LIB.f7_job_cancel(job)
        try:
            result = self.extract(job=job)
            self.assertFalse(result['ok'])
            self.assertTrue(result['cancelled'])
            self.assertEqual(list(self.parent.iterdir()), [])
        finally:
            LIB.f7_job_destroy(job)
        self.assert_clean()
