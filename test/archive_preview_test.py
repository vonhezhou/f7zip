"""预览导出预算覆盖选中内容、元数据和复合归档中间层。"""
import gzip
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
import zipfile

from native_engine_test import execute


class ArchivePreviewTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='f7zip-preview-budget-')
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def export(self, archive, limit):
        listing = execute('list', archive)
        self.assertTrue(listing['ok'], listing)
        return execute('export', archive, self.root / 'content.txt', indices=[0],
                       export_path=listing['items'][0]['path'], export_version=listing['version'],
                       output_limit=limit)

    def assert_rejected(self, result):
        self.assertFalse(result['ok'], result)
        self.assertIn('资源上限', result['error'])
        self.assertFalse(result.get('cancelled', False), result)
        self.assertFalse((self.root / 'content.txt').exists())
        self.assertEqual(list(self.root.glob('.f7zip-*')), [])

    def test_exact_limit_passes_and_lower_limit_rejects_without_output(self):
        archive = self.root / 'small.zip'
        with zipfile.ZipFile(archive, 'w') as writer:
            writer.writestr('hello.txt', b'hello')
            writer.writestr('large.txt', b'x' * 10000)
        self.assert_rejected(self.export(archive, 4))
        result = self.export(archive, 5)
        self.assertTrue(result['ok'], result)
        self.assertEqual((self.root / 'content.txt').read_bytes(), b'hello')

    def test_metadata_counts_toward_budget(self):
        source = self.root / 'hello.txt'
        source.write_bytes(b'hello')
        import subprocess
        subprocess.run(['/usr/bin/xattr', '-w', 'com.apple.ResourceFork', 'r' * 4096, str(source)], check=True)
        archive = self.root / 'metadata.zip'
        self.assertTrue(execute('compress', archive, inputs=[source])['ok'])
        self.assert_rejected(self.export(archive, 5))

    def test_compound_archive_intermediate_layer_has_budget(self):
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode='w') as writer:
            item = tarfile.TarInfo('hello.txt')
            item.size = 5
            writer.addfile(item, io.BytesIO(b'hello'))
        archive = self.root / 'sample.tar.gz'
        archive.write_bytes(gzip.compress(buffer.getvalue()))
        self.assert_rejected(self.export(archive, 5))
        self.assertTrue(self.export(archive, len(buffer.getvalue()))['ok'])
