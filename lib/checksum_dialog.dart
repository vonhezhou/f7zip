import 'desktop_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'archive_engine.dart';
import 'checksum_manifest.dart';

class ChecksumDialog extends StatefulWidget {
  const ChecksumDialog({
    super.key,
    required this.run,
    required this.cancel,
    this.archive,
  });
  final Future<Map<String, dynamic>?> Function(String, ArchiveRequest) run;
  final VoidCallback cancel;
  final String? archive;

  @override
  State<ChecksumDialog> createState() => _ChecksumDialogState();
}

class _ChecksumDialogState extends State<ChecksumDialog> {
  static const _desktop = DesktopBridge();
  Map<String, Map<String, dynamic>> _files = {};
  List<ChecksumEntry> _expected = [];
  List<String> _paths = [];
  String _base = '';
  String _algorithm = 'sha256';
  String? _message;
  bool _busy = false;

  Future<void> _perform(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _message = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _calculate(List<String> paths, {String? savePath}) async {
    final result = await widget.run(
      savePath == null ? '计算摘要' : '保存校验清单',
      ArchiveRequest(
        savePath == null ? 'checksum' : 'checksumSave',
        savePath ?? '',
        inputs: paths,
        format: _algorithm,
      ),
    );
    if (!mounted) return;
    setState(() {
      if (result == null) {
        _message = '校验已取消';
        return;
      }
      _files = {
        for (final file in result['files'] as List)
          file['path'] as String: file as Map<String, dynamic>,
      };
      _paths = paths;
      _expected = [];
      _message = savePath == null
          ? '已计算 ${_files.length} 个文件'
          : '清单已保存至 ${result['path']}';
    });
  }

  Future<void> _chooseFiles() => _perform(() async {
    final paths = await _desktop.invokeListMethod<String>(
      'chooseChecksumFiles',
    );
    if (paths != null && paths.isNotEmpty && mounted) await _calculate(paths);
  });

  Future<void> _verify() => _perform(() async {
    final paths = await _desktop.invokeListMethod<String>('openArchive');
    if (paths == null || paths.isEmpty || !mounted) return;
    final (base, entries) = await readChecksumManifest(paths.single);
    if (!mounted) return;
    final result = await widget.run(
      '核验校验清单',
      ArchiveRequest(
        'checksumVerify',
        '',
        destination: base,
        inputs: entries
            .map((entry) => p.join(base, entry.name))
            .toSet()
            .toList(),
      ),
    );
    if (!mounted) return;
    setState(() {
      if (result == null) {
        _message = '核验已取消';
        return;
      }
      _base = base;
      _expected = entries;
      _files = {
        for (final file in result['files'] as List)
          file['path'] as String: file as Map<String, dynamic>,
      };
      _paths = [];
      final matched = entries.where(_matches).length;
      _message = '核验完成，$matched / ${entries.length} 项一致';
    });
  });

  Map<String, dynamic>? _fileFor(ChecksumEntry entry) =>
      _files[p.join(_base, entry.name)];

  bool _matches(ChecksumEntry entry) =>
      '${_fileFor(entry)?[entry.algorithm]}'.toUpperCase() == entry.expected;

  Future<void> _save() => _perform(() async {
    final path = await _desktop.invokeMethod<String>(
      'saveArchive',
      '${_algorithm.toUpperCase()}SUMS',
    );
    if (path != null && mounted) await _calculate(_paths, savePath: path);
  });

  Future<void> _copy() async {
    final text = _expected.isEmpty
        ? _files.values
              .map((file) => '${file[_algorithm]}  ${file['path']}')
              .join('\n')
        : _expected
              .map(
                (entry) =>
                    '${_matches(entry) ? '一致' : '失败'}  ${entry.name}  ${entry.algorithm}  ${entry.expected}',
              )
              .join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) setState(() => _message = '已复制');
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: const Text('校验工具'),
      content: SizedBox(
        width: 760,
        height: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: _busy ? null : _chooseFiles,
                  child: const Text('选择文件计算'),
                ),
                if (widget.archive != null)
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () => _perform(() => _calculate([widget.archive!])),
                    child: const Text('计算当前归档'),
                  ),
                OutlinedButton(
                  onPressed: _busy ? null : _verify,
                  child: const Text('核验清单…'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _algorithm,
              decoration: const InputDecoration(labelText: '摘要算法'),
              items: const [
                DropdownMenuItem(value: 'sha256', child: Text('SHA-256')),
                DropdownMenuItem(value: 'crc32', child: Text('CRC32')),
                DropdownMenuItem(value: 'crc64', child: Text('CRC64/XZ')),
              ],
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _algorithm = value!),
            ),
            const SizedBox(height: 8),
            const Text(
              '支持 SHA-256、CRC32、CRC64/XZ 清单及 SFV。保存时重新计算，清单应位于全部文件的共同父目录或其上级目录，已有文件受到保护。',
              style: TextStyle(fontSize: 11),
            ),
            const SizedBox(height: 8),
            if (_busy) const LinearProgressIndicator(),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  _message!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            Expanded(
              child: ListView.builder(
                itemCount: _expected.isEmpty ? _files.length : _expected.length,
                itemBuilder: (_, index) {
                  if (_expected.isNotEmpty) {
                    final entry = _expected[index];
                    final file = _fileFor(entry);
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        _matches(entry)
                            ? Icons.check_circle_outline
                            : Icons.error_outline,
                      ),
                      title: Text(entry.name),
                      subtitle: SelectableText(
                        '${entry.algorithm} · ${_matches(entry) ? '一致' : file?['error'] ?? '摘要不一致'}\n期望 ${entry.expected}\n实际 ${file?[entry.algorithm] ?? '不可用'}',
                      ),
                    );
                  }
                  final file = _files.values.elementAt(index);
                  return ListTile(
                    dense: true,
                    title: Text(file['path'] as String),
                    subtitle: SelectableText(file[_algorithm] as String),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy || _files.isEmpty ? null : _copy,
          child: const Text('复制'),
        ),
        TextButton(
          onPressed: _busy || _paths.isEmpty ? null : _save,
          child: const Text('保存清单…'),
        ),
        if (_busy)
          TextButton(onPressed: widget.cancel, child: const Text('取消计算'))
        else
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
      ],
    ),
  );
}
