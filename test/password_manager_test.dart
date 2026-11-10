import 'package:f7zip/app_settings.dart';
import 'package:f7zip/password_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const channel = MethodChannel('sevenzip/desktop');
  test('自动尝试默认关闭，配置与预设更新保留授权开关', () {
    expect(AppSettings.fromJson({}).autoTryPasswords, isFalse);
    expect(
      AppSettings.fromJson({'autoTryPasswords': 'true'}).autoTryPasswords,
      isFalse,
    );
    final settings = const AppSettings(autoTryPasswords: true)
        .withCompressionPresets([], '');
    expect(AppSettings.fromJson(settings.toJson()).autoTryPasswords, isTrue);
    expect(settings.toJson().containsKey('passwords'), isFalse);
  });

  testWidgets('设置仅保存自动尝试授权，常用密码单独管理', (tester) async {
    Map? saved;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'listArchivePasswords') return ['工作归档'];
      if (call.method == 'saveSettings') saved = call.arguments as Map;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => const SettingsDialog(initial: AppSettings()),
            ),
            child: const Text('设置'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('密码'));
    await tester.pumpAndSettle();
    expect(find.text('工作归档'), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const ValueKey('autoTryPasswords')),
          )
          .value,
      isFalse,
    );
    await tester.tap(find.byKey(const ValueKey('autoTryPasswords')));
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(saved!['autoTryPasswords'], isTrue);
    expect(saved!.containsKey('passwords'), isFalse);
    expect(saved.toString(), isNot(contains('工作归档')));
  });

  testWidgets('钥匙串新增更新删除的失败重试与取消保护', (tester) async {
    final names = <String>[];
    final values = <String>[];
    var failSave = true;
    var failDelete = true;
    var deletes = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'listArchivePasswords') return List.of(names);
      if (call.method == 'saveArchivePassword') {
        if (failSave) {
          throw PlatformException(code: 'keychain', message: '保存失败');
        }
        final arguments = call.arguments as Map;
        if (arguments['replace'] != true) {
          names.add(arguments['name'] as String);
        }
        values.add(arguments['password'] as String);
        return List.of(names);
      }
      if (call.method == 'deleteArchivePassword') {
        deletes++;
        if (failDelete) {
          throw PlatformException(code: 'keychain', message: '删除失败');
        }
        names.remove((call.arguments as Map)['name']);
        return List.of(names);
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 620, height: 350, child: PasswordManager()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('新增密码'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('passwordName')), '工作归档');
    await tester.enterText(
      find.byKey(const ValueKey('savedPassword')),
      'secret',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('savedPassword')))
          .obscureText,
      isTrue,
    );
    await tester.tap(find.text('保存到钥匙串'));
    await tester.pumpAndSettle();
    expect(names, isEmpty);
    expect(find.textContaining('保存失败'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('savedPassword')))
          .controller!
          .text,
      'secret',
    );
    failSave = false;
    await tester.tap(find.text('保存到钥匙串'));
    await tester.pumpAndSettle();
    expect(find.text('工作归档'), findsOneWidget);
    await tester.tap(find.byTooltip('更新密码'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('passwordName')))
          .readOnly,
      isTrue,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('savedPassword')))
          .controller!
          .text,
      isEmpty,
    );
    await tester.enterText(
      find.byKey(const ValueKey('savedPassword')),
      'updated-secret',
    );
    await tester.tap(find.text('保存到钥匙串'));
    await tester.pumpAndSettle();
    expect(values, ['secret', 'updated-secret']);
    await tester.tap(find.byTooltip('删除密码'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(deletes, 0);
    await tester.tap(find.byTooltip('删除密码'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('工作归档'), findsOneWidget);
    expect(find.textContaining('删除失败'), findsOneWidget);
    failDelete = false;
    await tester.tap(find.byTooltip('删除密码'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(names, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
