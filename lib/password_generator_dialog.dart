import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'archive_password_history.dart';
import 'password_history_dialog.dart';

class PasswordGeneratorDialog extends StatefulWidget {
  const PasswordGeneratorDialog({super.key});

  @override
  State<PasswordGeneratorDialog> createState() =>
      _PasswordGeneratorDialogState();
}

class _PasswordGeneratorDialogState extends State<PasswordGeneratorDialog> {
  int _length = 20;
  final _lengthInput = TextEditingController(text: '20');
  String? _lengthError;
  final _types = [true, true, true, true];
  bool _excludeAmbiguous = true;
  late String _password = _generate();

  @override
  void dispose() {
    _lengthInput.dispose();
    super.dispose();
  }

  String _generate() => generateArchivePassword(
    length: _length,
    uppercase: _types[0],
    lowercase: _types[1],
    digits: _types[2],
    symbols: _types[3],
    excludeAmbiguous: _excludeAmbiguous,
  );

  void _update(VoidCallback change) => setState(() {
    change();
    _password = _generate();
  });

  void _changeLength(String value) {
    final length = int.tryParse(value);
    setState(() {
      _lengthError = length == null || length < 8 || length > 128
          ? '请输入 8–128 的整数'
          : null;
      if (_lengthError == null) {
        _length = length!;
        _password = _generate();
      }
    });
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _password));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('密码已复制')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final letters = RegExp(r'[a-zA-Z]');
    Widget section(Widget child) => Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
    return AlertDialog(
      title: const Text('随机密码生成器'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              section(
                Row(
                  children: [
                    Expanded(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 120),
                        child: SingleChildScrollView(
                          child: SelectableText.rich(
                            TextSpan(
                              children: [
                                for (final character in _password.split(''))
                                  TextSpan(
                                    text: character,
                                    style: TextStyle(
                                      color: '0123456789'.contains(character)
                                          ? scheme.primary
                                          : letters.hasMatch(character)
                                          ? scheme.onSurface
                                          : scheme.tertiary,
                                    ),
                                  ),
                              ],
                            ),
                            key: const ValueKey('generatedPassword'),
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 20,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: '重新生成',
                      onPressed: () => _update(() {}),
                      icon: const Icon(Icons.refresh),
                    ),
                    IconButton(
                      tooltip: '复制密码',
                      onPressed: _copy,
                      icon: const Icon(Icons.copy_outlined),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              section(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(child: Text('密码长度')),
                        SizedBox(
                          width: 76,
                          child: TextField(
                            key: const ValueKey('passwordLength'),
                            controller: _lengthInput,
                            keyboardType: TextInputType.number,
                            textAlign: TextAlign.center,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(3),
                            ],
                            decoration: const InputDecoration(
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 8,
                              ),
                            ),
                            onChanged: _changeLength,
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: _length.toDouble(),
                      min: 8,
                      max: 128,
                      divisions: 120,
                      label: '$_length',
                      onChanged: (value) => _update(() {
                        _length = value.round();
                        _lengthInput.text = '$_length';
                        _lengthError = null;
                      }),
                    ),
                    Text(
                      _lengthError ?? '8–128 个字符',
                      style: TextStyle(
                        fontSize: 12,
                        color: _lengthError == null
                            ? scheme.onSurfaceVariant
                            : scheme.error,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              section(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('包含字符'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final (index, label) in [
                          'A–Z',
                          'a–z',
                          '0–9',
                          '!@#\$%',
                        ].indexed)
                          SizedBox(
                            width: 110,
                            child: CheckboxListTile(
                              key: ValueKey('passwordType:$index'),
                              contentPadding: EdgeInsets.zero,
                              controlAffinity: ListTileControlAffinity.leading,
                              dense: true,
                              title: Text(label),
                              value: _types[index],
                              onChanged:
                                  _types[index] &&
                                      _types.where((value) => value).length == 1
                                  ? null
                                  : (value) =>
                                        _update(() => _types[index] = value!),
                            ),
                          ),
                      ],
                    ),
                    const Divider(height: 24),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      dense: true,
                      title: const Text('排除易混淆字符'),
                      subtitle: const Text('I、l、o、O、0、1'),
                      value: _excludeAmbiguous,
                      onChanged: (value) =>
                          _update(() => _excludeAmbiguous = value!),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const PasswordHistoryDialog(),
                ),
                icon: const Icon(Icons.history, size: 18),
                label: const Text('压缩包密码历史'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _lengthError == null
              ? () => Navigator.pop(context, _password)
              : null,
          child: const Text('使用此密码'),
        ),
      ],
    );
  }
}
