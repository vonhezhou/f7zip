import 'package:f7zip/archive_preview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('预览分类支持大小写、无扩展名文本与安全输出名称', () {
    for (final path in ['a/README', '.env', '日志.TXT', 'src/file.dart']) {
      expect(ArchivePreviewKind.forPath(path), ArchivePreviewKind.text);
      expect(ArchivePreviewKind.text.outputName(path), 'content.txt');
    }
    expect(ArchivePreviewKind.forPath('照片.PNG'), ArchivePreviewKind.image);
    expect(ArchivePreviewKind.forPath('a.PDF'), ArchivePreviewKind.pdf);
    expect(ArchivePreviewKind.forPath('a.M4A'), ArchivePreviewKind.audio);
    expect(ArchivePreviewKind.forPath('a.MOV'), ArchivePreviewKind.video);
    for (final path in ['a.zip', 'a.html', 'a.svg', 'executable']) {
      expect(ArchivePreviewKind.forPath(path), isNull);
    }
    expect(ArchivePreviewKind.image.outputName('../照片.PNG'), 'content.png');
    expect(ArchivePreviewKind.text.outputLimit, 4 * 1024 * 1024);
    expect(ArchivePreviewKind.image.outputLimit, 256 * 1024 * 1024);
  });
}
