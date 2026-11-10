#!/usr/bin/env python3
"""为应用生成包含原始依赖的对应源码包。"""
from pathlib import Path
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / 'dist'
DIST.mkdir(exist_ok=True)
bit7z_archive = ROOT / 'native/vendor/bit7z-source.tar.gz'
if (ROOT / 'native/vendor/bit7z/.git').exists():
    with bit7z_archive.open('wb') as output:
        subprocess.run(['git', '-C', str(ROOT / 'native/vendor/bit7z'), 'archive',
                        '--format=tar.gz', '--prefix=bit7z/', 'HEAD'], stdout=output, check=True)
else:
    import shutil
    shutil.copy2(ROOT / 'third_party/bit7z-source.tar.gz', bit7z_archive)
excluded = {'.git', '.dart_tool', '.idea', '.vscode', 'build', 'dist', 'ephemeral',
            '__pycache__', '.DS_Store', '.flutter-plugins-dependencies'}
with tarfile.open(DIST / 'F7Zip-sources.tar.gz', 'w:gz') as archive:
    for path in sorted(ROOT.rglob('*')):
        relative = path.relative_to(ROOT)
        if not path.is_file() or any(part in excluded for part in relative.parts):
            continue
        if relative.parts[:2] in [('native', 'lib'), ('native', 'vendor')]:
            continue
        archive.add(path, arcname=str(Path('f7zip') / relative), recursive=False)
    for source in ['7zip.tar.xz', 'bit7z-source.tar.gz']:
        archive.add(ROOT / 'native/vendor' / source,
                    arcname='f7zip/third_party/' + source, recursive=False)
print(DIST / 'F7Zip-sources.tar.gz')
