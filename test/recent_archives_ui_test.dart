import 'dart:async';

import 'package:f7zip/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('sevenzip/desktop');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  for (final entry in ['sidebar', 'toolbar', 'native', 'failure']) {
    testWidgets('最近打开清空入口 $entry', (tester) async {
      tester.view.physicalSize = const Size(1120, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var saved = ['/tmp/first.zip', '/tmp/second.7z'];
      var clearCalls = 0;
      Map<Object?, Object?> commands = {};
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'recentArchives':
            return saved;
          case 'clearRecentArchives':
            clearCalls++;
            if (entry == 'failure') {
              throw PlatformException(code: 'storage', message: '清空失败');
            }
            saved = [];
            return null;
          case 'updateCommands':
            commands = call.arguments as Map;
            return null;
          default:
            return null;
        }
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(const F7ZipApp());
      await tester.pumpAndSettle();
      expect(find.text('first.zip'), findsOneWidget);
      expect(find.text('second.7z'), findsOneWidget);
      expect(commands['clearRecent'], isTrue);

      if (entry == 'toolbar') {
        await tester.tap(find.byTooltip('最近打开'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('清空最近打开'));
      } else if (entry == 'native') {
        unawaited(_command('clearRecent'));
      } else {
        await tester.tap(find.byTooltip('清空最近打开'));
      }
      await tester.pumpAndSettle();
      expect(clearCalls, 1);
      if (entry == 'failure') {
        expect(find.textContaining('清空失败'), findsOneWidget);
        await tester.tap(find.text('知道了'));
        await tester.pumpAndSettle();
        expect(find.text('first.zip'), findsOneWidget);
        expect(find.text('second.7z'), findsOneWidget);
        expect(commands['clearRecent'], isTrue);
      } else {
        expect(find.text('first.zip'), findsNothing);
        expect(find.text('second.7z'), findsNothing);
        expect(find.text('打开的压缩包会显示在这里'), findsOneWidget);
        expect(find.text('已清空最近打开记录'), findsOneWidget);
        expect(commands['clearRecent'], isFalse);
        expect(
          tester
              .widget<PopupMenuButton<String>>(
                find.byWidgetPredicate(
                  (widget) =>
                      widget is PopupMenuButton<String> &&
                      widget.tooltip == '最近打开',
                ),
              )
              .enabled,
          isFalse,
        );
        unawaited(_command('clearRecent'));
        await tester.pumpAndSettle();
        expect(clearCalls, 1);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(const F7ZipApp());
        await tester.pumpAndSettle();
        expect(find.text('打开的压缩包会显示在这里'), findsOneWidget);
        expect(commands['clearRecent'], isFalse);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });
  }
}

Future<dynamic> _command(String command) {
  final completer = Completer<dynamic>();
  const codec = StandardMethodCodec();
  unawaited(
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'sevenzip/desktop',
          codec.encodeMethodCall(MethodCall('archiveCommand', command)),
          (data) => completer.complete(codec.decodeEnvelope(data!)),
        ),
  );
  return completer.future;
}
