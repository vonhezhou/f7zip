"""完整解压后的回收资格、版本保护及真实 macOS 废纸篓往返。"""
from pathlib import Path
import tempfile
import unittest
import ctypes

from native_engine_test import execute, LIB


class ArchiveRecoveryTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='f7zip-recycle-test-')
        self.root = Path(self.temp.name)
        self.source = self.root / 'hello.txt'
        self.source.write_text('recoverable data')
        self.archive = self.root / (self.root.name + '.zip')
        self.assertTrue(execute('compress', self.archive, inputs=[self.source])['ok'])

    def tearDown(self):
        self.root.chmod(0o700)
        self.temp.cleanup()

    def test_only_complete_single_volume_extraction_qualifies(self):
        result = execute('extract', self.archive, self.root / 'all')
        self.assertTrue(result['complete'], result)
        result = execute('extract', self.archive, self.root / 'selected', indices=[0])
        self.assertFalse(result['complete'], result)
        target = self.root / 'existing'
        target.mkdir()
        (target / 'hello.txt').write_text('existing content')
        result = execute('extractHere', self.archive, target, extraction_policy=1)
        self.assertTrue(result['ok'], result)
        self.assertFalse(result['complete'], result)
        self.assertEqual((target / 'hello.txt').read_text(), 'existing content')
        split = self.root / 'split.7z'
        self.assertTrue(execute('compress', split, format='7z', inputs=[self.source], volume_size=1024)['ok'])
        result = execute('extract', Path(str(split) + '.001'), self.root / 'split-output')
        self.assertTrue(result['ok'], result)
        self.assertFalse(result['complete'], result)
        self.assertTrue(self.archive.exists())

    def test_trash_rejects_changed_source_cancel_symlink_and_unwritable_parent(self):
        result = execute('extract', self.archive, self.root / 'output')
        version = result['version']
        self.assertFalse(execute('trash', self.archive, export_version='stale')['ok'])
        alias = self.root / 'alias.zip'
        alias.symlink_to(self.archive)
        self.assertFalse(execute('trash', alias, export_version=version)['ok'])
        job = LIB.f7_job_create()
        LIB.f7_job_cancel(job)
        try:
            response = execute('trash', self.archive, export_version=version, job=job)
            self.assertTrue(response['cancelled'], response)
        finally:
            LIB.f7_job_destroy(job)
        self.root.chmod(0o500)
        try:
            self.assertFalse(execute('trash', self.archive, export_version=version)['ok'])
        finally:
            self.root.chmod(0o700)
        self.assertTrue(self.archive.exists())
        self.assertEqual(list(self.root.glob('.f7zip-*')), [])
        self.assertEqual((self.root / 'output/hello.txt').read_text(), 'recoverable data')
        self.archive.write_bytes(self.archive.read_bytes() + b'changed')
        self.assertFalse(execute('trash', self.archive, export_version=version)['ok'])
        self.assertTrue(self.archive.exists())

    def test_success_moves_only_fixture_to_real_macos_trash(self):
        original = self.archive.read_bytes()
        result = execute('extract', self.archive, self.root / 'output')
        response = execute('trash', self.archive, export_version=result['version'])
        self.assertTrue(response['ok'], response)
        trashed = Path(response['path'])
        try:
            self.assertFalse(self.archive.exists())
            self.assertEqual(trashed.read_bytes(), original)
            self.assertEqual(trashed.name, self.archive.name)
            self.assertEqual((self.root / 'output/hello.txt').read_text(), 'recoverable data')
            self.assertEqual(list(self.root.glob('.f7zip-*')), [])
        finally:
            # 仅回收本用例明确返回并逐字节核对的测试产物。
            if trashed.is_file() and trashed.read_bytes() == original:
                trashed.unlink()

    def test_system_recycle_failure_rolls_back_and_protects_concurrent_file(self):
        # 仅替换外部系统回收边界，实际版本检查、暂存与回滚仍走生产引擎。
        runtime = ctypes.CDLL('/usr/lib/libobjc.A.dylib')
        runtime.objc_getClass.argtypes = [ctypes.c_char_p]
        runtime.objc_getClass.restype = ctypes.c_void_p
        runtime.sel_registerName.argtypes = [ctypes.c_char_p]
        runtime.sel_registerName.restype = ctypes.c_void_p
        runtime.class_getInstanceMethod.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        runtime.class_getInstanceMethod.restype = ctypes.c_void_p
        runtime.method_setImplementation.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        runtime.method_setImplementation.restype = ctypes.c_void_p
        method = runtime.class_getInstanceMethod(runtime.objc_getClass(b'NSFileManager'),
                    runtime.sel_registerName(b'trashItemAtURL:resultingItemURL:error:'))
        callback_type = ctypes.CFUNCTYPE(ctypes.c_bool, *([ctypes.c_void_p] * 5))
        original = self.archive.read_bytes()
        for concurrent in [False, True]:
            with self.subTest(concurrent=concurrent):
                version = execute('list', self.archive)['version']
                calls = []

                def fail_recycle(*arguments):
                    calls.append(self.archive.exists())
                    if concurrent:
                        self.archive.write_bytes(b'concurrent file')
                    return False

                callback = callback_type(fail_recycle)
                previous = runtime.method_setImplementation(method, ctypes.cast(callback, ctypes.c_void_p))
                try:
                    response = execute('trash', self.archive, export_version=version)
                finally:
                    runtime.method_setImplementation(method, previous)
                self.assertFalse(response['ok'], response)
                self.assertEqual(calls, [False])
                if concurrent:
                    self.assertEqual(self.archive.read_bytes(), b'concurrent file')
                    retained = list(self.root.glob('.f7zip-*/' + self.archive.name))
                    self.assertEqual(len(retained), 1)
                    self.assertEqual(retained[0].read_bytes(), original)
                    self.assertIn(str(retained[0].resolve()), response['error'])
                else:
                    self.assertEqual(self.archive.read_bytes(), original)
                    self.assertEqual(list(self.root.glob('.f7zip-*')), [])
