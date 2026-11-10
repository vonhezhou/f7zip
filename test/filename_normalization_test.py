"""Unicode 创建/解压边界、规范重名、元数据与链接保真。"""
import io
import os
from pathlib import Path
import stat
import subprocess
import tarfile
import tempfile
import threading
import time
import unicodedata
import unittest
import zipfile

from native_engine_test import execute, LIB

NFC = 'café-각'
NFD = unicodedata.normalize('NFD', NFC)


class FilenameNormalizationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='f7zip-unicode-')
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def assert_clean(self):
        self.assertEqual(list(self.root.glob('.f7zip-*')), [])

    def test_creation_forms_and_preserve_across_archive_formats(self):
        source = self.root / NFD
        source.mkdir()
        (source / (NFD + '.txt')).write_text('payload')
        (source / ('empty-' + NFD)).mkdir()
        for mode, form in [(0, 'NFD'), (1, 'NFC'), (2, 'NFD')]:
            for format in ['zip', '7z', 'tar', 'tar.gz', 'tar.xz', 'tar.bz2']:
                with self.subTest(mode=mode, format=format):
                    archive = self.root / f'created-{mode}.{format}'
                    result = execute('compress', archive, inputs=[source], format=format, filename_normalization=mode)
                    self.assertTrue(result['ok'], result)
                    listing = execute('list', archive)
                    expected = unicodedata.normalize(form, NFD + '/' + NFD + '.txt')
                    self.assertIn(expected, [item['path'] for item in listing['items']])
                    if format == 'zip':
                        with zipfile.ZipFile(archive) as reader:
                            self.assertEqual(reader.read(expected), b'payload')
                    if format.startswith('tar'):
                        with tarfile.open(archive) as reader:
                            self.assertEqual(reader.extractfile(expected).read(), b'payload')
        self.assertCountEqual(os.listdir(source), [NFD + '.txt', 'empty-' + NFD])
        self.assert_clean()

    def test_single_file_stream_formats_round_trip(self):
        import gzip
        import bz2
        import lzma
        source = self.root / (NFD + '.txt')
        source.write_bytes(b'payload')
        for format, decode in [('gz', gzip.decompress), ('bz2', bz2.decompress), ('xz', lzma.decompress)]:
            archive = self.root / ('stream.' + format)
            result = execute('compress', archive, inputs=[source], format=format, filename_normalization=1)
            self.assertTrue(result['ok'], result)
            self.assertEqual(decode(archive.read_bytes()), b'payload')
            if format == 'gz':
                listing = execute('list', archive)
                self.assertEqual(listing['items'][0]['path'], NFC + '.txt')
        self.assert_clean()

    def test_creation_normalizes_symbolic_link_targets_without_editing_sources(self):
        source = self.root / NFD
        source.mkdir()
        (source / NFD).write_bytes(b'payload')
        (source / ('alias-' + NFD)).symlink_to(NFD)
        for format in ['zip', '7z', 'tar']:
            archive = self.root / ('links.' + format)
            result = execute('compress', archive, inputs=[source], format=format, filename_normalization=1)
            self.assertTrue(result['ok'], result)
            target = self.root / ('links-' + format)
            result = execute('extract', archive, target)
            self.assertTrue(result['ok'], result)
            self.assertEqual(os.readlink(target / NFC / ('alias-' + NFC)), NFC)
            self.assertEqual((target / NFC / ('alias-' + NFC)).read_bytes(), b'payload')
        self.assertEqual(os.readlink(source / ('alias-' + NFD)), NFD)
        self.assert_clean()

    def test_invalid_mode_fails_before_publishing(self):
        source = self.root / 'source'
        source.write_bytes(b'payload')
        archive = self.root / 'invalid.zip'
        result = execute('compress', archive, inputs=[source], filename_normalization=3)
        self.assertFalse(result['ok'], result)
        self.assertIn('Unicode', result['error'])
        self.assertFalse(archive.exists())
        self.assert_clean()

    def test_extraction_normalizes_components_and_preserves_default_spelling(self):
        for spelling in [NFC, NFD]:
            archive = self.root / ('nfc.zip' if spelling == NFC else 'nfd.zip')
            with zipfile.ZipFile(archive, 'w') as writer:
                writer.writestr(spelling + '/' + spelling + '.txt', b'payload')
                writer.writestr(spelling + '/empty-' + spelling + '/', b'')
            for mode, form in [(0, None), (1, 'NFC'), (2, 'NFD')]:
                target = self.root / (archive.stem + str(mode))
                result = execute('extract', archive, target, filename_normalization=mode)
                self.assertTrue(result['ok'], result)
                expected = unicodedata.normalize(form, spelling) if form else spelling
                self.assertEqual(os.listdir(target), [expected])
                self.assertEqual((target / expected / (expected + '.txt')).read_bytes(), b'payload')
                self.assertTrue((target / expected / ('empty-' + expected)).is_dir())
                if form:
                    for path in target.rglob('*'):
                        relative = str(path.relative_to(target))
                        self.assertEqual(relative, unicodedata.normalize(form, relative))
        self.assert_clean()

    def test_creation_rejects_normalized_root_collisions_without_changing_sources(self):
        sources = []
        for index, name in enumerate([NFC, NFD]):
            parent = self.root / str(index)
            parent.mkdir()
            source = parent / name
            source.write_text(str(index))
            sources.append(source)
        for mode in [1, 2]:
            archive = self.root / f'collision-{mode}.zip'
            result = execute('compress', archive, inputs=sources, filename_normalization=mode)
            self.assertFalse(result['ok'], result)
            self.assertIn('重名', result['error'])
            self.assertFalse(archive.exists())
        preserved = self.root / 'preserved.zip'
        self.assertTrue(execute('compress', preserved, inputs=sources)['ok'])
        with zipfile.ZipFile(preserved) as reader:
            self.assertEqual(set(reader.namelist()), {NFC, NFD})
        self.assertEqual([path.read_text() for path in sources], ['0', '1'])
        self.assert_clean()

    def test_equivalent_file_and_implicit_parent_names_are_rejected_before_writing(self):
        cases = [
            {NFC: b'one', NFD: b'two'},
            {NFC + '/a': b'one', NFD + '/b': b'two'},
            {NFC: b'one', NFD + '/child': b'two'},
            {NFC + '/': b'', NFD + '/child': b'two'},
        ]
        for index, entries in enumerate(cases):
            archive = self.root / f'case-{index}.zip'
            with zipfile.ZipFile(archive, 'w') as writer:
                for name, value in entries.items(): writer.writestr(name, value)
            for mode in [0, 1, 2]:
                with self.subTest(index=index, mode=mode):
                    target = self.root / f'output-{index}-{mode}'
                    result = execute('extract', archive, target, filename_normalization=mode, indices=[0])
                    self.assertFalse(result['ok'], result)
                    self.assertIn('重名', result['error'])
                    self.assertFalse(target.exists())
                    self.assert_clean()

    def test_existing_equivalent_name_uses_regular_conflict_policy(self):
        archive = self.root / 'source.zip'
        with zipfile.ZipFile(archive, 'w') as writer: writer.writestr(NFD, b'incoming')
        target = self.root / 'target'
        target.mkdir()
        (target / NFD).write_bytes(b'keep')
        result = execute('extractHere', archive, target, filename_normalization=1)
        self.assertFalse(result['ok'], result)
        self.assertEqual(result['conflicts'], [NFC])
        result = execute('extractHere', archive, target, filename_normalization=1, extraction_policy=2)
        self.assertTrue(result['ok'], result)
        self.assertEqual((target / NFD).read_bytes(), b'keep')
        self.assertEqual((target / (NFC + ' (2)')).read_bytes(), b'incoming')
        self.assertIn(NFC + ' (2)', os.listdir(target))
        self.assert_clean()

    def test_links_permissions_times_and_export_scope_survive_normalization(self):
        archive = self.root / 'links.tar'
        with tarfile.open(archive, 'w') as writer:
            directory = tarfile.TarInfo(NFD)
            directory.type = tarfile.DIRTYPE
            directory.mode = 0o500
            directory.mtime = 1234567890
            writer.addfile(directory)
            item = tarfile.TarInfo(NFD + '/' + NFD)
            item.mode = 0o751
            item.size = 7
            writer.addfile(item, io.BytesIO(b'payload'))
            for name, kind, target in [('alias-' + NFD, tarfile.SYMTYPE, '../' + NFD + '/' + NFD), ('hard-' + NFD, tarfile.LNKTYPE, NFC + '/' + NFC)]:
                item = tarfile.TarInfo(NFD + '/' + name)
                item.type = kind
                item.linkname = target
                writer.addfile(item)
        target = self.root / 'links'
        result = execute('extract', archive, target, filename_normalization=1)
        self.assertTrue(result['ok'], result)
        directory = target / NFC
        self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o500)
        self.assertEqual(int(directory.stat().st_mtime), 1234567890)
        self.assertEqual(stat.S_IMODE((directory / NFC).stat().st_mode), 0o751)
        self.assertEqual(os.readlink(directory / ('alias-' + NFC)), '../' + NFC + '/' + NFC)
        self.assertEqual((directory / ('alias-' + NFC)).read_bytes(), b'payload')
        self.assertEqual((directory / ('hard-' + NFC)).stat().st_ino, (directory / NFC).stat().st_ino)
        listing = execute('list', archive)
        result = execute('export', archive, self.root / 'exported', filename_normalization=1, export_path=NFD, export_version=listing['version'], indices=[item['index'] for item in listing['items']])
        self.assertTrue(result['ok'], result)
        self.assertEqual((self.root / 'exported' / ('alias-' + NFC)).read_bytes(), b'payload')
        self.assertEqual(os.readlink(self.root / 'exported' / ('alias-' + NFC)), NFC)
        self.assertEqual(int((self.root / 'exported').stat().st_mtime), 1234567890)
        directory.chmod(0o700)
        (self.root / 'exported').chmod(0o700)
        self.assert_clean()

    def test_metadata_matches_equivalent_sidecar_names_with_selected_extraction(self):
        source = self.root / NFC
        source.write_bytes(b'payload')
        subprocess.run(['/usr/bin/xattr', '-w', 'com.apple.ResourceFork', 'resource data', str(source)], check=True)
        original = self.root / 'original.zip'
        self.assertTrue(execute('compress', original, inputs=[source])['ok'])
        archive = self.root / 'mixed.zip'
        with zipfile.ZipFile(original) as reader, zipfile.ZipFile(archive, 'w') as writer:
            for info in reader.infolist():
                name = unicodedata.normalize('NFD', info.filename) if info.filename.startswith('__MACOSX/') else info.filename
                info.filename = name
                writer.writestr(info, reader.read(info.orig_filename))
        listing = execute('list', archive)
        index = next(item['index'] for item in listing['items'] if item['path'] == NFC)
        target = self.root / 'metadata'
        result = execute('extract', archive, target, filename_normalization=2, indices=[index])
        self.assertTrue(result['ok'], result)
        self.assertEqual(os.listdir(target), [NFD])
        fork = subprocess.check_output(['/usr/bin/xattr', '-p', 'com.apple.ResourceFork', str(target / NFD)], text=True)
        self.assertEqual(fork.strip(), 'resource data')
        self.assert_clean()

    def test_cancellation_during_rename_cleans_all_staging(self):
        archive = self.root / 'many.zip'
        with zipfile.ZipFile(archive, 'w') as writer:
            for index in range(1600): writer.writestr(f'{NFD}-{index}', b'payload')
        job = LIB.f7_job_create()
        result = []
        target = self.root / 'cancelled'
        worker = threading.Thread(target=lambda: result.append(execute('extract', archive, target, job=job, filename_normalization=1)))
        try:
            worker.start()
            renamed = False
            deadline = time.monotonic() + 10
            while worker.is_alive() and time.monotonic() < deadline:
                for staging in self.root.glob('.f7zip-*'):
                    try:
                        with os.scandir(staging) as entries:
                            renamed = any(entry.name.startswith(NFC + '-') for entry in entries)
                    except FileNotFoundError:
                        continue
                    if renamed: break
                if renamed:
                    LIB.f7_job_cancel(job)
                    break
                time.sleep(0.001)
            worker.join(10)
            self.assertFalse(worker.is_alive())
            self.assertTrue(renamed, 'did not observe the rename phase')
            self.assertTrue(result[0].get('cancelled'), result)
            self.assertFalse(target.exists())
            self.assert_clean()
        finally:
            if worker.is_alive():
                LIB.f7_job_cancel(job)
                worker.join()
            LIB.f7_job_destroy(job)
