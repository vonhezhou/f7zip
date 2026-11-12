import 'package:f7zip/app_theme.dart';
import 'package:f7zip/compression_dialog.dart';
import 'package:f7zip/compression_parameters.dart';
import 'package:f7zip/compression_preset.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('高级参数标签位于展开区域内，小窗口可滚动到线程参数', (tester) async {
    await _mount(tester);
    await tester.ensureVisible(find.text('高级压缩参数'));
    await tester.tap(find.text('高级压缩参数'));
    await tester.pumpAndSettle();
    final method = find.byKey(const ValueKey('compressionMethod:auto'));
    await tester.ensureVisible(method);
    await tester.pumpAndSettle();
    final title = tester.getRect(find.text('高级压缩参数'));
    final field = tester.getRect(method);
    expect(field.top - title.bottom, greaterThanOrEqualTo(12));
    final label = find.descendant(of: method, matching: find.text('压缩算法'));
    final clip = find
        .ancestor(of: method, matching: find.byType(ClipRect))
        .first;
    expect(
      tester.getRect(label).top,
      greaterThanOrEqualTo(tester.getRect(clip).top),
    );
    final threads = find.byKey(const ValueKey('compressionThreads:0'));
    await tester.ensureVisible(threads);
    await tester.tap(threads);
    await tester.pumpAndSettle();
    await _scrollMenuTo(tester, '64');
    await tester.tap(find.text('64').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择保存位置'));
    await tester.pumpAndSettle();
    expect(_result!.parameters.threads, 64);
    expect(tester.takeException(), isNull);
  });

  testWidgets('格式菜单高度受限且背景不透明，末尾格式可滚动选择', (tester) async {
    await _mount(tester);
    await tester.tap(find.byKey(const ValueKey('compressionFormat')));
    await tester.pumpAndSettle();
    final menu = find.byType(ListView).last;
    expect(tester.getSize(menu).height, lessThanOrEqualTo(280));
    final field = tester.widget<DropdownButton<String>>(
      find.descendant(
        of: find.byKey(const ValueKey('compressionFormat')),
        matching: find.byType(DropdownButton<String>),
      ),
    );
    expect(field.dropdownColor!.a, 1);
    expect(
      field.dropdownColor,
      buildAppTheme(
        Brightness.dark,
        colorTheme: AppColorTheme.green,
      ).colorScheme.surfaceContainerHigh,
    );
    await _scrollMenuTo(tester, 'BZIP2 · 单文件');
    await tester.tap(find.text('BZIP2 · 单文件').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('volumeSize')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('compressionFormat')));
    await tester.pumpAndSettle();
    await _scrollMenuTo(tester, 'ZIP · 兼容性优先');
    await tester.tap(find.text('ZIP · 兼容性优先').last);
    await tester.pumpAndSettle();
    expect(find.text('不分卷'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('重置恢复初始参数并解除预设选择，可重新加载已保存预设', (tester) async {
    var saves = 0;
    const preset = CompressionPreset(
      name: '备份',
      format: 'zipx',
      level: 9,
      volumeSize: 3 * 1048576,
      encryption: 'ZipCrypto',
      encryptNames: false,
      parameters: CompressionParameters(
        method: 'LZMA',
        dictionaryMiB: 32,
        threads: 4,
      ),
    );
    await _mount(
      tester,
      presets: [preset],
      defaultPreset: '备份',
      onSave: () => saves++,
    );
    await tester.enterText(
      find.byKey(const ValueKey('compressionPassword')),
      'task-secret',
    );
    await tester.enterText(
      find.byKey(const ValueKey('customVolumeSize')),
      'invalid',
    );
    await tester.ensureVisible(find.byTooltip('重置压缩设置'));
    await tester.tap(find.byTooltip('重置压缩设置'));
    await tester.pumpAndSettle();
    expect(find.text('自定义设置'), findsOneWidget);
    expect(find.text('ZIP · 兼容性优先'), findsOneWidget);
    expect(find.text('标准'), findsOneWidget);
    expect(find.text('不分卷'), findsOneWidget);
    expect(find.text('AES-256'), findsOneWidget);
    expect(find.byKey(const ValueKey('customVolumeSize')), findsNothing);
    expect(saves, 0);
    await tester.tap(find.text('选择保存位置'));
    await tester.pumpAndSettle();
    expect(_result!.format, 'zip');
    expect(_result!.level, 5);
    expect(_result!.volumeSize, 0);
    expect(_result!.encryption, 'AES256');
    expect(_result!.encryptNames, isTrue);
    expect(
      _result!.parameters.toJson(),
      const CompressionParameters().toJson(),
    );
    expect(_result!.password, 'task-secret');
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('重置压缩设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('compressionPreset')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('备份 · 默认').last);
    await tester.pumpAndSettle();
    expect(find.text('ZIPX · LZMA 默认'), findsOneWidget);
    expect(find.text('极限'), findsOneWidget);
    expect(saves, 0);
    expect(tester.takeException(), isNull);
  });
}

CompressionOptions? _result;

Future<void> _mount(
  WidgetTester tester, {
  List<CompressionPreset> presets = const [],
  String defaultPreset = '',
  VoidCallback? onSave,
}) async {
  _result = null;
  tester.view.physicalSize = const Size(900, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.dark, colorTheme: AppColorTheme.green),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              _result = await showDialog<CompressionOptions>(
                context: context,
                builder: (_) => CompressionDialog(
                  inputs: const ['/tmp/source'],
                  presets: presets,
                  defaultPreset: defaultPreset,
                  onPresetsChanged: (_, _) async => onSave?.call(),
                ),
              );
            },
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

Future<void> _scrollMenuTo(WidgetTester tester, String label) async {
  final menu = find.byType(ListView).last;
  final scrollable = find.descendant(
    of: menu,
    matching: find.byType(Scrollable),
  );
  tester.state<ScrollableState>(scrollable).position.jumpTo(0);
  await tester.pump();
  await tester.scrollUntilVisible(
    find.descendant(of: menu, matching: find.text(label)),
    120,
    scrollable: scrollable,
  );
}
