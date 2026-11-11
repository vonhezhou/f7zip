import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'custom_theme_controls.dart';
import 'filename_encoding.dart';
import 'filename_normalization.dart';
import 'compression_preset.dart';
import 'password_manager.dart';

const _desktop = MethodChannel('sevenzip/desktop');

class AppSettings {
  const AppSettings({
    this.alternateRows = true,
    this.singleClickOpen = true,
    this.showDotEntries = true,
    this.removeRedundantRoot = false,
    this.smartExtraction = false,
    this.autoUnpackTar = true,
    this.autoTryPasswords = false,
    this.viewer = '',
    this.editor = '',
    this.themeMode = ThemeMode.system,
    this.colorTheme = AppColorTheme.purple,
    this.customThemes = const [],
    this.selectedCustomTheme = '',
    this.filenameEncoding = FilenameEncoding.autoDetect,
    this.filenameNormalization = FilenameNormalization.preserve,
    this.compressionPresets = const [],
    this.defaultCompressionPreset = '',
  });

  factory AppSettings.fromJson(Map<dynamic, dynamic> json) {
    final presets = <CompressionPreset>[];
    final stored = json['compressionPresets'];
    if (stored is List) {
      for (final entry in stored) {
        if (entry is! Map) continue;
        final preset = CompressionPreset.fromJson(entry);
        if (preset.name.isNotEmpty &&
            !presets.any((item) => item.name == preset.name)) {
          presets.add(preset);
        }
      }
    }
    final themes = <CustomColorTheme>[];
    final storedThemes = json['customThemes'];
    if (storedThemes is List) {
      for (final entry in storedThemes) {
        try {
          final theme = CustomColorTheme.fromJson(entry);
          if (!themes.any((item) => item.name == theme.name)) themes.add(theme);
        } on FormatException {
          // 跳过损坏条目，其余主题仍可使用。
        }
      }
    }
    final selectedTheme = json['selectedCustomTheme'];
    final defaultName = json['defaultCompressionPreset'];
    return AppSettings(
      customThemes: List.unmodifiable(themes),
      selectedCustomTheme: themes.any((theme) => theme.name == selectedTheme)
          ? selectedTheme as String
          : '',
      compressionPresets: List.unmodifiable(presets),
      defaultCompressionPreset:
          presets.any((preset) => preset.name == defaultName)
          ? defaultName as String
          : '',
      alternateRows: json['alternateRows'] as bool? ?? true,
      singleClickOpen: json['singleClickOpen'] as bool? ?? true,
      showDotEntries: json['showDotEntries'] as bool? ?? true,
      removeRedundantRoot: json['removeRedundantRoot'] as bool? ?? false,
      smartExtraction: json['smartExtraction'] as bool? ?? false,
      autoUnpackTar: json['autoUnpackTar'] as bool? ?? true,
      autoTryPasswords: json['autoTryPasswords'] == true,
      viewer: json['viewer'] as String? ?? '',
      editor: json['editor'] as String? ?? '',
      themeMode: ThemeMode.values.firstWhere(
        (mode) => mode.name == json['themeMode'],
        orElse: () => ThemeMode.system,
      ),
      filenameEncoding: FilenameEncoding.values.firstWhere(
        (encoding) => encoding.name == json['filenameEncoding'],
        orElse: () => FilenameEncoding.autoDetect,
      ),
      filenameNormalization: FilenameNormalization.values.firstWhere(
        (mode) => mode.name == json['filenameNormalization'],
        orElse: () => FilenameNormalization.preserve,
      ),
      colorTheme: AppColorTheme.values.firstWhere(
        (theme) => theme.name == json['colorTheme'],
        orElse: () => AppColorTheme.purple,
      ),
    );
  }

  final List<CompressionPreset> compressionPresets;
  final String defaultCompressionPreset;

  AppSettings withCompressionPresets(
    List<CompressionPreset> presets,
    String defaultName,
  ) => AppSettings(
    alternateRows: alternateRows,
    singleClickOpen: singleClickOpen,
    showDotEntries: showDotEntries,
    removeRedundantRoot: removeRedundantRoot,
    smartExtraction: smartExtraction,
    autoUnpackTar: autoUnpackTar,
    autoTryPasswords: autoTryPasswords,
    viewer: viewer,
    editor: editor,
    themeMode: themeMode,
    colorTheme: colorTheme,
    customThemes: customThemes,
    selectedCustomTheme: selectedCustomTheme,
    filenameEncoding: filenameEncoding,
    filenameNormalization: filenameNormalization,
    compressionPresets: List.unmodifiable(presets),
    defaultCompressionPreset: defaultName,
  );

  final bool alternateRows;
  final bool singleClickOpen;
  final bool showDotEntries;
  final bool removeRedundantRoot;
  final bool smartExtraction;
  final bool autoUnpackTar;
  final bool autoTryPasswords;
  final String viewer;
  final String editor;
  final ThemeMode themeMode;
  final AppColorTheme colorTheme;
  final List<CustomColorTheme> customThemes;
  final String selectedCustomTheme;

  CustomColorTheme? get customTheme => customThemes
      .where((theme) => theme.name == selectedCustomTheme)
      .firstOrNull;
  final FilenameEncoding filenameEncoding;
  final FilenameNormalization filenameNormalization;

  Map<String, dynamic> toJson() => {
    'compressionPresets': compressionPresets
        .map((preset) => preset.toJson())
        .toList(),
    'defaultCompressionPreset': defaultCompressionPreset,
    'alternateRows': alternateRows,
    'singleClickOpen': singleClickOpen,
    'showDotEntries': showDotEntries,
    'removeRedundantRoot': removeRedundantRoot,
    'smartExtraction': smartExtraction,
    'autoUnpackTar': autoUnpackTar,
    'autoTryPasswords': autoTryPasswords,
    'viewer': viewer,
    'editor': editor,
    'themeMode': themeMode.name,
    'colorTheme': colorTheme.name,
    'customThemes': customThemes.map((theme) => theme.toJson()).toList(),
    'selectedCustomTheme': selectedCustomTheme,
    'filenameEncoding': filenameEncoding.name,
    'filenameNormalization': filenameNormalization.name,
  };
}

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.initial});
  final AppSettings initial;
  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late String _defaultCompressionPreset =
      widget.initial.defaultCompressionPreset;
  late ThemeMode _themeMode = widget.initial.themeMode;
  late AppColorTheme _colorTheme = widget.initial.colorTheme;
  late List<CustomColorTheme> _customThemes = List.of(
    widget.initial.customThemes,
  );
  late String _selectedCustomTheme = widget.initial.selectedCustomTheme;
  CustomColorTheme? get _customTheme => _customThemes
      .where((theme) => theme.name == _selectedCustomTheme)
      .firstOrNull;
  late FilenameEncoding _filenameEncoding = widget.initial.filenameEncoding;
  late FilenameNormalization _filenameNormalization =
      widget.initial.filenameNormalization;
  late bool _alternateRows = widget.initial.alternateRows;
  late bool _singleClickOpen = widget.initial.singleClickOpen;
  late bool _showDotEntries = widget.initial.showDotEntries;
  late bool _smartExtraction = widget.initial.smartExtraction;
  late bool _autoUnpackTar = widget.initial.autoUnpackTar;
  late bool _autoTryPasswords = widget.initial.autoTryPasswords;
  late bool _removeRedundantRoot = widget.initial.removeRedundantRoot;
  late final _viewer = TextEditingController(text: widget.initial.viewer);
  late final _editor = TextEditingController(text: widget.initial.editor);
  List<Map<String, dynamic>> _associations = [];
  bool _saving = false;
  bool _themeBusy = false;
  bool _binding = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadAssociations();
  }

  @override
  void dispose() {
    _viewer.dispose();
    _editor.dispose();
    super.dispose();
  }

  Future<void> _loadAssociations() async {
    try {
      final entries =
          await _desktop.invokeListMethod<dynamic>('fileAssociations') ?? [];
      if (mounted) {
        setState(
          () => _associations = entries
              .map((value) => Map<String, dynamic>.from(value as Map))
              .toList(),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _associate(
    Map<String, dynamic> association,
    bool restore,
  ) async {
    setState(() {
      _binding = true;
      _error = null;
    });
    try {
      final entries =
          await _desktop.invokeListMethod<dynamic>('setFileAssociation', {
            'extension': association['extension'],
            'restore': restore,
          }) ??
          [];
      if (mounted) {
        setState(
          () => _associations = entries
              .map((value) => Map<String, dynamic>.from(value as Map))
              .toList(),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _binding = false);
    }
  }

  Future<void> _chooseApplication(TextEditingController controller) async {
    final path = await _desktop.invokeMethod<String>('chooseApplication');
    if (path != null && mounted) controller.text = path;
  }

  Future<void> _save() async {
    final settings = AppSettings(
      compressionPresets: widget.initial.compressionPresets,
      defaultCompressionPreset: _defaultCompressionPreset,
      themeMode: _themeMode,
      colorTheme: _colorTheme,
      customThemes: List.unmodifiable(_customThemes),
      selectedCustomTheme: _selectedCustomTheme,
      filenameEncoding: _filenameEncoding,
      filenameNormalization: _filenameNormalization,
      alternateRows: _alternateRows,
      singleClickOpen: _singleClickOpen,
      showDotEntries: _showDotEntries,
      removeRedundantRoot: _removeRedundantRoot,
      smartExtraction: _smartExtraction,
      autoUnpackTar: _autoUnpackTar,
      autoTryPasswords: _autoTryPasswords,
      viewer: _viewer.text.trim(),
      editor: _editor.text.trim(),
    );
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _desktop.invokeMethod<void>('saveSettings', settings.toJson());
      if (mounted) Navigator.pop(context, settings);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final brightness = switch (_themeMode) {
      ThemeMode.system => MediaQuery.platformBrightnessOf(context),
      ThemeMode.light => Brightness.light,
      ThemeMode.dark => Brightness.dark,
    };
    return Theme(
      data: buildAppTheme(
        brightness,
        colorTheme: _colorTheme,
        customTheme: _customTheme,
      ),
      child: Builder(
        builder: (context) => DefaultTabController(
          length: 5,
          child: AlertDialog(
            titlePadding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            contentPadding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            title: const Text('设置'),
            content: SizedBox(
              width: 620,
              height: 350,
              child: Column(
                children: [
                  const TabBar(
                    tabs: [
                      Tab(height: 36, text: '常规'),
                      Tab(height: 36, text: '压缩'),
                      Tab(height: 36, text: '文件关联'),
                      Tab(height: 36, text: '外部程序'),
                      Tab(height: 36, text: '密码'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: TabBarView(
                      children: [
                        ListView(
                          children: [
                            ListTile(
                              title: const Text('明暗模式'),
                              trailing: DropdownButton<ThemeMode>(
                                key: const ValueKey('themeMode'),
                                value: _themeMode,
                                items: const [
                                  DropdownMenuItem(
                                    value: ThemeMode.system,
                                    child: Text('跟随系统'),
                                  ),
                                  DropdownMenuItem(
                                    value: ThemeMode.light,
                                    child: Text('浅色'),
                                  ),
                                  DropdownMenuItem(
                                    value: ThemeMode.dark,
                                    child: Text('深色'),
                                  ),
                                ],
                                onChanged: (value) {
                                  if (value != null) {
                                    setState(() => _themeMode = value);
                                  }
                                },
                              ),
                            ),
                            ListTile(
                              title: const Text('创建与解压文件名规范化'),
                              subtitle: const Text('规范等价拼写重名时停止操作，请调整名称后重试。'),
                              trailing: DropdownButton<FilenameNormalization>(
                                key: const ValueKey('filenameNormalization'),
                                value: _filenameNormalization,
                                items: [
                                  for (final mode
                                      in FilenameNormalization.values)
                                    DropdownMenuItem(
                                      value: mode,
                                      child: Text(mode.label),
                                    ),
                                ],
                                onChanged: _saving
                                    ? null
                                    : (value) {
                                        if (value != null) {
                                          setState(
                                            () =>
                                                _filenameNormalization = value,
                                          );
                                        }
                                      },
                              ),
                            ),
                            ListTile(
                              title: const Text('ZIP 文件名编码'),
                              trailing: DropdownButton<FilenameEncoding>(
                                key: const ValueKey('filenameEncoding'),
                                value: _filenameEncoding,
                                style: Theme.of(context).textTheme.bodyMedium,
                                items: [
                                  for (final encoding
                                      in FilenameEncoding.values)
                                    DropdownMenuItem(
                                      value: encoding,
                                      child: Text(encoding.label),
                                    ),
                                ],
                                onChanged: _saving
                                    ? null
                                    : (value) {
                                        if (value != null) {
                                          setState(
                                            () => _filenameEncoding = value,
                                          );
                                        }
                                      },
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('颜色主题'),
                                  const SizedBox(height: 6),
                                  Text(
                                    'Material 3 配色 · 选择后预览，保存后应用',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall,
                                  ),
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 6,
                                    runSpacing: 6,
                                    children: [
                                      for (final theme in AppColorTheme.values)
                                        ChoiceChip(
                                          key: ValueKey(
                                            'colorTheme:${theme.name}',
                                          ),
                                          label: Text(theme.label),
                                          avatar: CircleAvatar(
                                            radius: 8,
                                            backgroundColor:
                                                ColorScheme.fromSeed(
                                                  seedColor: theme.seedColor,
                                                  brightness: brightness,
                                                ).primary,
                                          ),
                                          selected:
                                              _selectedCustomTheme.isEmpty &&
                                              _colorTheme == theme,
                                          onSelected: _saving
                                              ? null
                                              : (_) => setState(() {
                                                  _colorTheme = theme;
                                                  _selectedCustomTheme = '';
                                                }),
                                        ),
                                    ],
                                  ),
                                  CustomThemeControls(
                                    onBusyChanged: (busy) =>
                                        setState(() => _themeBusy = busy),
                                    themes: _customThemes,
                                    selected: _selectedCustomTheme,
                                    seedColor:
                                        _customTheme?.seedColor ??
                                        _colorTheme.seedColor,
                                    exportTheme:
                                        _customTheme ??
                                        CustomColorTheme(
                                          name: _colorTheme.label,
                                          seedColor: _colorTheme.seedColor,
                                        ),
                                    enabled: !_saving,
                                    onChanged: (themes, selected) =>
                                        setState(() {
                                          _customThemes = themes;
                                          _selectedCustomTheme = selected;
                                        }),
                                  ),
                                ],
                              ),
                            ),
                            const Divider(height: 1),
                            SwitchListTile(
                              key: const ValueKey('autoUnpackTar'),
                              title: const Text('自动解开 TAR 复合压缩包'),
                              subtitle: const Text(
                                'TAR.GZ / TAR.BZ2 / TAR.XZ 及 TGZ / TBZ / TBZ2 / TXZ 一次解压得到内部文件。关闭后浏览和解压外层，得到 TAR 文件',
                              ),
                              value: _autoUnpackTar,
                              onChanged: (value) =>
                                  setState(() => _autoUnpackTar = value),
                            ),
                            SwitchListTile(
                              key: const ValueKey('smartExtraction'),
                              title: const Text('智能选择解压目录'),
                              subtitle: const Text(
                                '单文件或单目录直接解压到所选位置，多项目使用压缩包名称的文件夹；Finder 原地解压直接使用同级目录',
                              ),
                              value: _smartExtraction,
                              onChanged: (value) =>
                                  setState(() => _smartExtraction = value),
                            ),
                            SwitchListTile(
                              title: const Text('解压时删除冗余的根目录'),
                              subtitle: const Text(
                                '结果只有一个顶层文件夹时去掉这一层，适用于主窗口和 Finder 解压',
                              ),
                              value: _removeRedundantRoot,
                              onChanged: (value) =>
                                  setState(() => _removeRedundantRoot = value),
                            ),
                            SwitchListTile(
                              title: const Text('隔行背景色'),
                              subtitle: const Text('使用交替背景区分相邻文件，适配当前主题'),
                              value: _alternateRows,
                              onChanged: (value) =>
                                  setState(() => _alternateRows = value),
                            ),
                            SwitchListTile(
                              title: const Text('单击打开文件和文件夹'),
                              subtitle: const Text('关闭后使用双击打开，勾选框用于多选'),
                              value: _singleClickOpen,
                              onChanged: (value) =>
                                  setState(() => _singleClickOpen = value),
                            ),
                            SwitchListTile(
                              title: const Text('显示返回上一级目录项（..）'),
                              subtitle: const Text('仅在压缩包子目录显示，返回包内上一级目录'),
                              value: _showDotEntries,
                              onChanged: (value) =>
                                  setState(() => _showDotEntries = value),
                            ),
                          ],
                        ),
                        ListView(
                          children: [
                            DropdownButtonFormField<String>(
                              key: const ValueKey('defaultCompressionPreset'),
                              initialValue: _defaultCompressionPreset,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: '默认压缩预设',
                              ),
                              items: [
                                const DropdownMenuItem(
                                  value: '',
                                  child: Text('使用标准设置'),
                                ),
                                for (final preset
                                    in widget.initial.compressionPresets)
                                  DropdownMenuItem(
                                    value: preset.name,
                                    child: Text(
                                      preset.name,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: (value) => setState(
                                () => _defaultCompressionPreset = value!,
                              ),
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              '在“新建压缩包”中保存、更新和删除预设。默认预设用于主窗口与 Finder 的配置压缩入口。密码按每次任务输入。',
                            ),
                            const SizedBox(height: 8),
                            for (final preset
                                in widget.initial.compressionPresets)
                              ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                title: Text(preset.name),
                                subtitle: Text(
                                  '${preset.format.toUpperCase()} · 等级 ${preset.level} · ${preset.volumeSize == 0 ? '不分卷' : '${preset.volumeSize ~/ 1048576} MiB / 卷'}',
                                ),
                              ),
                          ],
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '按后缀设置默认打开程序，系统会按需要请求确认。',
                              style: TextStyle(fontSize: 12),
                            ),
                            const SizedBox(height: 8),
                            Expanded(
                              child: ListView.builder(
                                itemCount: _associations.length,
                                itemBuilder: (context, index) {
                                  final association = _associations[index];
                                  return SizedBox(
                                    height: 34,
                                    child: Row(
                                      children: [
                                        SizedBox(
                                          width: 72,
                                          child: Text(
                                            '.${association['extension']}',
                                          ),
                                        ),
                                        Expanded(
                                          child: Text(
                                            association['application']
                                                as String,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                        if (association['canRestore'] == true)
                                          TextButton(
                                            onPressed: _binding
                                                ? null
                                                : () => _associate(
                                                    association,
                                                    true,
                                                  ),
                                            child: const Text('恢复原应用'),
                                          ),
                                        TextButton(
                                          key: ValueKey(
                                            'associate:${association['extension']}',
                                          ),
                                          onPressed:
                                              _binding ||
                                                  association['ours'] == true
                                              ? null
                                              : () => _associate(
                                                  association,
                                                  false,
                                                ),
                                          child: Text(
                                            association['ours'] == true
                                                ? '已关联'
                                                : '设为 F7Zip',
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                        ListView(
                          children: [
                            const Text(
                              '查看时使用查看程序，编辑时监控保存并自动回写 ZIP / 7z。\n留空时使用系统默认程序。',
                              style: TextStyle(fontSize: 12),
                            ),
                            const SizedBox(height: 12),
                            _programField('查看程序', _viewer),
                            const SizedBox(height: 12),
                            _programField('编辑程序', _editor),
                            const SizedBox(height: 12),
                            Text(
                              '编辑文件保存在应用支持目录。回写失败时可定位文件、重试，重启后会恢复编辑会话。',
                              style: TextStyle(
                                fontSize: 11,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                        Column(
                          children: [
                            SwitchListTile(
                              key: const ValueKey('autoTryPasswords'),
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                              title: const Text('自动尝试钥匙串中的常用密码'),
                              subtitle: const Text(
                                '开启后在操作加密归档时按顺序尝试，随后可手动输入密码。',
                              ),
                              value: _autoTryPasswords,
                              onChanged: _saving
                                  ? null
                                  : (value) => setState(
                                      () => _autoTryPasswords = value,
                                    ),
                            ),
                            const Expanded(child: PasswordManager()),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _error!,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: _saving || _binding || _themeBusy
                    ? null
                    : () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: _saving || _binding || _themeBusy ? null : _save,
                child: Text(_saving ? '保存中…' : '保存设置'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _programField(String label, TextEditingController controller) => Row(
    children: [
      Expanded(
        child: TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: label,
            hintText: '/Applications/应用名称.app',
          ),
        ),
      ),
      const SizedBox(width: 10),
      OutlinedButton(
        onPressed: () => _chooseApplication(controller),
        child: const Text('选择…'),
      ),
    ],
  );
}
