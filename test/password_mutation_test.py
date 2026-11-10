"""加密编辑的密码错误必须可识别，重试前保留原包。"""
from pathlib import Path
import tempfile
import unittest

from native_engine_test import execute, update, mutate


class PasswordMutationTest(unittest.TestCase):
    def test_password_failure_is_typed_and_retry_preserves_archive(self):
        with tempfile.TemporaryDirectory(prefix='f7zip-password-mutation-') as temporary:
            root = Path(temporary)
            source = root / 'data.txt'
            source.write_text('original')
            edited = root / 'edited.txt'
            edited.write_text('updated')
            for format in ['zip', '7z']:
                with self.subTest(format=format):
                    archive = root / ('archive.' + format)
                    self.assertTrue(execute('compress', archive, inputs=[source], format=format, password='secret')['ok'])
                    listing = execute('list', archive, password='secret')
                    original = archive.read_bytes()
                    for password in ['', 'wrong']:
                        result = update(archive, 'data.txt', edited, listing['version'], password=password)
                        self.assertFalse(result['ok'], result)
                        self.assertTrue(result.get('passwordRequired'), result)
                        self.assertEqual(archive.read_bytes(), original)
                        result = mutate(archive, 'remove', listing['version'], item='data.txt', password=password)
                        self.assertFalse(result['ok'], result)
                        self.assertTrue(result.get('passwordRequired'), result)
                        self.assertEqual(archive.read_bytes(), original)
                    result = update(archive, 'data.txt', edited, listing['version'], password='secret')
                    self.assertTrue(result['ok'], result)
                    target = root / ('verified-' + format)
                    self.assertTrue(execute('extract', archive, target, password='secret')['ok'])
                    self.assertEqual((target / 'data.txt').read_text(), 'updated')
                    self.assertEqual(list(root.glob('.f7zip-*')), [])
