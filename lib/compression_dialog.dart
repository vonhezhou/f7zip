import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'app_theme.dart';
import 'compression_parameters.dart';
import 'compression_preset.dart';

class CompressionOptions {
  const CompressionOptions(
    this.format,
    this.level,
    this.password, {
    this.volumeSize = 0,
    this.encryption = 'AES256',
    this.encryptNames = true,
    this.parameters = const CompressionParameters(),
  });
  final String format;
  final int level;
  final String password;
  final int volumeSize;
  final String encryption;
  final bool encryptNames;
  final CompressionParameters parameters;
}

class CompressionDialog extends StatefulWidget {
  const CompressionDialog({
    super.key,
    required this.inputs,
    required this.presets,
    required this.defaultPreset,
    required this.onPresetsChanged,
  }) : presetOnly = false,
       initialPreset = null;

  const CompressionDialog.preset({
    super.key,
    required this.presets,
    this.initialPreset,
  }) : inputs = const [],
       defaultPreset = '',
       onPresetsChanged = null,
       presetOnly = true;

  final List<String> inputs;
  final List<CompressionPreset> presets;
  final String defaultPreset;
  final Future<void> Function(List<CompressionPreset>, String)?
  onPresetsChanged;
  final bool presetOnly;
  final CompressionPreset? initialPreset;

  @override
  State<CompressionDialog> createState() => _CompressionDialogState();
}

class _CompressionDialogState extends State<CompressionDialog> {
  String _format = 'zip';
  String _volume = 'none';
  final _customVolume = TextEditingController();
  int? get _volumeSize {
    if (!_supportsVolumes || _volume == 'none') return 0;
    final mib = int.tryParse(
      _volume == 'custom' ? _customVolume.text.trim() : _volume,
    );
    if (mib == null || mib < 1 || mib > 2097151) return null;
    return mib * 1024 * 1024;
  }

  int _level = 5;
  CompressionParameters _parameters = const CompressionParameters();
  String _encryption = 'AES256';
  bool _encryptNames = true;
  final _password = TextEditingController();
  late final _name = TextEditingController(
    text: widget.initialPreset?.name ?? '',
  );
  String? _nameError;
  bool _showPassword = false;
  bool get _supportsPassword =>
      const {'zip', 'zipx', '7z', 'sfx'}.contains(_format);
  bool get _supportsVolumes => const {'zip', 'zipx', '7z'}.contains(_format);
  bool get _singleFileFormat => const {'gz', 'xz', 'bz2'}.contains(_format);
  bool get _validInput =>
      widget.presetOnly ||
      !_singleFileFormat ||
      (widget.inputs.length == 1 && File(widget.inputs.single).existsSync());
  late List<CompressionPreset> _presets;
  late String _defaultPreset;
  String _presetName = '';
  int _presetRevision = 0;
  bool _savingPreset = false;
  String? _presetError;

  @override
  void initState() {
    super.initState();
    _presets = widget.presets.toList();
    _defaultPreset = widget.defaultPreset;
    final initial = widget.presetOnly
        ? widget.initialPreset
        : _presets.where((preset) => preset.name == _defaultPreset).firstOrNull;
    if (initial != null) _loadPreset(initial);
  }

  void _loadPreset(CompressionPreset preset) {
    _presetRevision++;
    _presetName = preset.name;
    _format = preset.format;
    _level = _format == 'wim' ? 0 : preset.level;
    _parameters = preset.parameters.forFormat(_format, _level);
    _encryption = preset.encryption;
    _encryptNames = preset.encryptNames;
    final mib = preset.volumeSize ~/ 1048576;
    _volume = mib == 0
        ? 'none'
        : const {10, 100, 500, 2048}.contains(mib)
        ? '$mib'
        : 'custom';
    _customVolume.text = mib == 0 ? '' : '$mib';
  }

  void _changeOptions(VoidCallback change) {
    setState(() {
      change();
      if (_format == 'wim') _level = 0;
      _parameters = _parameters.forFormat(_format, _level);
      _presetName = '';
    });
  }

  Future<void> _persistPresets(
    List<CompressionPreset> presets,
    String defaultName,
    String selection,
  ) async {
    setState(() {
      _savingPreset = true;
      _presetError = null;
    });
    try {
      await widget.onPresetsChanged!(presets, defaultName);
      if (mounted) {
        setState(() {
          _presets = presets;
          _defaultPreset = defaultName;
          _presetName = selection;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _presetError = '预设保存失败。$error');
    } finally {
      if (mounted) setState(() => _savingPreset = false);
    }
  }

  Future<void> _savePreset() async {
    final result = await showDialog<(String, bool)>(
      context: context,
      builder: (_) => _SaveCompressionPresetDialog(
        initialName: _presetName,
        defaultName: _defaultPreset,
      ),
    );
    if (result == null || !mounted || _volumeSize == null) return;
    final preset = CompressionPreset(
      name: result.$1,
      format: _format,
      level: _level,
      parameters: _parameters,
      volumeSize: _volumeSize!,
      encryption: _encryption,
      encryptNames: _encryptNames,
    );
    final presets = _presets.toList();
    final index = presets.indexWhere((item) => item.name == preset.name);
    if (index < 0) {
      presets.add(preset);
    } else {
      presets[index] = preset;
    }
    final defaultName = result.$2
        ? preset.name
        : _defaultPreset == preset.name
        ? ''
        : _defaultPreset;
    await _persistPresets(presets, defaultName, preset.name);
  }

  Future<void> _deletePreset() async {
    final presets = _presets
        .where((preset) => preset.name != _presetName)
        .toList();
    await _persistPresets(
      presets,
      _defaultPreset == _presetName ? '' : _defaultPreset,
      '',
    );
  }

  void _submitPreset() {
    final name = _name.text.trim();
    if (name.isEmpty || name.length > 40) {
      setState(() => _nameError = '请输入 1–40 个字符的名称');
      return;
    }
    if (widget.presets.any(
      (preset) =>
          preset.name == name && preset.name != widget.initialPreset?.name,
    )) {
      setState(() => _nameError = '预设名称已存在，请编辑已有预设或使用新名称');
      return;
    }
    Navigator.pop(
      context,
      CompressionPreset(
        name: name,
        format: _format,
        level: _level,
        volumeSize: _volumeSize!,
        encryption: _encryption,
        encryptNames: _encryptNames,
        parameters: _parameters,
      ),
    );
  }

  @override
  void dispose() {
    _customVolume.dispose();
    _password.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.presetOnly
          ? (widget.initialPreset == null ? '新建压缩预设' : '编辑压缩预设')
          : '新建压缩包',
    ),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.presetOnly) ...[
              TextField(
                key: const ValueKey('presetName'),
                controller: _name,
                autofocus: true,
                maxLength: 40,
                decoration: InputDecoration(
                  labelText: '预设名称',
                  errorText: _nameError,
                ),
                onChanged: (_) {
                  if (_nameError != null) setState(() => _nameError = null);
                },
              ),
              const SizedBox(height: 12),
            ] else
              Row(
                children: [
                  Expanded(
                    child: InputDecorator(
                      decoration: const InputDecoration(labelText: '压缩预设'),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          key: const ValueKey('compressionPreset'),
                          value: _presetName,
                          isDense: true,
                          isExpanded: true,
                          items: [
                            const DropdownMenuItem(
                              value: '',
                              child: Text('自定义设置'),
                            ),
                            for (final preset in _presets)
                              DropdownMenuItem(
                                value: preset.name,
                                child: Text(
                                  '${preset.name}${preset.name == _defaultPreset ? ' · 默认' : ''}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: _savingPreset
                              ? null
                              : (value) => setState(() {
                                  if (value == '') {
                                    _presetName = '';
                                  } else {
                                    _loadPreset(
                                      _presets.firstWhere(
                                        (preset) => preset.name == value,
                                      ),
                                    );
                                  }
                                }),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    tooltip: '保存压缩预设',
                    onPressed: _savingPreset || _volumeSize == null
                        ? null
                        : _savePreset,
                    icon: const Icon(Icons.bookmark_add_outlined, size: 20),
                  ),
                  IconButton(
                    tooltip: '删除压缩预设',
                    onPressed: _savingPreset || _presetName.isEmpty
                        ? null
                        : _deletePreset,
                    icon: const Icon(Icons.delete_outline, size: 20),
                  ),
                ],
              ),
            if (_presetError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _presetError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 12),
            if (!widget.presetOnly) ...[
              Text(
                '已选择 ${widget.inputs.length} 个文件或文件夹',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.of(context).secondary,
                ),
              ),
              const SizedBox(height: 10),
              Container(
                constraints: const BoxConstraints(maxHeight: 84),
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.of(context).field,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    widget.inputs.map(p.basename).join('\n'),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            Row(
              key: ValueKey('presetFormat:$_presetRevision'),
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _format,
                    key: const ValueKey('compressionFormat'),
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '压缩格式'),
                    items: const [
                      DropdownMenuItem(
                        value: 'zip',
                        child: Text('ZIP · 兼容性优先'),
                      ),
                      DropdownMenuItem(
                        value: 'zipx',
                        child: Text('ZIPX · LZMA 默认'),
                      ),
                      DropdownMenuItem(
                        value: 'sfx',
                        child: Text('Windows 自解压 EXE · x86'),
                      ),
                      DropdownMenuItem(value: 'wim', child: Text('WIM · 仅存储')),
                      DropdownMenuItem(value: '7z', child: Text('7z · 压缩率优先')),
                      DropdownMenuItem(value: 'tar', child: Text('TAR · 仅打包')),
                      DropdownMenuItem(value: 'tar.gz', child: Text('TAR.GZ')),
                      DropdownMenuItem(
                        value: 'tar.bz2',
                        child: Text('TAR.BZ2'),
                      ),
                      DropdownMenuItem(value: 'tar.xz', child: Text('TAR.XZ')),
                      DropdownMenuItem(value: 'gz', child: Text('GZIP · 单文件')),
                      DropdownMenuItem(value: 'xz', child: Text('XZ · 单文件')),
                      DropdownMenuItem(
                        value: 'bz2',
                        child: Text('BZIP2 · 单文件'),
                      ),
                    ],
                    onChanged: _savingPreset
                        ? null
                        : (value) => _changeOptions(() => _format = value!),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    key: ValueKey('compressionLevel:$_format'),
                    initialValue: _level,
                    decoration: const InputDecoration(labelText: '压缩等级'),
                    items: const [
                      DropdownMenuItem(value: 0, child: Text('仅存储')),
                      DropdownMenuItem(value: 1, child: Text('最快')),
                      DropdownMenuItem(value: 5, child: Text('标准')),
                      DropdownMenuItem(value: 7, child: Text('最大')),
                      DropdownMenuItem(value: 9, child: Text('极限')),
                    ],
                    onChanged:
                        _savingPreset || const {'tar', 'wim'}.contains(_format)
                        ? null
                        : (value) => _changeOptions(() => _level = value!),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (const {'zip', 'zipx'}.contains(_format)) ...[
              const Text(
                '文件名编码 · UTF-8（跨平台）',
                key: ValueKey('zipCreationEncoding'),
              ),
              const SizedBox(height: 4),
              const Text(
                '写入 UTF-8 标志，供 Windows、macOS 和 Linux 识别。接收方需使用支持 UTF-8 的解压软件。',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
            ],
            if (_supportsVolumes) ...[
              KeyedSubtree(
                key: ValueKey('presetVolume:$_presetRevision'),
                child: DropdownButtonFormField<String>(
                  key: const ValueKey('volumeSize'),
                  initialValue: _volume,
                  decoration: const InputDecoration(labelText: '分卷大小'),
                  items: const [
                    DropdownMenuItem(value: 'none', child: Text('不分卷')),
                    DropdownMenuItem(value: '10', child: Text('10 MiB')),
                    DropdownMenuItem(value: '100', child: Text('100 MiB')),
                    DropdownMenuItem(value: '500', child: Text('500 MiB')),
                    DropdownMenuItem(value: '2048', child: Text('2 GiB')),
                    DropdownMenuItem(value: 'custom', child: Text('自定义')),
                  ],
                  onChanged: _savingPreset
                      ? null
                      : (value) => _changeOptions(() => _volume = value!),
                ),
              ),
              if (_volume == 'custom') ...[
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('customVolumeSize'),
                  enabled: !_savingPreset,
                  controller: _customVolume,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => _changeOptions(() {}),
                  decoration: InputDecoration(
                    labelText: '每卷大小（MiB）',
                    errorText: _volumeSize == null ? '请输入 1–2097151 的整数' : null,
                  ),
                ),
              ],
              if (_volume != 'none')
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('生成 .001、.002 等数字分卷，请保留整组文件。'),
                ),
              const SizedBox(height: 12),
            ],
            if (_supportsPassword && !widget.presetOnly)
              TextField(
                key: const ValueKey('compressionPassword'),
                controller: _password,
                obscureText: !_showPassword,
                decoration: InputDecoration(
                  labelText: '密码（可选）',
                  hintText: '留空则不加密',
                  suffixIcon: IconButton(
                    onPressed: () =>
                        setState(() => _showPassword = !_showPassword),
                    icon: Icon(
                      _showPassword
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 18,
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            if (const {'zip', 'zipx'}.contains(_format))
              DropdownButtonFormField<String>(
                key: ValueKey('presetEncryption:$_presetRevision'),
                initialValue: _encryption,
                decoration: const InputDecoration(labelText: '加密算法'),
                items: const [
                  DropdownMenuItem(value: 'AES256', child: Text('AES-256')),
                  DropdownMenuItem(
                    value: 'ZipCrypto',
                    child: Text('ZipCrypto · 兼容旧解压工具'),
                  ),
                ],
                onChanged: _savingPreset
                    ? null
                    : (value) => _changeOptions(() => _encryption = value!),
              ),
            if (const {'7z', 'sfx'}.contains(_format))
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('同时加密文件名'),
                value: _encryptNames,
                onChanged: _savingPreset
                    ? null
                    : (value) => _changeOptions(() => _encryptNames = value!),
              ),
            if (_format != 'tar')
              ExpansionTile(
                key: ValueKey('advanced:$_format:$_level:$_presetRevision'),
                tilePadding: EdgeInsets.zero,
                title: const Text('高级压缩参数'),
                children: [
                  DropdownButtonFormField<String>(
                    key: ValueKey('compressionMethod:${_parameters.method}'),
                    initialValue: _parameters.method,
                    decoration: const InputDecoration(labelText: '压缩算法'),
                    items: [
                      for (final method in CompressionParameters.methodsFor(
                        _format,
                      ))
                        DropdownMenuItem(
                          value: method,
                          child: Text(
                            method == 'auto'
                                ? '自动（${_parameters.effectiveMethod(_format, _level)}）'
                                : method,
                          ),
                        ),
                    ],
                    onChanged: _savingPreset || _level == 0
                        ? null
                        : (value) => _changeOptions(
                            () => _parameters = CompressionParameters(
                              method: value!,
                              dictionaryMiB: _parameters.dictionaryMiB,
                              threads: _parameters.threads,
                              solidMiB: _parameters.solidMiB,
                            ),
                          ),
                  ),
                  if (_parameters.supportsDictionary(_format, _level)) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      key: ValueKey(
                        'compressionDictionary:${_parameters.dictionaryMiB}',
                      ),
                      initialValue: _parameters.dictionaryMiB,
                      decoration: const InputDecoration(labelText: '字典大小'),
                      items: [
                        for (final size in CompressionParameters.dictionaries)
                          DropdownMenuItem(
                            value: size,
                            child: Text(size == 0 ? '自动' : '$size MiB'),
                          ),
                      ],
                      onChanged: _savingPreset
                          ? null
                          : (value) => _changeOptions(
                              () => _parameters = CompressionParameters(
                                method: _parameters.method,
                                dictionaryMiB: value!,
                                threads: _parameters.threads,
                                solidMiB: _parameters.solidMiB,
                              ),
                            ),
                    ),
                  ],
                  if (_parameters.supportsSolid(_format, _level)) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      key: ValueKey('compressionSolid:${_parameters.solidMiB}'),
                      initialValue: _parameters.solidMiB,
                      decoration: const InputDecoration(labelText: '固实块大小'),
                      items: [
                        for (final size in CompressionParameters.solidBlocks)
                          DropdownMenuItem(
                            value: size,
                            child: Text(
                              size == -1
                                  ? '默认（关闭）'
                                  : size == 0
                                  ? '关闭固实压缩'
                                  : '$size MiB',
                            ),
                          ),
                      ],
                      onChanged: _savingPreset
                          ? null
                          : (value) => _changeOptions(
                              () => _parameters = CompressionParameters(
                                method: _parameters.method,
                                dictionaryMiB: _parameters.dictionaryMiB,
                                threads: _parameters.threads,
                                solidMiB: value!,
                              ),
                            ),
                    ),
                  ],
                  if (CompressionParameters.supportsThreads(_format)) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      key: ValueKey(
                        'compressionThreads:${_parameters.threads}',
                      ),
                      initialValue: _parameters.threads,
                      decoration: const InputDecoration(labelText: '线程上限'),
                      items: [
                        const DropdownMenuItem(value: 0, child: Text('自动')),
                        for (var count = 1; count <= 64; count++)
                          DropdownMenuItem(value: count, child: Text('$count')),
                      ],
                      onChanged: _savingPreset
                          ? null
                          : (value) => _changeOptions(
                              () => _parameters = CompressionParameters(
                                method: _parameters.method,
                                dictionaryMiB: _parameters.dictionaryMiB,
                                threads: value!,
                                solidMiB: _parameters.solidMiB,
                              ),
                            ),
                    ),
                  ],
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      '本机 ${Platform.numberOfProcessors} 个逻辑处理器。实际并行度由算法和输入决定。\n'
                      '${_parameters.dictionaryMiB == 0
                          ? '内存由引擎按等级和算法自动选择。'
                          : _parameters.effectiveMethod(_format, _level) == 'PPMd'
                          ? '每个编码器至少需要 ${_parameters.dictionaryMiB} MiB 模型内存。'
                          : '每个 LZMA 编码器粗估需 ${_parameters.dictionaryMiB * 12 + 64} MiB 内存。'}'
                      ' 多个编码器会增加总内存，实际占用还受文件和引擎缓冲影响。',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 12),
            Text(
              widget.presetOnly
                  ? '压缩预设保存格式、等级、分卷及高级参数。密码在每次创建任务中按需输入。'
                  : !_validInput
                  ? '此格式需要选择一个普通文件。多个文件或文件夹可选择 ZIP、7z 或 TAR。'
                  : switch (_format) {
                      '7z' => '7z 使用 AES-256。填写密码后启用加密。',
                      'zip' => '填写密码后启用所选加密算法。ZIP 密码请使用 ASCII 字符。',
                      'sfx' => '生成供 Windows x86 运行的单个 EXE，可用于支持 32 位程序的 x64 系统。普通解压模块在解压完成后结束，包内文件的可信度由来源决定。生成包未签名，Windows 安全策略可能提示或阻止运行。',
                      'wim' => 'WIM 使用引擎支持的存储方式，不支持密码和分卷；用于数据归档。',
                      'tar' => 'TAR 保留目录结构，仅打包，不进行压缩。',
                      'tar.gz' ||
                      'tar.bz2' ||
                      'tar.xz' => '先打包为 TAR，再压缩，保留目录结构。',
                      _ => '压缩单个文件，保留文件内容。',
                    },
              style: TextStyle(
                fontSize: 11,
                color: _validInput
                    ? AppColors.of(context).secondary
                    : Theme.of(context).colorScheme.error,
              ),
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
        onPressed: _savingPreset || !_validInput || _volumeSize == null
            ? null
            : widget.presetOnly
            ? _submitPreset
            : () => Navigator.pop(
                context,
                CompressionOptions(
                  _format,
                  _level,
                  _supportsPassword ? _password.text : '',
                  parameters: _parameters,
                  volumeSize: _volumeSize!,
                  encryption: _encryption,
                  encryptNames: _encryptNames,
                ),
              ),
        child: Text(widget.presetOnly ? '保存预设' : '选择保存位置'),
      ),
    ],
  );
}

class _SaveCompressionPresetDialog extends StatefulWidget {
  const _SaveCompressionPresetDialog({
    required this.initialName,
    required this.defaultName,
  });
  final String initialName;
  final String defaultName;
  @override
  State<_SaveCompressionPresetDialog> createState() =>
      _SaveCompressionPresetDialogState();
}

class _SaveCompressionPresetDialogState
    extends State<_SaveCompressionPresetDialog> {
  late final _name = TextEditingController(text: widget.initialName);
  late bool _default =
      widget.initialName.isNotEmpty && widget.initialName == widget.defaultName;
  bool _defaultTouched = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty || name.length > 40) {
      setState(() => _error = '请输入 1–40 个字符的名称');
      return;
    }
    Navigator.pop(context, (name, _default));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('保存压缩预设'),
    content: SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey('presetName'),
            controller: _name,
            autofocus: true,
            decoration: InputDecoration(
              labelText: '预设名称',
              helperText: '相同名称会更新已有预设',
              errorText: _error,
            ),
            onSubmitted: (_) => _submit(),
            onChanged: (value) {
              if (!_defaultTouched) {
                setState(
                  () => _default =
                      value.trim().isNotEmpty &&
                      value.trim() == widget.defaultName,
                );
              }
            },
          ),
          CheckboxListTile(
            key: const ValueKey('presetDefault'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('设为默认预设'),
            value: _default,
            onChanged: (value) => setState(() {
              _default = value!;
              _defaultTouched = true;
            }),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: const Text('保存预设')),
    ],
  );
}
