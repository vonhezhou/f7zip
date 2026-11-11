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

  Color? get _seed => RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(_color.text)
      ? Color(0xFF000000 | int.parse(_color.text.substring(1), radix: 16))
      : null;

  @override
  void dispose() {
    _name.dispose();
    _color.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('自定义主题'),
    content: SizedBox(
      width: 380,
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
              TextFormField(
                key: const ValueKey('customThemeColor'),
                controller: _color,
                decoration: const InputDecoration(
                  labelText: '种子色',
                  hintText: '#6750A4',
                ),
                onChanged: (_) => setState(() {}),
                validator: (_) => _seed == null ? '请输入 #RRGGBB 格式的颜色' : null,
              ),
              const SizedBox(height: 16),
              for (final brightness in Brightness.values)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Theme(
                    data: buildAppTheme(
                      brightness,
                      customTheme: CustomColorTheme(
                        name: '',
                        seedColor: _seed ?? widget.initial.seedColor,
                      ),
                    ),
                    child: Builder(
                      builder: (context) => Material(
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(8),
                        child: ListTile(
                          leading: Icon(
                            Icons.folder,
                            color: Theme.of(context).colorScheme.tertiary,
                          ),
                          title: Text(
                            brightness == Brightness.light ? '浅色预览' : '深色预览',
                          ),
                          trailing: FilledButton(
                            onPressed: () {},
                            child: const Text('按钮'),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (_form.currentState!.validate()) {
            Navigator.pop(
              context,
              CustomColorTheme(name: _name.text.trim(), seedColor: _seed!),
            );
          }
        },
        child: const Text('保存主题'),
      ),
    ],
  );
}
