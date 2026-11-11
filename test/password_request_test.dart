import 'package:f7zip/archive_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('密码重试完整保留导出预算与源版本等请求约束', () {
    const original = ArchiveRequest(
      'export',
      '/archive.zip',
      destination: '/destination',
      removeRedundantRoot: true,
      autoUnpackTar: false,
      itemPath: 'folder/file',
      expectedVersion: 'source-version',
      password: 'wrong',
      codePage: 936,
      volumeSize: 1048576,
      extractionPolicy: ExtractionPolicy.overwrite,
      expectedDestinationVersion: 'destination-version',
      format: '7z',
      level: 9,
      outputLimit: 4096,
      inputs: ['/input'],
      indices: [3, 5],
    );
    final retried = original.withPassword('correct');
    expect(retried.password, 'correct');
    expect(original.password, 'wrong');
    expect(retried.operation, original.operation);
    expect(retried.archive, original.archive);
    expect(retried.destination, original.destination);
    expect(retried.removeRedundantRoot, original.removeRedundantRoot);
    expect(retried.autoUnpackTar, isFalse);
    expect(retried.itemPath, original.itemPath);
    expect(retried.expectedVersion, original.expectedVersion);
    expect(retried.codePage, original.codePage);
    expect(retried.volumeSize, original.volumeSize);
    expect(retried.extractionPolicy, original.extractionPolicy);
    expect(
      retried.expectedDestinationVersion,
      original.expectedDestinationVersion,
    );
    expect(retried.format, original.format);
    expect(retried.level, original.level);
    expect(retried.outputLimit, original.outputLimit);
    expect(retried.inputs, original.inputs);
    expect(retried.indices, original.indices);
  });
}
