"""在独立临时钥匙串中运行生产密码存储实现。"""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class KeychainStoreTest(unittest.TestCase):
    def test_isolated_keychain_contract(self):
        with tempfile.TemporaryDirectory(prefix='f7zip-keychain-test-') as directory:
            root = Path(directory)
            binary = root / 'keychain-test'
            keychain = root / 'isolated.keychain-db'
            subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(root / 'cache'),
                            str(ROOT / 'macos/Runner/ArchivePasswordStore.swift'),
                            str(ROOT / 'test/keychain_store_main.swift'), '-o', str(binary)],
                           check=True, capture_output=True, text=True, timeout=90)
            try:
                try:
                    result = subprocess.run([str(binary), str(keychain)], capture_output=True, text=True, timeout=30)
                except subprocess.TimeoutExpired as error:
                    self.fail(f'Keychain operation timed out: {error.output!r} {error.stderr!r}')
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('passed', result.stdout)
            finally:
                if keychain.exists():
                    subprocess.run(['/usr/bin/security', 'delete-keychain', str(keychain)],
                                   capture_output=True, check=False)
