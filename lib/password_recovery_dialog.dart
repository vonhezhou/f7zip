import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'archive_engine.dart';
import 'password_search_range.dart';

class PasswordRecoveryDialog extends StatefulWidget {
  const PasswordRecoveryDialog({
    super.key,
    required this.archive,
    required this.codePage,
    required this.run,
    required this.cancel,
  });

  final String archive;
  final int codePage;
  final Future<Map<String, dynamic>?> Function(ArchiveRequest) run;
  final VoidCallback cancel;

  @override
  State<PasswordRecoveryDialog> createState() => _PasswordRecoveryDialogState();
}

class _PasswordRecoveryDialogState extends State<PasswordRecoveryDialog> {
  final _words = TextEditingController();
  final _alphabet = TextEditingController(text: '0123456789');
  final _minimum = TextEditingController(text: '1');
  final _maximum = TextEditingController(text: '4');
  final _prefix = TextEditingController();
  final _suffix = TextEditingController();
  final _seconds = TextEditingController(text: '60');
  bool _dictionary = true;
  bool _running = false;
  bool _pauseRequested = false;
  bool _visible = false;
  PasswordSearchRange? _range;
  String? _version;
  String? _found;
  String? _error;
  String _status = '配置搜索范围后开始，搜索记录仅保留在当前窗口。';
  int _next = 0;

  @override
  void dispose() {
    if (_running) widget.cancel();
    for (final controller in [
      _words,
      _alphabet,
      _minimum,
      _maximum,
      _prefix,
      _suffix,
      _seconds,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _search() async {
    if (_running) return;
    final seconds = int.tryParse(_seconds.text);
    try {
      if (seconds == null || seconds < 1 || seconds > 3600) {
        throw const FormatException('本轮运行上限必须为 1–3600 秒');
      }
      _range ??= _dictionary
          ? PasswordSearchRange.dictionary(_words.text)
          : PasswordSearchRange.characters(
              alphabet: _alphabet.text,
              minimum: int.tryParse(_minimum.text) ?? 0,
              maximum: int.tryParse(_maximum.text) ?? 0,
              prefix: _prefix.text,
              suffix: _suffix.text,
            );
    } on FormatException catch (error) {
      setState(() => _error = error.message);
      return;
    }
    setState(() {
      _running = true;
      _pauseRequested = false;
      _error = null;
      _status = '搜索中';
    });
    final elapsed = Stopwatch()..start();
    try {
      if (_version == null) {
        final info = await widget.run(
          ArchiveRequest('passwordSearchInfo', widget.archive),
        );
        if (!mounted || info == null) return;
        _version = info['version'] as String;
      }
      while (mounted && !_pauseRequested && _next < _range!.count) {
        if (elapsed.elapsed >= Duration(seconds: seconds)) {
          _status = '本轮已达运行上限，已暂停';
          break;
        }
        final remaining = _range!.count - _next;
        final batch = List<String>.generate(
          remaining < 8 ? remaining : 8,
          (index) => _range!.candidate(_next + index),
        );
        final result = await widget.run(
          ArchiveRequest(
            'passwordSearch',
            widget.archive,
            expectedVersion: _version!,
            codePage: widget.codePage,
            inputs: batch,
          ),
        );
        if (!mounted || result == null) break;
        final found = result['found'] as int;
        setState(() {
          _next += result['tested'] as int;
          if (found >= 0) {
            _found = batch[found];
            _status = '已找到密码并验证一个加密文件条目';
          }
        });
        if (_found != null) break;
      }
      if (_found == null && _range != null && _next == _range!.count) {
        _status = '已搜索全部候选，未找到可验证的密码';
      } else if (_pauseRequested && _found == null) {
        _status = '已暂停，继续时重试未完成的一批';
      }
    } catch (error) {
      if (mounted) _error = error.toString();
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  void _pause() {
    setState(() {
      _pauseRequested = true;
      _status = '正在暂停，等待当前验证结束';
    });
    widget.cancel();
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    int lines = 1,
  }) => TextField(
    controller: controller,
    enabled: _range == null && !_running,
    minLines: lines,
    maxLines: lines,
    decoration: InputDecoration(labelText: label),
  );

  @override
  Widget build(BuildContext context) {
    final range = _range;
    final complete = _found != null || (range != null && _next == range.count);
    return PopScope(
      canPop: !_running,
      child: AlertDialog(
        title: const Text('自有归档密码恢复'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '单卷 ZIP / 7z 最多 512 MiB、10000 项；总展开量最多 256 MiB，最小加密条目最多 64 MiB。单个搜索任务串行处理，每批最多 8 个候选。',
                ),
                const SizedBox(height: 12),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('候选词表')),
                    ButtonSegment(value: false, label: Text('字符范围')),
                  ],
                  selected: {_dictionary},
                  onSelectionChanged: range == null && !_running
                      ? (selection) =>
                            setState(() => _dictionary = selection.single)
                      : null,
                ),
                if (_dictionary)
                  _field(_words, '每行一个候选，最多 10000 个 / 4 MiB', lines: 4)
                else ...[
                  _field(_alphabet, '字符表（最多 64 个不同字符）'),
                  Row(
                    children: [
                      Expanded(child: _field(_minimum, '最短长度')),
                      const SizedBox(width: 12),
                      Expanded(child: _field(_maximum, '最长长度（最多 8）')),
                    ],
                  ),
                  Row(
                    children: [
                      Expanded(child: _field(_prefix, '已知前缀')),
                      const SizedBox(width: 12),
                      Expanded(child: _field(_suffix, '已知后缀')),
                    ],
                  ),
                  const Text('按长度递增、字符表顺序搜索，最多 1000000 个组合。'),
                ],
                TextField(
                  controller: _seconds,
                  enabled: !_running,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '本轮运行上限（秒，1–3600）',
                  ),
                ),
                const SizedBox(height: 12),
                Text(_status),
                if (range != null) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: _next / range.count),
                  Text('已完成 $_next / ${range.count} 个候选'),
                ],
                const Text(
                  '暂停与时限在当前验证退出后生效，未完成的一批会重新尝试。损坏数据也可能导致候选全部失败。关闭窗口后清除搜索进度。',
                ),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (_found != null)
                  Row(
                    children: [
                      Expanded(
                        child: SelectableText(_visible ? _found! : '••••••••'),
                      ),
                      IconButton(
                        tooltip: _visible ? '隐藏密码' : '显示密码',
                        onPressed: () => setState(() => _visible = !_visible),
                        icon: Icon(
                          _visible ? Icons.visibility_off : Icons.visibility,
                        ),
                      ),
                      IconButton(
                        tooltip: '复制恢复的密码',
                        onPressed: () =>
                            Clipboard.setData(ClipboardData(text: _found!)),
                        icon: const Icon(Icons.copy),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
        actions: [
          if (range != null && !_running)
            TextButton(
              onPressed: () => setState(() {
                _range = null;
                _version = null;
                _found = null;
                _visible = false;
                _next = 0;
                _error = null;
                _status = '重新配置搜索范围';
              }),
              child: const Text('重新配置'),
            ),
          TextButton(
            onPressed: _running ? null : () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          if (_running)
            FilledButton(
              onPressed: _pauseRequested ? null : _pause,
              child: const Text('暂停'),
            )
          else if (!complete)
            FilledButton(
              onPressed: () => unawaited(_search()),
              child: Text(range == null ? '开始搜索' : '继续搜索'),
            ),
        ],
      ),
    );
  }
}
