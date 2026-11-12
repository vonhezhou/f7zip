import 'package:f7zip/archive_password_history.dart';
import 'package:f7zip/compression_dialog.dart';
import 'package:f7zip/password_generator_dialog.dart';
import 'package:f7zip/password_history_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('随机密码满足长度、字符类别和易混淆字符排除设置', () {
    for (var index = 0; index < 100; index++) {
      final password = generateArchivePassword();
      expect(password.length, 20);
      expect(password, matches(RegExp('[A-Z]')));
      expect(password, matches(RegExp('[a-z]')));
      expect(password, matches(RegExp('[2-9]')));
      expect(password, matches(RegExp(r'[^a-zA-Z0-9]')));
      expect(password, isNot(matches(RegExp('[IloO01]'))));
    }
    expect(
      generateArchivePassword(
        length: 128,
        uppercase: false,
        lowercase: false,
        symbols: false,
      ),
      matches(RegExp(r'^[2-9]{128}$')),
    );
    expect(
      () => generateArchivePassword(
        uppercase: false,
        lowercase: false,
        digits: false,
        symbols: false,
      ),
      throwsArgumentError,
    );
    expect(() => generateArchivePassword(length: 2), throwsArgumentError);
  });

  test('历史持久化保留同路径多次记录，并发新增删除互不覆盖', () async {
    await ArchivePasswordHistory.remember('/tmp/archive.zip', 'first');
    final first = (await ArchivePasswordHistory.load()).single;
    await Future.wait([
      ArchivePasswordHistory.remember('/tmp/archive.zip', 'second'),
      ArchivePasswordHistory.remember('/tmp/other.7z.001', 'third'),
      ArchivePasswordHistory.delete(first.id),
    ]);
    await ArchivePasswordHistory.remember('/tmp/plain.zip', '');
    final records = await ArchivePasswordHistory.load();
    expect(records.map((record) => record.password), ['third', 'second']);
    expect(records.map((record) => record.id).toSet().length, 2);
    expect(records.first.path, '/tmp/other.7z.001');
    expect(
      records.first.createdAt.isAfter(
        DateTime.now().subtract(const Duration(minutes: 1)),
      ),
      isTrue,
    );
    for (final record in records) {
      await ArchivePasswordHistory.delete(record.id);
    }
    expect(await ArchivePasswordHistory.load(), isEmpty);
  });

  test('历史读取失败保留原数据，存储恢复后继续接受写入', () async {
    FlutterSecureStorage.setMockInitialValues({
      'createdArchivePasswordHistory': 'invalid-json',
    });
    await expectLater(
      ArchivePasswordHistory.remember('/tmp/archive.zip', 'secret'),
      throwsFormatException,
    );
    expect(
      await const FlutterSecureStorage().read(
        key: 'createdArchivePasswordHistory',
      ),
      'invalid-json',
    );
    FlutterSecureStorage.setMockInitialValues({});
    await ArchivePasswordHistory.remember('/tmp/archive.zip', 'retried');
    expect((await ArchivePasswordHistory.load()).single.password, 'retried');
  });

  testWidgets('创建窗口生成密码并采用，默认隐藏，预设隐藏生成器', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<CompressionOptions>(
              context: context,
              builder: (_) => CompressionDialog(
                inputs: const ['/tmp/source'],
                presets: const [],
                defaultPreset: '',
                onPresetsChanged: (_, _) async {},
              ),
            ),
            child: const Text('新建'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('新建'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('zipCreationEncoding')), findsNothing);
    expect(find.text('密码历史'), findsNothing);
    expect(find.text('压缩包密码历史'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('compressionPassword')),
        matching: find.byTooltip('生成随机密码'),
      ),
      findsOneWidget,
    );
    await tester.ensureVisible(find.byTooltip('生成随机密码'));
    await tester.tap(find.byTooltip('生成随机密码'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('压缩包密码历史'));
    await tester.tap(find.text('压缩包密码历史'));
    await tester.pumpAndSettle();
    expect(find.text('暂无密码历史'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    final generated = tester
        .widget<SelectableText>(find.byKey(const ValueKey('generatedPassword')))
        .textSpan!
        .toPlainText();
    await tester.tap(find.text('使用此密码'));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('compressionPassword')),
    );
    expect(field.controller!.text, generated);
    expect(field.obscureText, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      const MaterialApp(home: CompressionDialog.preset(presets: [])),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('生成随机密码'), findsNothing);
  });

  testWidgets('生成器阻止关闭最后一类字符，支持重新生成', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: PasswordGeneratorDialog()));
    for (final index in [0, 1, 3]) {
      await tester.tap(find.byKey(ValueKey('passwordType:$index')));
      await tester.pump();
    }
    final digits = tester.widget<CheckboxListTile>(
      find.byKey(const ValueKey('passwordType:2')),
    );
    expect(digits.onChanged, isNull);
    expect(
      tester
          .widget<SelectableText>(
            find.byKey(const ValueKey('generatedPassword')),
          )
          .textSpan!
          .toPlainText(),
      matches(RegExp(r'^[2-9]{20}$')),
    );
    await tester.tap(find.byTooltip('重新生成'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('密码长度输入与滑块同步，非法长度阻止采用，窄窗口可操作长密码', (tester) async {
    tester.view.physicalSize = const Size(440, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: PasswordGeneratorDialog())),
    );
    final input = find.byKey(const ValueKey('passwordLength'));
    await tester.enterText(input, '7');
    await tester.pump();
    expect(find.text('请输入 8–128 的整数'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '使用此密码'))
          .onPressed,
      isNull,
    );
    await tester.enterText(input, '128');
    await tester.pump();
    expect(tester.widget<Slider>(find.byType(Slider)).value, 128);
    expect(
      tester
          .widget<SelectableText>(
            find.byKey(const ValueKey('generatedPassword')),
          )
          .textSpan!
          .toPlainText()
          .length,
      128,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '使用此密码'))
          .onPressed,
      isNotNull,
    );
    final previewScroll = find
        .ancestor(
          of: find.byKey(const ValueKey('generatedPassword')),
          matching: find.byType(SingleChildScrollView),
        )
        .first;
    expect(tester.getSize(previewScroll).height, lessThanOrEqualTo(120));
    await tester.ensureVisible(find.byType(Slider));
    await tester.tap(find.byType(Slider));
    await tester.pumpAndSettle();
    final length = tester.widget<Slider>(find.byType(Slider)).value.round();
    expect(tester.widget<TextField>(input).controller!.text, '$length');
    expect(tester.takeException(), isNull);
  });

  testWidgets('历史默认隐藏，可显示复制定位，确认后删除持久化记录', (tester) async {
    final saving = ArchivePasswordHistory.remember(
      '/tmp/archive.zip',
      'secret-password',
    );
    await tester.pump();
    await saving;
    const channel = MethodChannel('sevenzip/desktop');
    String? revealed;
    String? copied;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'reveal') revealed = call.arguments as String;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: PasswordHistoryDialog())),
    );
    await tester.pumpAndSettle();
    expect(find.text('archive.zip'), findsOneWidget);
    expect(find.text('secret-password'), findsNothing);
    await tester.tap(find.byTooltip('显示密码'));
    await tester.pump();
    expect(find.text('secret-password'), findsOneWidget);
    await tester.tap(find.byTooltip('复制密码'));
    await tester.pumpAndSettle();
    expect(copied, 'secret-password');
    await tester.tap(find.byTooltip('定位压缩包'));
    await tester.pumpAndSettle();
    expect(revealed, '/tmp/archive.zip');
    await tester.tap(find.byTooltip('删除历史'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    final retained = ArchivePasswordHistory.load();
    await tester.pump();
    expect((await retained).length, 1);
    await tester.tap(find.byTooltip('删除历史'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    final deleted = ArchivePasswordHistory.load();
    await tester.pump();
    expect(await deleted, isEmpty);
    expect(find.text('暂无密码历史'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
