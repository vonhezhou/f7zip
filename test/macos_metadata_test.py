"""macOS 权限与归档链接的保真和边界验证。"""
import io
import os
from pathlib import Path
import stat
import subprocess
import tarfile
import tempfile
import unittest
import zipfile

from native_engine_test import execute, mutate, update


class MacOSMetadataTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='f7zip-metadata-')
        self.root = Path(self.temp.name)
        self.archive = self.root / 'bundle.tar'

    def tearDown(self):
        # 用例会验证权限为 000 的目录，清理前恢复访问权限。
        for current, directories, files in os.walk(self.root):
            os.chmod(current, 0o700)
            for name in directories:
                path = Path(current) / name
                if not path.is_symlink(): path.chmod(0o700)
        self.temp.cleanup()

    def set_attribute(self, path, name, value):
        subprocess.run(['/usr/bin/xattr', '-wx', name, value.hex(), str(path)], check=True)

    def attribute(self, path, name):
        result = subprocess.check_output(['/usr/bin/xattr', '-px', name, str(path)], text=True)
        return bytes.fromhex(result)

    def metadata_source(self):
        source = self.root / 'source'
        source.mkdir()
        file = source / 'data'
        file.write_bytes(b'payload')
        file.chmod(0o751)
        self.set_attribute(source, 'com.f7zip.folder', b'folder attributes')
        self.set_attribute(file, 'com.f7zip.binary', b'\x00\x01custom\xff')
        self.set_attribute(file, 'com.apple.ResourceFork', b'resource fork payload')
        return source

    def assert_metadata(self, folder, filename='data'):
        self.assertEqual(self.attribute(folder, 'com.f7zip.folder'), b'folder attributes')
        self.assertEqual(self.attribute(folder / filename, 'com.f7zip.binary'), b'\x00\x01custom\xff')
        self.assertEqual(self.attribute(folder / filename, 'com.apple.ResourceFork'), b'resource fork payload')
        self.assertEqual(stat.S_IMODE((folder / filename).stat().st_mode), 0o751)

    def test_extended_attributes_and_resource_forks_round_trip_all_container_formats(self):
        source = self.metadata_source()
        for format in ['zip', '7z', 'tar', 'tar.gz', 'tar.bz2', 'tar.xz', 'zip-aes256']:
            with self.subTest(format=format):
                archive = self.root / ('metadata.' + format)
                password = 'secret' if format == 'zip-aes256' else ''
                result = execute('compress', archive, format=format, inputs=[source], password=password)
                self.assertTrue(result['ok'], result)
                output = self.root / ('restored-' + format)
                result = execute('extract', archive, output, password=password)
                self.assertTrue(result['ok'], result)
                self.assert_metadata(output / 'source')
                self.assertFalse((output / '__MACOSX').exists())
                self.assertEqual(list(output.rglob('._*')), [])
                if format == 'zip':
                    independent = self.root / 'ditto-unpacked'
                    subprocess.run(['/usr/bin/ditto', '-x', '-k', str(archive), str(independent)], check=True)
                    self.assert_metadata(independent / 'source')
                if format == 'tar':
                    independent = self.root / 'tar-unpacked'
                    independent.mkdir()
                    subprocess.run(['/usr/bin/tar', '-xf', str(archive), '-C', str(independent)], check=True)
                    self.assert_metadata(independent / 'source')

    def test_ditto_metadata_selected_file_and_flat_volume_extraction(self):
        source = self.metadata_source()
        archive = self.root / 'ditto.zip'
        subprocess.run(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(source), str(archive)], check=True)
        listing = execute('list', archive)
        index = next(item['index'] for item in listing['items'] if item['path'] == 'source/data')
        output = self.root / 'selected-metadata'
        result = execute('extract', archive, output, indices=[index])
        self.assertTrue(result['ok'], result)
        self.assertEqual(self.attribute(output / 'source/data', 'com.apple.ResourceFork'), b'resource fork payload')
        self.assertEqual(self.attribute(output / 'source/data', 'com.f7zip.binary'), b'\x00\x01custom\xff')
        volume = self.root / 'metadata.7z'
        result = execute('compress', volume, format='7z', inputs=[source], password='secret', volume_size=500)
        self.assertTrue(result['ok'], result)
        self.assertFalse((self.root / 'mac-metadata').exists())
        self.assertFalse((self.root / 'directory-entries').exists())
        output = self.root / 'flat-metadata'
        result = execute('extractFlat', result['path'], output, password='secret')
        self.assertTrue(result['ok'], result)
        self.assert_metadata(output)

    def test_metadata_survives_rename_content_update_add_and_remove(self):
        source = self.metadata_source()
        archive = self.root / 'editable.zip'
        self.assertTrue(execute('compress', archive, inputs=[source])['ok'])
        version = execute('list', archive)['version']
        result = mutate(archive, 'rename', version, item='source/data', destination='source/renamed')
        self.assertTrue(result['ok'], result)
        edited = self.root / 'edited'
        edited.write_bytes(b'updated')
        result = update(archive, 'source/renamed', edited, result['version'])
        self.assertTrue(result['ok'], result)
        output = self.root / 'edited-output'
        self.assertTrue(execute('extract', archive, output)['ok'])
        # 内容回写沿用原元数据与权限，调用方的编辑文件保持原状。
        self.assertEqual(self.attribute(output / 'source/renamed', 'com.apple.ResourceFork'), b'resource fork payload')
        self.assertEqual(self.attribute(output / 'source/renamed', 'com.f7zip.binary'), b'\x00\x01custom\xff')
        self.assertEqual(stat.S_IMODE((output / 'source/renamed').stat().st_mode), 0o751)
        self.assertEqual(stat.S_IMODE(edited.stat().st_mode), 0o644)
        incoming = self.root / 'incoming'
        incoming.write_bytes(b'new')
        self.set_attribute(incoming, 'com.f7zip.new', b'new attribute')
        result = mutate(archive, 'add', result['version'], item='source', inputs=[incoming])
        self.assertTrue(result['ok'], result)
        output = self.root / 'added-output'
        self.assertTrue(execute('extract', archive, output)['ok'])
        self.assertEqual(self.attribute(output / 'source/incoming', 'com.f7zip.new'), b'new attribute')
        result = mutate(archive, 'rename', result['version'], item='source', destination='moved')
        self.assertTrue(result['ok'], result)
        output = self.root / 'moved-output'
        self.assertTrue(execute('extract', archive, output)['ok'])
        self.assertEqual(self.attribute(output / 'moved', 'com.f7zip.folder'), b'folder attributes')
        self.assertEqual(self.attribute(output / 'moved/renamed', 'com.apple.ResourceFork'), b'resource fork payload')
        result = mutate(archive, 'remove', result['version'], inputs=['moved'])
        self.assertTrue(result['ok'], result)
        self.assertFalse(any('._' in item['path'] for item in result['items']))

    def test_add_replace_removes_stale_metadata_and_ordinary_sidecar_names_are_preserved(self):
        source = self.metadata_source()
        archive = self.root / 'replace.zip'
        self.assertTrue(execute('compress', archive, inputs=[source])['ok'])
        replacement_folder = self.root / 'replacement'
        replacement_folder.mkdir()
        replacement = replacement_folder / 'data'
        replacement.write_bytes(b'plain replacement')
        version = execute('list', archive)['version']
        result = mutate(archive, 'addReplace', version, item='source', inputs=[replacement])
        self.assertTrue(result['ok'], result)
        output = self.root / 'replaced-output'
        self.assertTrue(execute('extract', archive, output)['ok'])
        names = subprocess.check_output(['/usr/bin/xattr', str(output / 'source/data')], text=True)
        self.assertNotIn('com.apple.ResourceFork', names)
        self.assertNotIn('com.f7zip.binary', names)
        self.archive = self.root / 'ordinary.zip'
        with zipfile.ZipFile(self.archive, 'w') as writer:
            writer.writestr('data', b'ordinary')
            writer.writestr('._data', b'ordinary sidecar name')
        output = self.root / 'ordinary-output'
        self.assertTrue(execute('extract', self.archive, output)['ok'])
        self.assertEqual((output / '._data').read_bytes(), b'ordinary sidecar name')
        result = mutate(self.archive, 'rename', execute('list', self.archive)['version'], item='data', destination='renamed')
        self.assertTrue(result['ok'], result)
        self.assertIn('._data', [item['path'] for item in result['items']])

    def test_metadata_failure_preserves_destination_and_source(self):
        archive = self.root / 'corrupt-metadata.zip'
        with zipfile.ZipFile(archive, 'w') as writer:
            writer.writestr('data', b'new')
            writer.writestr('__MACOSX/._data', b'\x00\x05\x16\x07corrupt')
        original = archive.read_bytes()
        output = self.root / 'preserved'
        output.mkdir()
        (output / 'data').write_bytes(b'old')
        result = execute('extractHere', archive, output, extraction_policy=4)
        self.assertFalse(result['ok'], result)
        self.assertEqual((output / 'data').read_bytes(), b'old')
        self.assertEqual(archive.read_bytes(), original)
        self.assertEqual(list(output.glob('.f7zip-*')), [])

    def test_metadata_and_links_together_and_readonly_mutation_boundary(self):
        source = self.metadata_source()
        (source / 'alias').symlink_to('data')
        archive = self.root / 'combined.7z'
        self.assertTrue(execute('compress', archive, format='7z', inputs=[source])['ok'])
        listing = execute('list', archive)
        self.assertFalse(listing['editable'])
        output = self.root / 'combined-output'
        self.assertTrue(execute('extract', archive, output)['ok'])
        self.assert_metadata(output / 'source')
        self.assertTrue((output / 'source/alias').is_symlink())
        result = update(archive, 'source/data', source / 'data', listing['version'])
        self.assertFalse(result['ok'], result)
        self.assertIn('只读', result['error'])

    def test_device_and_fifo_entries_are_rejected_before_publication(self):
        for type in [tarfile.FIFOTYPE, tarfile.CHRTYPE, tarfile.BLKTYPE]:
            with self.subTest(type=type):
                with tarfile.open(self.archive, 'w') as writer:
                    item = tarfile.TarInfo('special')
                    item.type = type
                    writer.addfile(item)
                output = self.root / 'special-output'
                result = execute('extract', self.archive, output)
                self.assertFalse(result['ok'], result)
                self.assertFalse(output.exists())
                self.assertEqual(list(self.root.glob('.f7zip-*')), [])

    def make_tar(self, links=(), files=None, directories=()):
        with tarfile.open(self.archive, 'w') as writer:
            for name, mode in directories:
                item = tarfile.TarInfo(name)
                item.type = tarfile.DIRTYPE
                item.mode = mode
                writer.addfile(item)
            for name, content in (files or {'folder/data': b'payload'}).items():
                item = tarfile.TarInfo(name)
                item.mode = 0o751
                item.size = len(content)
                writer.addfile(item, io.BytesIO(content))
            for name, target, hard in links:
                item = tarfile.TarInfo(name)
                item.type = tarfile.LNKTYPE if hard else tarfile.SYMTYPE
                item.linkname = target
                writer.addfile(item)

    def test_tar_permissions_and_directory_permissions_are_restored(self):
        self.make_tar(directories=[('folder', 0o711), ('empty', 0o000)])
        output = self.root / 'output'
        result = execute('extract', self.archive, output)
        self.assertTrue(result['ok'], result)
        self.assertEqual(stat.S_IMODE((output / 'folder/data').stat().st_mode), 0o751)
        self.assertEqual(stat.S_IMODE((output / 'folder').stat().st_mode), 0o711)
        self.assertEqual(stat.S_IMODE((output / 'empty').stat().st_mode), 0o000)

    def test_merge_preserves_existing_directory_permissions(self):
        self.make_tar(directories=[('folder', 0o000)])
        output = self.root / 'output'
        (output / 'folder').mkdir(parents=True, mode=0o750)
        before = stat.S_IMODE((output / 'folder').stat().st_mode)
        result = execute('extractHere', self.archive, output, extraction_policy=3)
        self.assertTrue(result['ok'], result)
        self.assertEqual(stat.S_IMODE((output / 'folder').stat().st_mode), before)
        self.assertEqual((output / 'folder/data').read_bytes(), b'payload')

    def test_safe_relative_symbolic_links_and_chains(self):
        self.make_tar(links=[('folder/link', 'data', False), ('alias', 'folder/link', False), ('folder/self', '.', False)])
        output = self.root / 'output'
        result = execute('extract', self.archive, output)
        self.assertTrue(result['ok'], result)
        self.assertTrue((output / 'folder/link').is_symlink())
        self.assertEqual(os.readlink(output / 'folder/link'), 'data')
        self.assertEqual((output / 'alias').read_bytes(), b'payload')
        self.assertTrue((output / 'folder/self').is_dir())

    def test_hard_links_chains_and_selection_include_data_dependency(self):
        self.make_tar(links=[('hard', 'folder/data', True), ('chain', 'hard', True)])
        output = self.root / 'all'
        result = execute('extract', self.archive, output)
        self.assertTrue(result['ok'], result)
        self.assertEqual((output / 'hard').stat().st_ino, (output / 'folder/data').stat().st_ino)
        self.assertEqual((output / 'chain').stat().st_ino, (output / 'hard').stat().st_ino)
        listing = execute('list', self.archive)['items']
        index = next(item['index'] for item in listing if item['path'] == 'chain')
        output = self.root / 'selected'
        result = execute('extract', self.archive, output, indices=[index])
        self.assertTrue(result['ok'], result)
        self.assertEqual((output / 'chain').read_bytes(), b'payload')
        self.assertEqual((output / 'chain').stat().st_ino, (output / 'folder/data').stat().st_ino)
        self.assertFalse((output / 'hard').exists())

    def test_unsafe_links_cycles_and_link_ancestors_are_rejected(self):
        cases = [
            [('link', '/tmp/outside', False)],
            [('link', '../outside', False)],
            [('a', '.', False), ('b', 'a/../outside', False)],
            [('a', 'b', False), ('b', 'a', False)],
            [('a', 'b', True), ('b', 'a', True)],
            [('a', '../outside', True)],
            [('folder', '.', False)],
            [('hard', 'missing', True)],
            [('link', 'missing', False)],
        ]
        for links in cases:
            with self.subTest(links=links):
                self.make_tar(links=links)
                output = self.root / 'rejected'
                result = execute('extract', self.archive, output)
                self.assertFalse(result['ok'], result)
                self.assertFalse(output.exists())
                self.assertEqual(list(self.root.glob('.f7zip-*')), [])

    def test_overwrite_existing_hardlink_group_keeps_new_hardlinks_and_external_old_alias(self):
        self.make_tar(links=[('alias', 'data', True)], files={'data': b'new'})
        output = self.root / 'output'
        output.mkdir()
        (output / 'data').write_bytes(b'old')
        os.link(output / 'data', output / 'alias')
        os.link(output / 'data', self.root / 'external-old')
        result = execute('extractHere', self.archive, output, extraction_policy=4)
        self.assertTrue(result['ok'], result)
        self.assertEqual((output / 'data').read_bytes(), b'new')
        self.assertEqual((output / 'alias').stat().st_ino, (output / 'data').stat().st_ino)
        self.assertEqual((self.root / 'external-old').read_bytes(), b'old')

    def test_zip_links_are_decoded_as_data_before_creation(self):
        self.archive = self.root / 'links.zip'
        with zipfile.ZipFile(self.archive, 'w') as writer:
            writer.writestr('data', b'payload')
            item = zipfile.ZipInfo('alias')
            item.create_system = 3
            item.external_attr = 0o120777 << 16
            writer.writestr(item, b'data')
        result = execute('extract', self.archive, self.root / 'output')
        self.assertTrue(result['ok'], result)
        self.assertEqual((self.root / 'output/alias').read_bytes(), b'payload')
        self.assertFalse(execute('list', self.archive)['editable'])

    def test_creation_preserves_symbolic_links_without_copying_target_data(self):
        source = self.root / 'source'
        source.mkdir()
        (source / 'data').write_bytes(b'payload')
        (source / 'alias').symlink_to('data')
        for format in ['zip', '7z', 'tar', 'tar.gz']:
            with self.subTest(format=format):
                archive = self.root / ('created.' + format)
                result = execute('compress', archive, format=format, inputs=[source])
                self.assertTrue(result['ok'], result)
                output = self.root / ('output-' + format)
                result = execute('extract', archive, output)
                self.assertTrue(result['ok'], result)
                self.assertTrue((output / 'source/alias').is_symlink())
                self.assertEqual(os.readlink(output / 'source/alias'), 'data')

    def test_rename_updates_link_targets_and_merge_rejects_external_existing_links(self):
        self.make_tar(links=[('alias', 'data', False)], files={'data': b'new'})
        output = self.root / 'output'
        output.mkdir()
        (output / 'data').write_bytes(b'old')
        result = execute('extractHere', self.archive, output, extraction_policy=2)
        self.assertTrue(result['ok'], result)
        self.assertEqual((output / 'data').read_bytes(), b'old')
        self.assertEqual((output / 'alias').read_bytes(), b'new')
        self.assertEqual(os.readlink(output / 'alias'), 'data (2)')
        outside = self.root / 'outside'
        outside.write_bytes(b'untouched')
        (output / 'data').unlink()
        (output / 'data').symlink_to(outside)
        (output / 'alias').unlink()
        result = execute('extractHere', self.archive, output, extraction_policy=1)
        self.assertFalse(result['ok'], result)
        self.assertFalse((output / 'alias').exists())
        self.assertEqual(outside.read_bytes(), b'untouched')

    def test_redundant_root_is_preserved_when_removal_changes_link_boundary(self):
        self.make_tar(links=[('wrapper/alias', '../wrapper/data', False)], files={'wrapper/data': b'payload'})
        output = self.root / 'output'
        result = execute('extractFlat', self.archive, output)
        self.assertTrue(result['ok'], result)
        self.assertEqual((output / 'wrapper/alias').read_bytes(), b'payload')
        self.make_tar(links=[('wrapper/alias', 'data', False)], files={'wrapper/data': b'payload'})
        output = self.root / 'flat'
        result = execute('extractFlat', self.archive, output)
        self.assertTrue(result['ok'], result)
        self.assertEqual((output / 'alias').read_bytes(), b'payload')

    def test_setuid_and_setgid_bits_are_not_restored(self):
        self.archive = self.root / 'mode.zip'
        with zipfile.ZipFile(self.archive, 'w') as writer:
            item = zipfile.ZipInfo('executable')
            item.create_system = 3
            item.external_attr = 0o106751 << 16
            writer.writestr(item, b'payload')
        output = self.root / 'output'
        self.assertTrue(execute('extract', self.archive, output)['ok'])
        self.assertEqual(stat.S_IMODE((output / 'executable').stat().st_mode), 0o751)
