import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';

const _desktop = MethodChannel('sevenzip/desktop');

class CustomThemeControls extends StatefulWidget {
  const CustomThemeControls({
    super.key,
    required this.themes,
    required this.selected,
    required this.seedColor,
    required this.exportTheme,
    required this.enabled,
    required this.onChanged,
    required this.onBusyChanged,
  });

  final List<CustomColorTheme> themes;
  final String selected;
  final Color seedColor;
  final CustomColorTheme exportTheme;
  final bool enabled;
  final void Function(List<CustomColorTheme>, String) onChanged;
  final ValueChanged<bool> onBusyChanged;

  @override
  State<CustomThemeControls> createState() => _CustomThemeControlsState();
}

class _CustomThemeControlsState extends State<CustomThemeControls> {
  bool _busy = false;
  String? _message;
  bool _failed = false;

  Future<void> _edit({CustomColorTheme? theme}) async {
    final result = await showDialog<CustomColorTheme>(
      context: context,
      builder: (_) => _ThemeEditor(
        initial:
            theme ?? CustomColorTheme(name: '', seedColor: widget.seedColor),
        existingNames: widget.themes
            .where((item) => item.name != theme?.name)
            .map((item) => item.name)
            .toSet(),
      ),
    );
    if (result == null || !mounted) return;
    final themes = List.of(widget.themes);
    final index = themes.indexWhere((item) => item.name == theme?.name);
    if (index < 0) {
      themes.add(result);
    } else {
      themes[index] = result;
    }
    widget.onChanged(themes, result.name);
  }

  Future<void> _transfer(bool importing) async {
    setState(() {
      _busy = true;
      _message = null;
      _failed = false;
    });
    widget.onBusyChanged(true);
    // 在异步文件选择前捕获导出内容。
    final exported = widget.exportTheme.exportJson();
    try {
      final path = await _desktop.invokeMethod<String>(
        importing ? 'importTheme' : 'exportTheme',
      );
      if (path == null || !mounted) return;
      if (importing) {
        final file = File(path);
        if (await file.length() > 65536) {
          throw const FormatException('主题文件超过 64 KiB');
        }
        final theme = CustomColorTheme.importJson(await file.readAsString());
        if (!mounted) return;
        var name = theme.name;
        var suffix = 2;
        while (widget.themes.any((item) => item.name == name)) {
          final ending = ' ($suffix)';
          final prefix = theme.name.length > 80 - ending.length
              ? theme.name.substring(0, 80 - ending.length)
              : theme.name;
          name = '$prefix$ending';
          suffix++;
        }
        widget.onChanged([
          ...widget.themes,
          CustomColorTheme(name: name, seedColor: theme.seedColor),
        ], name);
        setState(() => _message = '已导入主题，保存设置后应用');
      } else {
        await File(path).writeAsString('$exported\n', flush: true);
        if (mounted) setState(() => _message = '主题已导出');
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _failed = true;
          _message = '${importing ? '导入' : '导出'}失败 · $error';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        widget.onBusyChanged(false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled && !_busy;
    final selected = widget.themes
        .where((theme) => theme.name == widget.selected)
        .firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.themes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final theme in widget.themes)
                  ChoiceChip(
                    key: ValueKey('customTheme:${theme.name}'),
                    label: Text(theme.name),
                    avatar: CircleAvatar(
                      radius: 8,
                      backgroundColor: theme.seedColor,
                    ),
                    selected: theme.name == widget.selected,
                    onSelected: enabled
                        ? (_) => widget.onChanged(widget.themes, theme.name)
                        : null,
                  ),
              ],
            ),
          ),
        Wrap(
          spacing: 6,
          children: [
            TextButton(
              onPressed: enabled ? _edit : null,
              child: const Text('自定义主题…'),
            ),
            if (selected != null) ...[
              TextButton(
                onPressed: enabled ? () => _edit(theme: selected) : null,
                child: const Text('编辑主题'),
              ),
              TextButton(
                onPressed: enabled
                    ? () => widget.onChanged(
                        widget.themes
                            .where((theme) => theme.name != selected.name)
                            .toList(),
                        '',
                      )
                    : null,
                child: const Text('删除主题'),
              ),
            ],
            TextButton(
              onPressed: enabled ? () => _transfer(true) : null,
              child: const Text('导入主题…'),
            ),
            TextButton(
              onPressed: enabled ? () => _transfer(false) : null,
              child: const Text('导出当前主题…'),
            ),
          ],
        ),
        if (_message != null)
          Text(
            _message!,
            style: TextStyle(
              color: _failed ? Theme.of(context).colorScheme.error : null,
            ),
          ),
      ],
    );
  }
}

class _ThemeEditor extends StatefulWidget {
  const _ThemeEditor({required this.initial, required this.existingNames});
  final CustomColorTheme initial;
  final Set<String> existingNames;

  @override
  State<_ThemeEditor> createState() => _ThemeEditorState();
}

class _ThemeEditorState extends State<_ThemeEditor> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.initial.name);
  late final _color = TextEditingController(text: widget.initial.hexColor);

  static const _picker = MethodChannel('sevenzip/themeColor');
  bool _picking = false;
  String? _pickerError;

  @override
  void initState() {
    super.initState();
    _picker.setMethodCallHandler((call) async {
      if (call.method == 'colorChanged' &&
          _picking &&
          mounted &&
          call.arguments is int) {
        _setColor(Color(call.arguments as int));
      }
    });
  }

  void _setColor(Color color) => setState(() {
    _color.text = CustomColorTheme(name: '', seedColor: color).hexColor;
  });

  Future<void> _chooseColor() async {
    final previous = _color.text;
    setState(() {
      _picking = true;
      _pickerError = null;
    });
    try {
      final color = await _picker.invokeMethod<int>(
        'chooseColor',
        (_seed ?? widget.initial.seedColor).toARGB32(),
      );
      if (!mounted) return;
      if (color == null) {
        setState(() => _color.text = previous);
      } else {
        _setColor(Color(color));
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _color.text = previous;
          _pickerError = '无法打开调色盘 · $error';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _picking = false);
      }
    }
  }

  Color? get _seed => RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(_color.text)
      ? Color(0xFF000000 | int.parse(_color.text.substring(1), radix: 16))
      : null;

  @override
  void dispose() {
    _picker.setMethodCallHandler(null);
    _name.dispose();
    _color.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_picking,
    child: AlertDialog(
      title: const Text('自定义主题'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  key: const ValueKey('customThemeName'),
                  controller: _name,
                  autofocus: true,
                  maxLength: 80,
                  decoration: const InputDecoration(labelText: '主题名称'),
                  validator: (value) {
                    final name = value?.trim() ?? '';
                    if (name.isEmpty) return '请输入主题名称';
                    if (widget.existingNames.contains(name)) return '主题名称已存在';
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        key: const ValueKey('customThemeColor'),
                        controller: _color,
                        enabled: !_picking,
                        decoration: InputDecoration(
                          labelText: '种子色',
                          hintText: '#6750A4',
                          prefixIcon: Padding(
                            padding: const EdgeInsets.all(10),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: _seed ?? widget.initial.seedColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ),
                        onChanged: (_) => setState(() {}),
                        validator: (_) =>
                            _seed == null ? '请输入 #RRGGBB 格式的颜色' : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      key: const ValueKey('themeColorPicker'),
                      onPressed: _picking ? null : _chooseColor,
                      icon: const Icon(Icons.palette_outlined),
                      label: const Text('调色盘…'),
                    ),
                  ],
                ),
                if (_pickerError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _pickerError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                LayoutBuilder(
                  builder: (context, constraints) => Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final brightness in Brightness.values)
                        SizedBox(
                          width: constraints.maxWidth >= 480
                              ? (constraints.maxWidth - 12) / 2
                              : constraints.maxWidth,
                          child: _ThemePreview(
                            brightness: brightness,
                            seedColor: _seed ?? widget.initial.seedColor,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _picking ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _picking
              ? null
              : () {
                  if (_form.currentState!.validate()) {
                    Navigator.pop(
                      context,
                      CustomColorTheme(
                        name: _name.text.trim(),
                        seedColor: _seed!,
                      ),
                    );
                  }
                },
          child: const Text('保存主题'),
        ),
      ],
    ),
  );
}

class _ThemePreview extends StatelessWidget {
  const _ThemePreview({required this.brightness, required this.seedColor});
  final Brightness brightness;
  final Color seedColor;

  @override
  Widget build(BuildContext context) => Theme(
    data: buildAppTheme(
      brightness,
      customTheme: CustomColorTheme(name: '', seedColor: seedColor),
    ),
    child: Builder(
      builder: (context) {
        final colors = AppColors.of(context);
        return Material(
          key: ValueKey('themePreview:${brightness.name}'),
          color: colors.canvas,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: colors.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              Container(
                color: colors.panel,
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        brightness == Brightness.light ? '浅色预览' : '深色预览',
                      ),
                    ),
                    FilledButton(onPressed: () {}, child: const Text('解压')),
                  ],
                ),
              ),
              ListTile(
                leading: Icon(Icons.folder, color: colors.folder),
                title: const Text('项目资料'),
                subtitle: const Text('文件夹'),
              ),
              ListTile(
                selected: true,
                selectedTileColor: colors.selection,
                selectedColor: colors.onSelection,
                leading: const Icon(Icons.description_outlined),
                title: const Text('说明.txt'),
                trailing: const Text('12 KB'),
              ),
            ],
          ),
        );
      },
    ),
  );
}
