"""通过可执行入口验证脚本契约、真实引擎、失败和信号取消。"""
import json
import os
from pathlib import Path
import signal
import plistlib
import shutil
import subprocess
import tempfile
import time
import unittest
import zipfile

from native_engine_test import ROOT

CLI = ROOT / 'native/lib/f7zip'


class CommandLineTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='f7zip-cli-')
        self.root = Path(self.temp.name)
        self.source = self.root / '中文\n😀.txt'
        self.source.write_text('CLI payload\n')

    def tearDown(self):
        self.temp.cleanup()

    def run_cli(self, *arguments, status=0, password=None, executable=CLI):
        result = subprocess.run([str(executable), *map(str, arguments)], cwd=self.root,
                                input=password, text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, status, result.stdout + result.stderr)
        try:
            response = json.loads(result.stdout)
        except json.JSONDecodeError:
            self.fail(result.stdout + result.stderr)
        self.assertEqual(response['ok'], status == 0, response)
        return response, result

    def test_create_test_extract_infers_compound_format_and_preserves_names(self):
        for format in ('zip', 'zipx', 'wim', '7z', 'tar.gz', 'tar.bz2', 'tar.xz', 'gz', 'xz', 'bz2'):
            with self.subTest(format=format):
                archive = self.root / ('created.' + format)
                response, result = self.run_cli('compress', '--quiet', archive, '--', self.source)
                self.assertEqual(Path(response['path']), archive)
                self.assertEqual(result.stderr, '')
                self.run_cli('test', '--quiet', archive)
                destination = self.root / ('output-' + format)
                response, _ = self.run_cli('extract', '--quiet', archive, destination)
                files = [path for path in Path(response['path']).rglob('*') if path.is_file()]
                self.assertEqual(len(files), 1)
                self.assertEqual(files[0].read_text(), 'CLI payload\n')
                if format not in ('gz', 'xz', 'bz2'):
                    self.assertEqual(files[0].name, self.source.name)

    def test_compression_parameters_volumes_and_independent_zip_reading(self):
        self.source.write_text('compressible CLI payload\n' * 10000)
        archive = self.root / 'advanced.zip'
        self.run_cli('compress', '--quiet', '--method', 'BZip2', '--threads', '2', archive, self.source)
        with zipfile.ZipFile(archive) as reader:
            self.assertEqual(reader.getinfo(self.source.name).compress_type, 12)
            self.assertEqual(reader.read(self.source.name), self.source.read_bytes())
        archive = self.root / 'split.7z'
        response, _ = self.run_cli('compress', '--quiet', '--volume-mib', '1', '--method', 'LZMA2',
                                 '--dictionary-mib', '1', '--threads', '1', '--solid-mib', '16', archive, self.source)
        self.assertEqual(Path(response['path']), Path(str(archive) + '.001'))
        self.run_cli('test', '--quiet', response['path'])

    def test_password_stdin_errors_and_no_password_output(self):
        archive = self.root / 'secret.7z'
        self.run_cli('compress', '--quiet', '--password-stdin', archive, self.source, password='private-value\n')
        self.run_cli('test', '--quiet', archive, status=3)
        response, result = self.run_cli('test', '--quiet', '--password-stdin', archive,
                                        password='wrong-value\n', status=3)
        self.assertTrue(response['passwordRequired'])
        self.assertNotIn('wrong-value', result.stdout + result.stderr)
        self.run_cli('test', '--quiet', '--password-stdin', archive, password='private-value\n')
        self.run_cli('extract', '--quiet', '--password-stdin', archive, self.root / 'password-output', password='private-value\n')
        self.run_cli('test', '--quiet', '--password-stdin', archive, password='x' * 4098, status=2)

    def test_existing_archive_missing_source_corruption_and_conflicts_preserve_data(self):
        archive = self.root / 'sample.zip'
        self.run_cli('compress', '--quiet', archive, self.source)
        before = archive.read_bytes()
        self.run_cli('compress', '--quiet', archive, self.source, status=1)
        self.assertEqual(archive.read_bytes(), before)
        output = self.root / 'output'
        output.mkdir()
        (output / self.source.name).write_text('existing')
        self.run_cli('extract', '--quiet', archive, output, status=1)
        self.assertEqual((output / self.source.name).read_text(), 'existing')
        self.run_cli('compress', '--quiet', self.root / 'missing.zip', self.root / 'missing', status=1)
        self.assertFalse((self.root / 'missing.zip').exists())
        bad = self.root / 'bad.zip'
        bad.write_bytes(b'corrupted archive')
        self.run_cli('test', '--quiet', bad, status=1)
        self.run_cli('extract', '--quiet', bad, self.root / 'bad-output', status=1)
        self.assertFalse((self.root / 'bad-output').exists())
        self.assertFalse(list(self.root.glob('.f7zip-*')))

    def test_argument_errors_help_and_leading_option_filename(self):
        for arguments in [(), ('unknown',), ('compress',), ('extract', self.source),
                          ('test', '--threads', '2', self.source), ('test', '--unknown', self.source),
                          ('compress', '--level', '2', 'out.zip', self.source),
                          ('compress', '--threads', '-1', 'out.zip', self.source),
                          ('compress', '--level', 'five', 'out.zip', self.source),
                          ('compress', '--format', '--quiet', 'out.zip', self.source),
                          ('compress', '--quiet', '--quiet', 'out.zip', self.source),
                          ('compress', '--visible-names', 'out.zip', self.source),
                          ('test', '--normalization', 'nfc', self.source)]:
            with self.subTest(arguments=arguments):
                self.run_cli(*arguments, status=2)
        help_result = subprocess.run([str(CLI), '--help'], text=True, capture_output=True)
        self.assertEqual(help_result.returncode, 0)
        self.assertIn('password-stdin', help_result.stdout)
        special = self.root / '--quiet'
        special.write_text('leading option name')
        archive = self.root / 'option-name.zip'
        self.run_cli('compress', '--quiet', archive, '--', special.name)
        with zipfile.ZipFile(archive) as reader:
            self.assertEqual(reader.read(special.name), b'leading option name')

    def test_progress_protocol_normalization_and_redundant_root(self):
        folder = self.root / 'folder'
        folder.mkdir()
        nfd = 'cafe\u0301.txt'
        (folder / nfd).write_text('normalized')
        archive = self.root / 'normalization.zip'
        _, result = self.run_cli('compress', '--normalization', 'nfc', archive, folder)
        for line in result.stderr.splitlines():
            progress = json.loads(line)
            self.assertIn('completed', progress)
        response, _ = self.run_cli('extract', '--quiet', '--remove-root', '--normalization', 'nfc', archive, self.root / 'normalized')
        self.assertEqual((Path(response['path']) / 'café.txt').read_text(), 'normalized')
        self.assertFalse((Path(response['path']) / 'folder').exists())

    def test_cancel_running_cli_cleans_partial_archive_and_retry_succeeds(self):
        data = self.root / 'large.bin'
        data.write_bytes(os.urandom(32 * 1024 * 1024))
        archive = self.root / 'cancel.7z'
        for cancel_signal in (signal.SIGINT, signal.SIGTERM):
            process = subprocess.Popen([str(CLI), 'compress', '--method', 'LZMA2', '--dictionary-mib', '1',
                                        '--threads', '1', str(archive), str(data)],
                                       cwd=self.root, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    line = process.stderr.readline()
                    self.assertTrue(line, '压缩任务在可取消进度之前结束')
                    if json.loads(line)['completed'] > 0: break
                self.assertIsNone(process.poll())
                process.send_signal(cancel_signal)
                stdout, stderr = process.communicate(timeout=20)
                self.assertEqual(process.returncode, 128 + cancel_signal, stdout + stderr)
                self.assertTrue(json.loads(stdout)['cancelled'])
                self.assertFalse(archive.exists())
                self.assertFalse(list(self.root.glob('.f7zip-*')))
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()
        self.run_cli('compress', '--quiet', archive, self.source)
        self.run_cli('test', '--quiet', archive)

    def test_symlink_entrypoint_resolves_bundled_engine(self):
        alias = self.root / 'f7zip'
        alias.symlink_to(CLI)
        archive = self.root / 'alias.zip'
        self.run_cli('compress', '--quiet', archive, self.source, executable=alias)
        self.run_cli('test', '--quiet', archive, executable=alias)

    def test_packaged_entrypoint_and_real_macos_open_document_handoff(self):
        app = self.root / 'F7Zip.app'
        macos = app / 'Contents/MacOS'
        frameworks = app / 'Contents/Frameworks/F7Zip'
        macos.mkdir(parents=True)
        frameworks.mkdir(parents=True)
        shutil.copy2(CLI, macos / 'f7zip-cli')
        for name in ('libf7zip.dylib', '7z.so'):
            shutil.copy2(ROOT / 'native/lib' / name, frameworks / name)
        resources = app / 'Contents/Resources/F7Zip'
        resources.mkdir(parents=True)
        shutil.copy2(ROOT / 'native/sfx/7z-x86.sfx', resources / '7z-x86.sfx')
        record = self.root / 'open-record.json'
        info = {'CFBundleExecutable': 'F7Zip', 'CFBundlePackageType': 'APPL',
                'CFBundleIdentifier': 'com.f7zip.cli-test.' + self.root.name,
                'CFBundleName': 'F7Zip CLI Test', 'LSUIElement': True, 'F7TestRecord': str(record)}
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        source = self.root / 'OpenReceiver.m'
        source.write_text(r'''#import <Cocoa/Cocoa.h>
#include <unistd.h>
@interface Receiver : NSObject <NSApplicationDelegate>
@end
@implementation Receiver
- (void)application:(NSApplication *)application openFiles:(NSArray<NSString *> *)filenames {
    NSString *path = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"F7TestRecord"];
    NSData *data = [NSJSONSerialization dataWithJSONObject:filenames options:0 error:NULL];
    [data writeToFile:path atomically:YES];
    [application replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
    [application terminate:nil];
}
@end
int main(void) {
    @autoreleasepool {
        alarm(12);
        NSApplication *app = [NSApplication sharedApplication];
        Receiver *receiver = [Receiver new];
        app.delegate = receiver;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
''')
        subprocess.run(['clang', '-mmacosx-version-min=12.0', '-framework', 'Cocoa', str(source),
                        '-o', str(macos / 'F7Zip')], check=True, capture_output=True)
        subprocess.run(['codesign', '--force', '--deep', '--sign', '-', '--timestamp=none', str(app)],
                       check=True, capture_output=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)],
                       check=True, capture_output=True)
        portable = self.root / 'portable.txt'
        portable.write_bytes(b'packaged SFX payload')
        sfx = self.root / 'packaged.exe'
        self.run_cli('compress', '--quiet', sfx, portable, executable=macos / 'f7zip-cli')
        self.run_cli('test', '--quiet', sfx, executable=macos / 'f7zip-cli')
        output = self.root / 'sfx-output'
        self.run_cli('extract', '--quiet', sfx, output, executable=macos / 'f7zip-cli')
        self.assertEqual((output / portable.name).read_bytes(), portable.read_bytes())
        archive = self.root / 'packaged.zip'
        self.run_cli('compress', '--quiet', archive, self.source, executable=macos / 'f7zip-cli')
        self.run_cli('test', '--quiet', archive, executable=macos / 'f7zip-cli')
        second = self.root / 'second space.zip'
        shutil.copy2(archive, second)
        response, _ = self.run_cli('open', archive, second, executable=macos / 'f7zip-cli')
        self.assertTrue(response['accepted'])
        deadline = time.monotonic() + 10
        while not record.exists() and time.monotonic() < deadline:
            time.sleep(.02)
        self.assertTrue(record.exists(), 'macOS 未将文件交给独立测试应用')
        self.assertEqual({Path(path).resolve() for path in json.loads(record.read_text())},
                         {archive.resolve(), second.resolve()})
