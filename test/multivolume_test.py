"""真实分卷的透明读取、只读边界与失败保护。"""
import binascii
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile
import zlib

from native_engine_test import execute, mutate, ROOT, LIB


class MultiVolumeTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='f7zip-volumes-test-')
        self.root = Path(self.temp.name)
        self.source = self.root / 'payload.bin'
        self.source.write_bytes(os.urandom(250000))

    def tearDown(self):
        self.temp.cleanup()

    def numbered(self, name='bundle', password=''):
        archive = self.root / (name + '.7z')
        self.assertTrue(execute('compress', archive, format='7z', password=password, inputs=[self.source])['ok'])
        data = archive.read_bytes()
        parts = []
        for index, offset in enumerate(range(0, len(data), 50000), 1):
            path = self.root / f'{name}.7z.{index:03}'
            path.write_bytes(data[offset:offset + 50000])
            parts.append(path)
        return parts

    def zip_parts(self):
        archive = self.root / 'split.zip'
        subprocess.run(['/usr/bin/zip', '-0', '-s', '64k', str(archive), self.source.name],
                       cwd=self.root, check=True, stdout=subprocess.DEVNULL)
        return archive, sorted(self.root.glob('split.z[0-9]*'))

    def rar_parts(self):
        parts = []
        for source in sorted((ROOT / 'test/fixtures/libarchive').glob('test_rar_multivolume_single_file.part*.rar.uu')):
            lines = source.read_bytes().splitlines()
            target = self.root / source.stem
            target.write_bytes(b''.join(binascii.a2b_uu(line) for line in lines[1:] if line != b'end'))
            parts.append(target)
        return parts

    def assert_failed_output(self, archive, name='failed', **kwargs):
        output = self.root / name
        result = execute('extract', archive, output, **kwargs)
        self.assertFalse(result['ok'], result)
        self.assertTrue(result.get('volumeError'), result)
        self.assertFalse(output.exists())
        self.assertEqual(list(self.root.glob('.f7zip-*')), [])
        return result

    def test_numbered_7z_transparent_listing_selection_and_encryption(self):
        parts = self.numbered(password='secret')
        self.assertTrue(execute('list', parts[0])['passwordRequired'])
        listing = execute('list', parts[0], password='secret')
        self.assertTrue(listing['ok'], listing)
        self.assertFalse(listing['editable'])
        self.assertEqual(listing['volumes'], len(parts))
        self.assertEqual([item['path'] for item in listing['items']], ['payload.bin'])
        output = self.root / 'decrypted'
        extracted = execute('extract', parts[0], output, password='secret', indices=[0])
        self.assertTrue(extracted['ok'], extracted)
        self.assertEqual(extracted['version'], listing['version'])
        self.assertEqual((output / 'payload.bin').read_bytes(), self.source.read_bytes())
        self.assertTrue(execute('test', parts[0], password='secret')['ok'])
        before = listing['version']
        os.utime(parts[1], None)
        self.assertNotEqual(execute('list', parts[0], password='secret')['version'], before)

    def test_unicode_and_newline_archive_names_track_every_part(self):
        parts = self.numbered(name='资料\n分卷')
        first = execute('list', parts[0])
        self.assertTrue(first['ok'], first)
        self.assertEqual(first['volumes'], len(parts))
        metadata = parts[1].stat()
        os.utime(parts[1], ns=(metadata.st_atime_ns, metadata.st_mtime_ns + 1000000))
        changed = execute('list', parts[0])
        self.assertTrue(changed['ok'], changed)
        self.assertNotEqual(first['version'], changed['version'])

    def test_numbered_7z_missing_wrong_corrupt_and_nonfirst_parts(self):
        for mode in ['missing', 'swapped', 'corrupt']:
            with self.subTest(mode=mode):
                parts = self.numbered(name=mode)
                if mode == 'missing':
                    parts[1].unlink()
                elif mode == 'swapped':
                    first, second = parts[1].read_bytes(), parts[2].read_bytes()
                    parts[1].write_bytes(second)
                    parts[2].write_bytes(first)
                else:
                    data = bytearray(parts[1].read_bytes())
                    data[100] ^= 0xff
                    parts[1].write_bytes(data)
                self.assert_failed_output(parts[0], name=mode + '-output')
        parts = self.numbered(name='first')
        result = execute('list', parts[1])
        self.assertFalse(result['ok'])
        self.assertTrue(result['volumeError'])
        self.assertIn('第一个分卷', result['error'])

    def test_split_zip_is_readonly_at_ui_contract_and_native_mutation_boundary(self):
        archive, parts = self.zip_parts()
        snapshot = {path: path.read_bytes() for path in [archive, *parts]}
        for entry in [archive, parts[0]]:
            listing = execute('list', entry)
            self.assertTrue(listing['ok'], listing)
            self.assertFalse(listing['editable'])
            self.assertEqual(listing['volumes'], len(parts) + 1)
            output = self.root / entry.suffix[1:]
            self.assertTrue(execute('extract', entry, output, indices=[0])['ok'])
            self.assertEqual((output / 'payload.bin').read_bytes(), self.source.read_bytes())
            result = mutate(entry, 'rename', listing['version'], item='payload.bin', destination='renamed.bin')
            self.assertFalse(result['ok'])
            self.assertIn('分卷', result['error'])
        self.assertEqual({path: path.read_bytes() for path in snapshot}, snapshot)

    def test_split_zip_missing_and_corrupt_parts_leave_no_result(self):
        archive, parts = self.zip_parts()
        original = parts[1].read_bytes()
        parts[1].unlink()
        self.assert_failed_output(archive, 'missing-zip')
        data = bytearray(original)
        data[100] ^= 0xff
        parts[1].write_bytes(data)
        self.assert_failed_output(archive, 'corrupt-zip')

    def test_rar_multivolume_known_content_missing_and_corrupt_parts(self):
        parts = self.rar_parts()
        self.assertEqual(len(parts), 3)
        listing = execute('list', parts[0])
        self.assertTrue(listing['ok'], listing)
        self.assertEqual(listing['volumes'], 3)
        self.assertFalse(listing['editable'])
        self.assertTrue(execute('test', parts[0])['ok'])
        target = self.root / 'rar-output'
        self.assertTrue(execute('extract', parts[0], target)['ok'])
        content = (target / 'LibarchiveAddingTest.html').read_bytes()
        self.assertEqual(len(content), 20111)
        self.assertEqual(zlib.crc32(content), 0x5e05a663)
        original = parts[1].read_bytes()
        parts[1].unlink()
        missing = execute('list', parts[0])
        self.assertFalse(missing['ok'])
        self.assertTrue(missing['volumeError'])
        self.assertIn(parts[1].name, missing['error'])
        data = bytearray(original)
        data[500] ^= 0xff
        parts[1].write_bytes(data)
        self.assert_failed_output(parts[0], 'corrupt-rar')

    def test_rar5_solid_multivolume_known_checksums_and_selected_file(self):
        parts = []
        for source in sorted((ROOT / 'test/fixtures/libarchive').glob('test_read_format_rar5_multiarchive_solid.part*.rar.uu')):
            target = self.root / source.stem
            target.write_bytes(b''.join(binascii.a2b_uu(line) for line in source.read_bytes().splitlines()[1:] if line != b'end'))
            parts.append(target)
        self.assertEqual(len(parts), 4)
        checksums = {
            'cebula.txt': 0x7e5ec49e, 'test.bin': 0x7cca70cd, 'test1.bin': 0x7e13b2c6,
            'test2.bin': 0xf166afcb, 'test3.bin': 0x9fb123d9, 'test4.bin': 0x10c43ed4,
            'test5.bin': 0xb9d155f2, 'test6.bin': 0x36a448ff, 'elf-Linux-ARMv7-ls': 0x886f91eb,
        }
        listing = execute('list', parts[0])
        self.assertTrue(listing['ok'], listing)
        self.assertEqual(listing['volumes'], 4)
        self.assertEqual({item['path'] for item in listing['items']}, set(checksums))
        self.assertTrue(execute('test', parts[0])['ok'])
        target = self.root / 'rar5'
        self.assertTrue(execute('extract', parts[0], target)['ok'])
        for name, checksum in checksums.items():
            self.assertEqual(zlib.crc32((target / name).read_bytes()), checksum)
        selected = next(item for item in listing['items'] if item['path'] == 'test4.bin')
        selected_target = self.root / 'selected-rar5'
        self.assertTrue(execute('extract', parts[0], selected_target, indices=[selected['index']])['ok'])
        self.assertEqual([path.name for path in selected_target.iterdir()], ['test4.bin'])
        self.assertEqual(zlib.crc32((selected_target / 'test4.bin').read_bytes()), checksums['test4.bin'])
        parts[-1].unlink()
        self.assert_failed_output(parts[0], 'missing-rar5')

    def test_numbered_zip_preserves_automatic_legacy_encoding_detection(self):
        class LegacyInfo(zipfile.ZipInfo):
            def _encodeFilenameFlags(self):
                return self.filename.encode('cp932'), self.flag_bits & ~0x800
        archive = self.root / 'legacy.zip'
        name = '日本語フォルダ/資料ファイルこんにちは.txt'
        with zipfile.ZipFile(archive, 'w') as writer:
            writer.writestr(LegacyInfo(name), b'legacy text')
            writer.write(self.source, self.source.name)
        data = archive.read_bytes()
        for index, offset in enumerate(range(0, len(data), 50000), 1):
            (self.root / f'legacy.zip.{index:03}').write_bytes(data[offset:offset + 50000])
        first = self.root / 'legacy.zip.001'
        listing = execute('list', first)
        self.assertTrue(listing['ok'], listing)
        self.assertEqual(listing['codePage'], 932)
        self.assertIn(name, {item['path'] for item in listing['items']})
        output = self.root / 'legacy-extracted'
        self.assertTrue(execute('extract', first, output)['ok'])
        self.assertEqual((output / name).read_bytes(), b'legacy text')

    def test_multivolume_cancellation_does_not_publish_output(self):
        parts = self.numbered()
        job = LIB.f7_job_create()
        try:
            LIB.f7_job_cancel(job)
            result = execute('extract', parts[0], self.root / 'cancelled', job=job)
            self.assertFalse(result['ok'])
            self.assertTrue(result['cancelled'])
            self.assertFalse((self.root / 'cancelled').exists())
        finally:
            LIB.f7_job_destroy(job)
