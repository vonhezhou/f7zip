import 'dart:io';

import 'package:f7zip/archive_engine.dart';
import 'package:f7zip/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  const channel = MethodChannel('sevenzip/desktop');

  for (final action in ['compressZip', 'extractHere', 'extractTo']) {
    for (final removeRoot in [false, true]) {
      testWidgets('Finder $action 快捷操作、密码重试和结果保护 removeRoot=$removeRoot', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(1120, 760);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final root = Directory.systemTemp.createTempSync('f7zip-finder-');
        addTearDown(() => root.deleteSync(recursive: true));
        final source = File(p.join(root.path, 'source.txt'))
          ..writeAsStringSync('finder content');
        final output = Directory(p.join(root.path, 'destination'))
          ..createSync();
        final wrapped = Directory(p.join(root.path, 'wrapper'))..createSync();
        final wrappedSource = source.copySync(
          p.join(wrapped.path, 'source.txt'),
        );
        final archive = p.join(root.path, 'encrypted.7z');
        final engine = ArchiveEngine();
        if (action != 'compressZip') {
          await tester.runAsync(
            () => engine.run(
              ArchiveRequest(
                'compress',
                archive,
                inputs: [removeRoot ? wrapped.path : source.path],
                format: '7z',
                password: 'secret',
              ),
            ),
          );
          source.deleteSync();
          wrappedSource.deleteSync();
          wrapped.deleteSync();
        } else {
          File('${source.path}.zip').writeAsStringSync('existing');
        }
        final calls = <MethodCall>[];
        var passwords = 0;
        var finished = false;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              switch (call.method) {
                case 'loadSettings':
                  return {'removeRedundantRoot': removeRoot};
                case 'takeFinderRequests':
                  return [
                    {
                      'action': action,
                      'paths': [
                        action == 'compressZip' ? source.path : archive,
                      ],
                    },
                    {
                      // 第二个请求确认队列在快捷任务完成后仍能继续处理。
                      'action': 'extractTo',
                      'paths': <String>[],
                    },
                  ];
                case 'finderPassword':
                  return ++passwords == 1 ? 'wrong' : 'secret';
                case 'finderChooseFolder':
                  if (action != 'extractTo' ||
                      calls
                              .where(
                                (item) => item.method == 'finderChooseFolder',
                              )
                              .length >
                          1) {
                    finished = true;
                    return null;
                  }
                  return output.path;
              }
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );
        await tester.pumpWidget(const F7ZipApp());
        for (var attempt = 0; attempt < 200 && !finished; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(finished, isTrue);
        expect(
          calls.where(
            (call) => const [
              'chooseInputs',
              'saveArchive',
              'chooseFolder',
              'rememberArchive',
              'finderError',
            ].contains(call.method),
          ),
          isEmpty,
        );
        expect(find.byType(AlertDialog), findsNothing);
        if (action == 'compressZip') {
          expect(File('${source.path}.zip').readAsStringSync(), 'existing');
          final zip = '${source.path} (2).zip';
          final listing = await tester.runAsync(
            () => engine.run(ArchiveRequest('list', zip)),
          );
          expect((listing!['items'] as List).single['path'], 'source.txt');
        } else {
          expect(passwords, 2);
          final target = action == 'extractTo' ? output.path : root.path;
          expect(
            File(p.join(target, 'source.txt')).readAsStringSync(),
            'finder content',
          );
          expect(Directory(p.join(target, 'encrypted')).existsSync(), isFalse);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
