import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'filename_encoding.dart';

const _desktop = MethodChannel('sevenzip/desktop');

class AppSettings {
  const AppSettings({
    this.alternateRows = true,
    this.singleClickOpen = true,
    this.showDotEntries = true,
    this.removeRedundantRoot = false,
    this.viewer = '',
    this.editor = '',
    this.themeMode = ThemeMode.system,
    this.colorTheme = AppColorTheme.purple,
    this.filenameEncoding = FilenameEncoding.autoDetect,
  });

  factory AppSettings.fromJson(Map<dynamic, dynamic> json) => AppSettings(
    alternateRows: json['alternateRows'] as bool? ?? true,
    singleClickOpen: json['singleClickOpen'] as bool? ?? true,
    showDotEntries: json['showDotEntries'] as bool? ?? true,
    removeRedundantRoot: json['removeRedundantRoot'] as bool? ?? false,
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
    colorTheme: AppColorTheme.values.firstWhere(
      (theme) => theme.name == json['colorTheme'],
      orElse: () => AppColorTheme.purple,
    ),
  );

  final bool alternateRows;
  final bool singleClickOpen;
  final bool showDotEntries;
  final bool removeRedundantRoot;
  final String viewer;
  final String editor;
  final ThemeMode themeMode;
  final AppColorTheme colorTheme;
  final FilenameEncoding filenameEncoding;

  Map<String, dynamic> toJson() => {
    'alternateRows': alternateRows,
    'singleClickOpen': singleClickOpen,
    'showDotEntries': showDotEntries,
    'removeRedundantRoot': removeRedundantRoot,
    'viewer': viewer,
    'editor': editor,
    'themeMode': themeMode.name,
    'colorTheme': colorTheme.name,
    'filenameEncoding': filenameEncoding.name,
  };
}

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.initial});
  final AppSettings initial;
  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late ThemeMode _themeMode = widget.initial.themeMode;
  late AppColorTheme _colorTheme = widget.initial.colorTheme;
  late FilenameEncoding _filenameEncoding = widget.initial.filenameEncoding;
  late bool _alternateRows = widget.initial.alternateRows;
  late bool _singleClickOpen = widget.initial.singleClickOpen;
  late bool _showDotEntries = widget.initial.showDotEntries;
  late bool _removeRedundantRoot = widget.initial.removeRedundantRoot;
  late final _viewer = TextEditingController(text: widget.initial.viewer);
  late final _editor = TextEditingController(text: widget.initial.editor);
  List<Map<String, dynamic>> _associations = [];
  bool _saving = false;
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
      themeMode: _themeMode,
      colorTheme: _colorTheme,
      filenameEncoding: _filenameEncoding,
      alternateRows: _alternateRows,
      singleClickOpen: _singleClickOpen,
      showDotEntries: _showDotEntries,
      removeRedundantRoot: _removeRedundantRoot,
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
      data: buildAppTheme(brightness, colorTheme: _colorTheme),
      child: Builder(
        builder: (context) => DefaultTabController(
          length: 3,
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
                      Tab(height: 36, text: '文件关联'),
                      Tab(height: 36, text: '外部程序'),
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
                                          selected: _colorTheme == theme,
                                          onSelected: _saving
                                              ? null
                                              : (_) => setState(
                                                  () => _colorTheme = theme,
                                                ),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            const Divider(height: 1),
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
                onPressed: _saving || _binding
                    ? null
                    : () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: _saving || _binding ? null : _save,
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
