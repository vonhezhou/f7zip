import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'archive_password_history.dart';
import 'desktop_bridge.dart';

class PasswordHistoryDialog extends StatefulWidget {
  const PasswordHistoryDialog({super.key});

  @override
  State<PasswordHistoryDialog> createState() => _PasswordHistoryDialogState();
}

class _PasswordHistoryDialogState extends State<PasswordHistoryDialog> {
  List<ArchivePasswordRecord> _records = [];
  final _visible = <String>{};
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final records = await ArchivePasswordHistory.load();
      if (mounted) setState(() => _records = records);
    } catch (error) {
      if (mounted) setState(() => _error = '读取密码历史失败。$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(ArchivePasswordRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除密码历史？'),
        content: Text(
          '删除“${p.basename(record.path)}”的密码记录后，请自行保管密码。压缩包文件仍保存在原路径。',
        ),
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
      await ArchivePasswordHistory.delete(record.id);
      if (mounted) {
        setState(() {
          _records.removeWhere((item) => item.id == record.id);
          _visible.remove(record.id);
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '删除密码历史失败。$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reveal(ArchivePasswordRecord record) async {
    try {
      await const DesktopBridge().invokeMethod<void>('reveal', record.path);
    } catch (error) {
      if (mounted) setState(() => _error = '定位压缩包失败。$error');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('压缩包密码历史'),
    content: SizedBox(
      width: 600,
      height: 400,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '加密压缩成功后自动保存路径、密码和创建时间，密码由本机系统安全存储保管。',
            style: TextStyle(fontSize: 12),
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            SelectableText(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          Expanded(
            child: _records.isEmpty
                ? Center(child: Text(_busy ? '正在读取…' : '暂无密码历史'))
                : ListView.builder(
                    itemCount: _records.length,
                    itemBuilder: (context, index) {
                      final record = _records[index];
                      final visible = _visible.contains(record.id);
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              p.basename(record.path),
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            SelectableText(
                              record.path,
                              style: const TextStyle(fontSize: 12),
                            ),
                            Text(
                              record.createdAt
                                  .toLocal()
                                  .toString()
                                  .split('.')
                                  .first,
                              style: const TextStyle(fontSize: 12),
                            ),
                            Row(
                              children: [
                                Expanded(
                                  child: SelectableText(
                                    visible ? record.password : '••••••••••••',
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: visible ? '隐藏密码' : '显示密码',
                                  onPressed: () => setState(() {
                                    if (visible) {
                                      _visible.remove(record.id);
                                    } else {
                                      _visible.add(record.id);
                                    }
                                  }),
                                  icon: Icon(
                                    visible
                                        ? Icons.visibility_off_outlined
                                        : Icons.visibility_outlined,
                                  ),
                                ),
                                IconButton(
                                  tooltip: '复制密码',
                                  onPressed: () async {
                                    await Clipboard.setData(
                                      ClipboardData(text: record.password),
                                    );
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(content: Text('密码已复制')),
                                      );
                                    }
                                  },
                                  icon: const Icon(Icons.copy_outlined),
                                ),
                                IconButton(
                                  tooltip: '定位压缩包',
                                  onPressed: () => _reveal(record),
                                  icon: const Icon(Icons.folder_open_outlined),
                                ),
                                IconButton(
                                  tooltip: '删除历史',
                                  onPressed: _busy
                                      ? null
                                      : () => _delete(record),
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              ],
                            ),
                            const Divider(),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: _busy ? null : _load, child: const Text('刷新')),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}
