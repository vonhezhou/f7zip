"""ZIP 注释修改与保留、旧 RAR 注释解码和只读边界。"""
import binascii
import os
from pathlib import Path
import struct
import tempfile
import unittest
import zipfile
import zlib

from native_engine_test import ROOT, LIB, execute, mutate, update


def rar_block(kind, flags, data, size=None):
    body = struct.pack('<BHH', kind, flags, size or (7 + len(data))) + data
    return struct.pack('<H', zlib.crc32(body) & 0xffff) + body


def rar_comment(data, packed=None, version=20, method=0x30):
    packed = data if packed is None else packed
    body = struct.pack('<HHBBH', 13 + len(packed), len(data), version, method, zlib.crc32(data) & 0xffff)
    # 旧注释块固定头为 13 字节，数据的 CRC 单独保存。
    return rar_block(0x75, 0, body[2:] + packed)


def rar_with_comment(comment, archive_comment=b''):
    data = b'carrier data'
    name = b'carrier.txt'
    file_fields = struct.pack('<IIBIIBBHI', len(data), len(data), 3,
                              zlib.crc32(data), 0, 20, 0x30, len(name), 0o100644)
    main = rar_block(0x73, 2 if archive_comment else 0, b'\x00' * 6,
                     size=13 + len(archive_comment)) + archive_comment
    file = rar_block(0x74, 0x8008 if comment else 0x8000, file_fields + name,
                     size=32 + len(name) + len(comment)) + comment + data
    return b'Rar!\x1a\x07\x00' + main + file + rar_block(0x7b, 0, b'')


def rar_service_comment(data, packed=None, version=29, method=0x30, utf16=False):
    packed = data if packed is None else packed
    fields = struct.pack('<IIBIIBBHI', len(packed), len(data), 3, zlib.crc32(data), 0,
                         version, method, 3, 0)
    return rar_block(0x7a, 0x8000, fields + b'CMT' + struct.pack('<I', int(utf16))) + packed


class ArchiveCommentsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='f7zip-comments-')
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def zip(self):
        archive = self.root / 'sample.zip'
        with zipfile.ZipFile(archive, 'w') as writer:
            writer.comment = b'archive comment'
            for name, text in [('one.txt', 'first'), ('two.txt', 'second')]:
                item = zipfile.ZipInfo(name)
                item.comment = (text + ' comment').encode()
                writer.writestr(item, text.encode())
        return archive

    def test_zip_read_edit_unicode_clear_and_preserve_data_and_backup(self):
        archive = self.zip()
        listed = execute('list', archive)
        self.assertTrue(listed['commentEditable'])
        self.assertEqual([item['comment'] for item in listed['items']], ['first comment', 'second comment'])
        before = archive.read_bytes()
        response = mutate(archive, 'fileComment', listed['version'], item='one.txt', destination='中文注释 😀\nline')
        self.assertTrue(response['ok'], response)
        self.assertEqual(Path(response['backup']).read_bytes(), before)
        with zipfile.ZipFile(archive) as reader:
            self.assertEqual(reader.read('one.txt'), b'first')
            self.assertEqual(reader.getinfo('one.txt').comment.decode(), '中文注释 😀\nline')
            self.assertEqual(reader.getinfo('two.txt').comment, b'second comment')
            self.assertEqual(reader.comment, b'archive comment')
            self.assertTrue(reader.getinfo('one.txt').flag_bits & 0x800)
        for comment in ['归档 😀\n注释', '', 'x' * 16384]:
            version = execute('list', archive)['version']
            response = mutate(archive, 'archiveComment', version, destination=comment)
            self.assertTrue(response['ok'], response)
            self.assertEqual(execute('list', archive)['comment'], comment)
            with zipfile.ZipFile(archive) as reader:
                self.assertEqual(reader.comment, comment.encode())
                self.assertEqual(reader.read('one.txt'), b'first')
        response = mutate(archive, 'fileComment', response['version'], item='one.txt', destination='')
        self.assertTrue(response['ok'], response)
        self.assertEqual(response['items'][0]['comment'], '')

    def test_content_replacement_rename_add_and_time_update_preserve_comments(self):
        archive = self.zip()
        edited = self.root / 'one.txt'
        edited.write_text('updated content')
        response = update(archive, 'one.txt', edited, execute('list', archive)['version'])
        self.assertTrue(response['ok'], response)
        self.assertEqual(response['items'][0]['comment'], 'first comment')
        response = mutate(archive, 'rename', response['version'], item='one.txt', destination='中文.txt')
        self.assertTrue(response['ok'], response)
        self.assertEqual(response['items'][0]['comment'], 'first comment')
        replacement = self.root / '中文.txt'
        replacement.write_text('replacement')
        response = mutate(archive, 'addReplace', response['version'], inputs=[replacement])
        self.assertTrue(response['ok'], response)
        self.assertEqual(response['items'][0]['comment'], 'first comment')
        os.utime(replacement, (1900000000, 1900000000))
        response = mutate(archive, 'updateExisting', response['version'], inputs=[replacement])
        self.assertTrue(response['ok'], response)
        with zipfile.ZipFile(archive) as reader:
            self.assertEqual(reader.getinfo('中文.txt').comment, b'first comment')
            self.assertEqual(reader.getinfo('two.txt').comment, b'second comment')
            self.assertEqual(reader.comment, b'archive comment')

    def test_encrypted_comment_changes_preserve_encryption_and_data(self):
        data = self.root / 'data.txt'
        data.write_text('encrypted data')
        for format in ('zip', 'zip-aes256'):
            archive = self.root / (format + '.zip')
            self.assertTrue(execute('compress', archive, format=format, inputs=[data], password='secret')['ok'])
            version = execute('list', archive, password='secret')['version']
            response = mutate(archive, 'fileComment', version, item=data.name, destination='加密文件注释', password='secret')
            self.assertTrue(response['ok'], response)
            self.assertEqual(response['items'][0]['comment'], '加密文件注释')
            self.assertTrue(response['items'][0]['encrypted'])
            self.assertTrue(execute('test', archive, password='secret')['ok'])
            self.assertFalse(execute('test', archive, password='wrong')['ok'])

    def test_invalid_comment_stale_version_cancel_and_readonly_preserve_original(self):
        archive = self.zip()
        before = archive.read_bytes()
        version = execute('list', archive)['version']
        for mode, item, text, expected in [('fileComment', 'one.txt', 'x' * 16385, version),
                                           ('archiveComment', '', 'x' * 16385, version),
                                           ('fileComment', 'missing', 'text', version),
                                           ('archiveComment', '', 'text', 'stale')]:
            response = mutate(archive, mode, expected, item=item, destination=text)
            self.assertFalse(response['ok'], response)
            self.assertEqual(archive.read_bytes(), before)
        job = LIB.f7_job_create()
        try:
            LIB.f7_job_cancel(job)
            response = mutate(archive, 'fileComment', version, item='one.txt', destination='text', job=job)
            self.assertTrue(response['cancelled'], response)
            self.assertEqual(archive.read_bytes(), before)
        finally:
            LIB.f7_job_destroy(job)
        source = self.root / 'source'
        source.write_text('data')
        seven = self.root / 'sample.7z'
        execute('compress', seven, format='7z', inputs=[source])
        listed = execute('list', seven)
        self.assertFalse(listed['commentEditable'])
        before = seven.read_bytes()
        response = mutate(seven, 'archiveComment', listed['version'], destination='text')
        self.assertFalse(response['ok'], response)
        self.assertEqual(seven.read_bytes(), before)
        self.assertFalse(list(self.root.glob('.f7zip-*')))

    def test_old_rar_stored_file_and_archive_comments_crc_and_utf8_cp437(self):
        for text, encoding in [('中文注释', 'utf8'), ('café comment', 'cp437')]:
            archive = self.root / 'comment.rar'
            comment = rar_comment(text.encode(encoding))
            archive.write_bytes(rar_with_comment(comment, rar_comment(b'archive comment')))
            listed = execute('list', archive)
            self.assertTrue(listed['ok'], listed)
            self.assertFalse(listed['commentEditable'])
            self.assertEqual(listed['comment'], 'archive comment')
            self.assertEqual(listed['items'][0]['comment'], text)
            self.assertTrue(execute('test', archive)['ok'])
        corrupted = bytearray(comment)
        corrupted[-1] ^= 1
        archive.write_bytes(rar_with_comment(corrupted))
        listed = execute('list', archive)
        self.assertTrue(listed['ok'], listed)
        self.assertTrue(listed['items'][0]['commented'])
        self.assertEqual(listed['items'][0]['comment'], '')

    def test_old_rar_compressed_comments_reuse_real_decoder_and_validate_crc(self):
        fixture = ROOT / 'test/fixtures/libarchive/test_read_format_rar_compress_normal.rar.uu'
        lines = fixture.read_bytes().splitlines()
        payload = b''.join(binascii.a2b_uu(line) for line in lines[1:-2])
        original = self.root / 'original.rar'
        original.write_bytes(payload)
        listed = execute('list', original)
        self.assertTrue(listed['ok'], listed)
        first = next(item for item in listed['items'] if not item['directory'])
        output = self.root / 'original-data'
        self.assertTrue(execute('extract', original, output, indices=[first['index']])['ok'])
        expected = (output / first['path']).read_bytes()
        position = 7
        while position + 32 < len(payload):
            kind = payload[position + 2]
            flags, size = struct.unpack_from('<HH', payload, position + 3)
            packed = struct.unpack_from('<I', payload, position + 7)[0] if flags & 0x8000 else 0
            if kind == 0x74 and packed:
                version, method = payload[position + 24:position + 26]
                compressed = payload[position + size:position + size + packed]
                break
            position += size + packed
        self.assertLessEqual(len(expected), 65535)
        comment = rar_comment(expected, compressed, version, method)
        archive = self.root / 'compressed-comment.rar'
        archive.write_bytes(rar_with_comment(comment, comment))
        listed = execute('list', archive)
        self.assertTrue(listed['ok'], listed)
        text = expected.decode('utf8')
        self.assertEqual(listed['items'][0]['comment'], text)
        self.assertEqual(listed['comment'], text)
        base = rar_with_comment(b'')
        service = rar_service_comment(expected, compressed, version, method)
        archive.write_bytes(base[:20] + service + base[20:])
        listed = execute('list', archive)
        self.assertTrue(listed['ok'], listed)
        self.assertEqual(listed['comment'], text)

    def test_legacy_zip_comment_preserved_as_unicode_after_content_update(self):
        archive = self.root / 'legacy.zip'
        with zipfile.ZipFile(archive, 'w') as writer:
            item = zipfile.ZipInfo('aaaa.txt')
            item.comment = '中文注释'.encode('gb18030')
            writer.writestr(item, b'original')
        archive.write_bytes(archive.read_bytes().replace(b'aaaa.txt', '中文.txt'.encode('gb18030')))
        listed = execute('list', archive, code_page=54936)
        self.assertTrue(listed['ok'], listed)
        self.assertEqual(listed['items'][0]['comment'], '中文注释')
        edited = self.root / 'edited'
        edited.write_text('updated')
        response = update(archive, '中文.txt', edited, listed['version'], code_page=54936)
        self.assertTrue(response['ok'], response)
        self.assertEqual(response['items'][0]['comment'], '中文注释')
        with zipfile.ZipFile(archive) as reader:
            self.assertEqual(reader.getinfo('中文.txt').comment.decode(), '中文注释')
            self.assertEqual(reader.read('中文.txt'), b'updated')

    def test_rar_service_archive_comment_utf8_utf16_and_resource_bound(self):
        archive = self.root / 'service-comment.rar'
        base = rar_with_comment(b'')
        for text, encoding in [('modern UTF-8 注释', 'utf8'), ('UTF-16 注释 🗂', 'utf-16le')]:
            service = rar_service_comment(text.encode(encoding), utf16=encoding == 'utf-16le')
            archive.write_bytes(base[:20] + service + base[20:])
            listed = execute('list', archive)
            self.assertTrue(listed['ok'], listed)
            self.assertEqual(listed['comment'], text)
            self.assertEqual([item['path'] for item in listed['items']], ['carrier.txt'])
            self.assertTrue(execute('test', archive)['ok'])
        service = rar_service_comment(b'x' * (262144 + 1))
        archive.write_bytes(base[:20] + service + base[20:])
        listed = execute('list', archive)
        self.assertTrue(listed['ok'], listed)
        self.assertEqual(listed['comment'], '')
        self.assertTrue(execute('test', archive)['ok'])

    def test_non_bmp_filenames_round_trip_and_comment_edit(self):
        source = self.root / '目录🗂'
        source.mkdir()
        file = source / '报告😀.txt'
        file.write_text('non-BMP content')
        for format in ('zip', '7z', 'tar'):
            archive = self.root / ('unicode.' + format)
            response = execute('compress', archive, format=format, inputs=[source])
            self.assertTrue(response['ok'], response)
            listed = execute('list', archive)
            self.assertTrue(listed['ok'], listed)
            path = '目录🗂/报告😀.txt'
            self.assertIn(path, [item['path'] for item in listed['items']])
            if format == 'zip':
                response = mutate(archive, 'fileComment', listed['version'], item=path, destination='注释😀')
                self.assertTrue(response['ok'], response)
                item = next(item for item in response['items'] if item['path'] == path)
                self.assertEqual(item['comment'], '注释😀')
                with zipfile.ZipFile(archive) as reader:
                    self.assertEqual(reader.read(path), b'non-BMP content')
            output = self.root / format
            self.assertTrue(execute('extract', archive, output)['ok'])
            self.assertEqual((output / path).read_text(), 'non-BMP content')
