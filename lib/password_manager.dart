import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _desktop = MethodChannel('sevenzip/desktop');

class PasswordManager extends StatefulWidget {
  const PasswordManager({super.key});

  @override
  State<PasswordManager> createState() => _PasswordManagerState();
}

class _PasswordManagerState extends State<PasswordManager> {
  List<String> _names = [];
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final names =
          await _desktop.invokeListMethod<String>('listArchivePasswords') ?? [];
      if (mounted) setState(() => _names = names);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit([String? existing]) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => _PasswordEditor(name: existing),
    );
    if (changed == true && mounted) await _refresh();
  }

  Future<void> _delete(String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除常用密码？'),
        content: Text('将从钥匙串删除“$name”。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final names =
          await _desktop.invokeListMethod<String>('deleteArchivePassword', {
            'name': name,
          }) ??
          [];
      if (mounted) setState(() => _names = names);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        '常用密码保存在本机 macOS 钥匙串中。最多保存 20 项，读取受钥匙串访问授权控制。',
        style: TextStyle(fontSize: 12),
      ),
      Row(
        children: [
          TextButton.icon(
            onPressed: _busy || _names.length >= 20 ? null : _edit,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('新增密码'),
          ),
          TextButton.icon(
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('刷新'),
          ),
          if (_busy)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: SelectableText(
            _error!,
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ),
      Expanded(
        child: _names.isEmpty
            ? const Center(child: Text('在钥匙串中新增常用密码'))
            : ListView(
                children: [
                  for (final name in _names)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(name),
                      leading: const Icon(Icons.key_outlined, size: 18),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: '更新密码',
                            onPressed: _busy ? null : () => _edit(name),
                            icon: const Icon(Icons.edit_outlined, size: 18),
                          ),
                          IconButton(
                            tooltip: '删除密码',
                            onPressed: _busy ? null : () => _delete(name),
                            icon: const Icon(Icons.delete_outline, size: 18),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
    ],
  );
}

class _PasswordEditor extends StatefulWidget {
  const _PasswordEditor({this.name});
  final String? name;
  @override
  State<_PasswordEditor> createState() => _PasswordEditorState();
}

class _PasswordEditorState extends State<_PasswordEditor> {
  late final _name = TextEditingController(text: widget.name ?? '');
  final _password = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty ||
        _name.text.trim().characters.length > 80 ||
        _password.text.isEmpty) {
      setState(() => _error = '请输入 1–80 字的名称和密码');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _desktop.invokeListMethod<String>('saveArchivePassword', {
        'name': _name.text.trim(),
        'password': _password.text,
        'replace': widget.name != null,
      });
      if (mounted) Navigator.pop(context, true);
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
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: Text(widget.name == null ? '新增常用密码' : '更新常用密码'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('passwordName'),
              controller: _name,
              readOnly: widget.name != null,
              enabled: !_saving,
              decoration: const InputDecoration(labelText: '名称'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('savedPassword'),
              controller: _password,
              obscureText: true,
              enabled: !_saving,
              decoration: const InputDecoration(labelText: '密码'),
              onSubmitted: (_) {
                if (!_saving) _save();
              },
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SelectableText(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中…' : '保存到钥匙串'),
        ),
      ],
    ),
  );
}
