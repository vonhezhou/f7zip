"""普通 Windows SFX 创建与归档式读取的真实引擎验证。"""
import ctypes
import binascii
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
import zipfile

from native_engine_test import LIB, ROOT, execute, mutate
from archive_comments_test import rar_with_comment

MODULE = ROOT / 'native/sfx/7z-x86.sfx'
CLI = ROOT / 'native/lib/f7zip'
LIB.f7_job_progress.argtypes = [ctypes.c_void_p]
LIB.f7_job_progress.restype = ctypes.c_void_p


class SfxTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='f7zip-sfx-test-')
        self.root = Path(self.temp.name)
        self.source = self.root / '中文😀.txt'
        self.source.write_bytes(b'ordinary SFX payload\n' * 1000)
        self.archive = self.root / 'created.exe'

    def tearDown(self):
        self.temp.cleanup()

    def create(self, **kwargs):
        options = {'format': 'sfx', 'inputs': [self.source]}
        options.update(kwargs)
        return execute('compress', self.archive, **options)

    def test_fixed_x86_module_readonly_listing_selected_extract_and_integrity(self):
        result = self.create()
        self.assertTrue(result['ok'], result)
        data = self.archive.read_bytes()
        self.assertTrue(data.startswith(MODULE.read_bytes()))
        pe = int.from_bytes(data[60:64], 'little')
        self.assertEqual(data[pe:pe + 4], b'PE\x00\x00')
        self.assertEqual(int.from_bytes(data[pe + 4:pe + 6], 'little'), 0x14c)
        listing = execute('list', self.archive)
        self.assertTrue(listing['ok'], listing)
        self.assertFalse(listing['editable'])
        self.assertFalse(listing['commentEditable'])
        self.assertEqual(listing['items'][0]['path'], self.source.name)
        self.assertTrue(execute('test', self.archive)['ok'])
        output = self.root / 'selected'
        self.assertTrue(execute('extract', self.archive, destination=output, indices=[0])['ok'])
        self.assertEqual((output / self.source.name).read_bytes(), self.source.read_bytes())
        changed = mutate(self.archive, 'remove', listing['version'], inputs=[self.source.name])
        self.assertFalse(changed['ok'], changed)
        self.assertEqual(self.archive.read_bytes(), data)
        self.assertFalse(list(self.root.glob('*.f7zip-backup-*')))

    def test_supported_methods_encryption_names_and_unicode_password_retry(self):
        for method in ['Copy', 'LZMA2', 'LZMA', 'PPMd']:
            for format in ['sfx', 'sfx-visible']:
                with self.subTest(method=method, format=format):
                    password = '中文😀 password'
                    result = self.create(format=format, password=password,
                                         compression_parameters=(method, 0, 2, -1))
                    self.assertTrue(result['ok'], result)
                    failed = execute('test', self.archive, password='wrong')
                    self.assertFalse(failed['ok'], failed)
                    self.assertTrue(failed['passwordRequired'], failed)
                    self.assertTrue(execute('test', self.archive, password=password)['ok'])
                    output = self.root / 'decrypted'
                    self.assertTrue(execute('extract', self.archive, destination=output, password=password)['ok'])
                    self.assertEqual((output / self.source.name).read_bytes(), self.source.read_bytes())
                    shutil.rmtree(output)
                    self.archive.unlink()

    def test_zip_sfx_is_parsed_and_unsafe_paths_never_publish(self):
        for unsafe in [False, True]:
            buffer = io.BytesIO()
            with zipfile.ZipFile(buffer, 'w', zipfile.ZIP_DEFLATED) as writer:
                writer.writestr('../escape' if unsafe else '资料😀.txt', b'ZIP SFX data')
                writer.writestr('setup.exe', b'inert data')
            self.archive.write_bytes(MODULE.read_bytes() + buffer.getvalue())
            listing = execute('list', self.archive)
            self.assertTrue(listing['ok'], listing)
            self.assertFalse(listing['editable'])
            output = self.root / 'zip-output'
            result = execute('extract', self.archive, destination=output)
            self.assertEqual(result['ok'], not unsafe, result)
            if unsafe:
                self.assertFalse(output.exists())
                self.assertFalse((self.root / 'escape').exists())
            else:
                self.assertEqual((output / '资料😀.txt').read_bytes(), b'ZIP SFX data')
                self.assertEqual((output / 'setup.exe').read_bytes(), b'inert data')
                shutil.rmtree(output)

    def test_windows_names_links_algorithms_volumes_and_existing_output(self):
        for name in ['AUX.txt', 'COM1.bin', 'COM¹.txt', 'bad:name', 'trailing.', 'trailing ']:
            path = self.root / name
            path.write_bytes(b'input')
            result = self.create(inputs=[path])
            self.assertFalse(result['ok'], result)
            self.assertFalse(self.archive.exists())
            path.unlink()
        link = self.root / 'link'
        link.symlink_to(self.source)
        self.assertFalse(self.create(inputs=[link])['ok'])
        self.assertFalse(self.create(volume_size=1048576)['ok'])
        self.assertFalse(self.create(compression_parameters=('BZip2', 0, 0, -1))['ok'])
        self.archive.write_bytes(b'keep existing')
        self.assertFalse(self.create()['ok'])
        self.assertEqual(self.archive.read_bytes(), b'keep existing')
        self.assertFalse(list(self.root.glob('.f7zip-*')))

    def test_module_integrity_failures_in_isolated_cli_directory(self):
        directory = self.root / 'isolated'
        directory.mkdir()
        for name in ['f7zip', 'libf7zip.dylib', '7z.so']:
            shutil.copy2(ROOT / 'native/lib' / name, directory / name)
        for module in [None, b'wrong', bytearray(MODULE.read_bytes())]:
            path = directory / '7z-x86.sfx'
            if module is not None:
                if len(module) == MODULE.stat().st_size:
                    module[-1] ^= 1
                path.write_bytes(module)
            result = subprocess.run([str(directory / 'f7zip'), 'compress', '--quiet', '--format', 'sfx',
                                     str(self.archive), str(self.source)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertFalse(self.archive.exists())
            self.assertFalse(list(self.root.glob('.f7zip-*')))

    def test_rar_and_rar5_payloads_are_read_as_archives(self):
        fixture = ROOT / 'test/fixtures/libarchive/test_read_format_rar5_stored.rar.uu'
        lines = fixture.read_bytes().splitlines()
        rar5 = b''.join(binascii.a2b_uu(line) for line in lines[1:-2])
        for index, payload in enumerate([rar_with_comment(b''), rar5]):
            self.archive.write_bytes(MODULE.read_bytes() + payload)
            listing = execute('list', self.archive)
            self.assertTrue(listing['ok'], listing)
            self.assertFalse(listing['editable'])
            self.assertTrue(execute('test', self.archive)['ok'])
            output = self.root / f'rar-output-{index}'
            result = execute('extract', self.archive, destination=output)
            self.assertTrue(result['ok'], result)
            expected = b'carrier data' if index == 0 else b'hello libarchive test suite!\n'
            name = 'carrier.txt' if index == 0 else 'helloworld.txt'
            self.assertEqual((output / name).read_bytes(), expected)

    def test_destination_directory_alias_remains_usable(self):
        actual = self.root / 'actual'
        actual.mkdir()
        alias = self.root / 'alias'
        alias.symlink_to(actual, target_is_directory=True)
        self.archive = alias / 'created.exe'
        result = self.create()
        self.assertTrue(result['ok'], result)
        self.assertTrue(execute('test', actual / 'created.exe')['ok'])

    def test_cli_extension_inference_visible_names_and_source_preservation(self):
        result = subprocess.run([str(CLI), 'compress', '--quiet', '--visible-names', '--password-stdin',
                                 str(self.archive), str(self.source)], input='secret\n', capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)['path'], str(self.archive))
        self.assertTrue(execute('list', self.archive)['ok'])
        self.assertTrue(execute('test', self.archive, password='secret')['ok'])
        self.assertTrue(self.source.exists())

    def active(self, change=None):
        self.source.write_bytes(os.urandom(32 * 1048576))
        job = LIB.f7_job_create()
        results = []
        worker = threading.Thread(target=lambda: results.append(self.create(
            job=job, level=1, compression_parameters=('LZMA2', 1, 1, -1))))
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
                if progress['completed'] > 0:
                    active = True
                    if change:
                        change()
                    else:
                        LIB.f7_job_cancel(job)
                    break
                time.sleep(0.001)
            worker.join(30)
            self.assertFalse(worker.is_alive())
            self.assertTrue(active, results)
            self.assertFalse(results[0]['ok'], results)
            self.assertFalse(self.archive.exists())
            self.assertFalse(list(self.root.glob('.f7zip-*')))
            return results[0]
        finally:
            worker.join()
            LIB.f7_job_destroy(job)

    def test_active_cancel_cleanup_and_retry(self):
        self.assertTrue(self.active()['cancelled'])
        self.source.write_bytes(b'retry')
        self.assertTrue(self.create()['ok'])

    def test_source_change_during_create_prevents_publish(self):
        self.active(change=lambda: self.source.touch())

    def test_output_directory_replacement_is_preserved(self):
        parent = self.root / 'output'
        parent.mkdir()
        moved = self.root / 'moved'
        self.archive = parent / 'created.exe'
        def replace():
            parent.rename(moved)
            parent.mkdir()
            (parent / 'keep').write_bytes(b'keep')
        self.active(change=replace)
        self.assertEqual((parent / 'keep').read_bytes(), b'keep')
        self.assertFalse(list(moved.iterdir()))

    def test_corruption_nonarchives_and_prefix_limit_fail_without_output(self):
        self.assertTrue(self.create()['ok'])
        data = bytearray(self.archive.read_bytes())
        data[-1] ^= 1
        self.archive.write_bytes(data)
        self.assertFalse(execute('test', self.archive)['ok'])
        self.archive.write_bytes(b'MZ no archive here')
        self.assertFalse(execute('list', self.archive)['ok'])
        self.archive.write_bytes(b'MZ' + b'\0' * (17 * 1048576) + bytes(data)[MODULE.stat().st_size:])
        self.assertFalse(execute('list', self.archive)['ok'])
        self.assertFalse(list(self.root.glob('.f7zip-*')))
