import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'archive_engine.dart';
import 'archive_drag.dart';
import 'archive_tree.dart';
import 'app_settings.dart';
import 'edit_workspace.dart';
import 'app_theme.dart';
import 'compression_preset.dart';

const _desktop = MethodChannel('sevenzip/desktop');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const F7ZipApp());
}

class F7ZipApp extends StatefulWidget {
  const F7ZipApp({super.key});
  @override
  State<F7ZipApp> createState() => _F7ZipAppState();
}

class _F7ZipAppState extends State<F7ZipApp> {
  ThemeMode _themeMode = ThemeMode.system;
  AppColorTheme _colorTheme = AppColorTheme.purple;

  void _applySettings(AppSettings settings) {
    if (_themeMode != settings.themeMode ||
        _colorTheme != settings.colorTheme) {
      setState(() {
        _themeMode = settings.themeMode;
        _colorTheme = settings.colorTheme;
      });
    }
    _desktop.invokeMethod<void>('setAppearance', settings.themeMode.name);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'F7Zip',
    debugShowCheckedModeBanner: false,
    theme: buildAppTheme(Brightness.light, colorTheme: _colorTheme),
    darkTheme: buildAppTheme(Brightness.dark, colorTheme: _colorTheme),
    themeMode: _themeMode,
    home: ArchiveWindow(onSettingsChanged: _applySettings),
  );
}

class ArchiveWindow extends StatefulWidget {
  const ArchiveWindow({super.key, this.onSettingsChanged});
  final ValueChanged<AppSettings>? onSettingsChanged;
  @override
  State<ArchiveWindow> createState() => _ArchiveWindowState();
}

class _ArchiveWindowState extends State<ArchiveWindow> {
  ArchiveEngine? _engine;
  String? _engineError;
  String? _archive;
  String _password = '';
  int _archiveCodePage = 0;
  int _volumeCount = 1;
  String _archiveVersion = '';
  String _archiveComment = '';
  bool _editable = false;
  bool _openingFile = false;
  bool _mutating = false;
  String _sortColumn = 'name';
  bool _sortAscending = true;
  bool _showTree = true;
  static const _fileRowHeight = 28.0;
  double _treeWidth = 200;
  final List<String> _navigation = [''];
  int _navigationIndex = 0;
  bool _desktopReady = false;
  AppSettings _preferences = const AppSettings();
  EditWorkspace? _edits;
  String? _workspaceError;
  String _folder = '';
  String _query = '';
  String _status = '准备就绪';
  String _task = '';
  String _currentFile = '';
  String? _lastOutput;
  double? _progress;
  bool _busy = false;
  bool _choosing = false;
  bool _dragging = false;
  bool _cancelling = false;
  List<ArchiveEntry> _entries = [];
  ArchiveTreeNode _tree = buildArchiveTree([]);
  final List<Map<String, dynamic>> _finderRequests = [];
  Timer? _finderTimer;
  bool _handlingFinderRequest = false;
  final Set<String> _selected = {};
  final List<String> _recent = [];
  final _search = TextEditingController();
  final _fileList = ScrollController();
  Timer? _timer;
  final Map<String, _ArchiveDragSession> _dragSessions = {};
  Future<void> _dragExports = Future.value();
  Completer<void>? _activeOperation;
  String? _activeDragId;
  int _pendingDragWrites = 0;
  bool _exportingDrag = false;

  bool get _engineAvailable =>
      _desktopReady && !_busy && !_choosing && _engine != null;
  bool get _available => _engineAvailable && !_exportingDrag;

  bool get _interactive => _available && !_openingFile && !_mutating;

  @override
  void initState() {
    super.initState();
    try {
      _engine = ArchiveEngine();
    } catch (error) {
      _engineError = '$error';
    }
    _desktop.setMethodCallHandler((call) async {
      if (call.method == 'writeArchivePromise') {
        return _writeArchivePromise(call.arguments as Map);
      }
      if (call.method == 'archiveDragEnded') {
        _endArchiveDrag(call.arguments as Map);
      }
      if (call.method == 'showSettings') await _showSettings();
      if (call.method == 'archiveCommand') {
        await _command(call.arguments as String);
      }
      if (call.method == 'finderRequest') {
        _enqueueFinderRequest(Map<String, dynamic>.from(call.arguments as Map));
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final requests =
          await _desktop.invokeListMethod<dynamic>('takeFinderRequests') ?? [];
      if (!mounted) return;
      for (final request in requests) {
        _enqueueFinderRequest(Map<String, dynamic>.from(request as Map));
      }
      try {
        final preferences = await _desktop.invokeMapMethod<dynamic, dynamic>(
          'loadSettings',
        );
        if (!mounted) return;
        setState(() => _preferences = AppSettings.fromJson(preferences ?? {}));
        widget.onSettingsChanged?.call(_preferences);
        final recent =
            await _desktop.invokeListMethod<String>('recentArchives') ?? [];
        if (!mounted) return;
        setState(
          () => _recent.addAll(recent.where((path) => !_recent.contains(path))),
        );
        final directory = await _desktop.invokeMethod<String>(
          'workspaceDirectory',
        );
        if (directory != null && mounted) {
          final workspace = EditWorkspace(
            root: Directory(directory),
            canUpdate: () =>
                mounted &&
                _available &&
                !_openingFile &&
                !_mutating &&
                !_handlingFinderRequest &&
                !Navigator.of(context).canPop(),
            update: _writeBack,
            onChanged: () {
              if (mounted) setState(() {});
            },
          );
          await workspace.restore();
          if (!mounted) {
            workspace.close();
            return;
          }
          setState(() => _edits = workspace);
        }
      } catch (error) {
        if (mounted) setState(() => _workspaceError = '$error');
      }
      if (!mounted) return;
      setState(() => _desktopReady = true);
      _processFinderRequests();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _finderTimer?.cancel();
    _edits?.close();
    _engine?.cancel();
    for (final session in _dragSessions.values) {
      session.cancelled = true;
      session.expiry?.cancel();
    }
    _dragSessions.clear();
    _search.dispose();
    _fileList.dispose();
    _desktop.setMethodCallHandler(null);
    super.dispose();
  }

  void _enqueueFinderRequest(Map<String, dynamic> request) {
    if (!mounted) return;
    _finderRequests.add(request);
    _finderTimer ??= Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => _processFinderRequests(),
    );
    _processFinderRequests();
  }

  Future<void> _processFinderRequests() async {
    if (!mounted ||
        _handlingFinderRequest ||
        _openingFile ||
        _mutating ||
        !_available ||
        Navigator.of(context).canPop()) {
      return;
    }
    _handlingFinderRequest = true;
    try {
      while (mounted &&
          _finderRequests.isNotEmpty &&
          _available &&
          !Navigator.of(context).canPop()) {
        final request = _finderRequests.removeAt(0);
        final paths = (request['paths'] as List).cast<String>();
        try {
          switch (request['action']) {
            case 'compress':
              await _create(paths);
              break;
            case 'compressZip':
              await _finderCompressZip(paths);
              break;
            case 'extractHere':
            case 'extractTo':
              await _finderExtract(
                paths,
                chooseFolder: request['action'] == 'extractTo',
              );
              break;
            case 'extract':
              for (final path in paths) {
                if (!mounted || !await _open(path)) break;
                await _extract(besideArchive: true);
              }
              break;
            case 'open':
              for (final path in paths) {
                if (!mounted || !await _open(path)) break;
              }
              break;
          }
        } catch (error) {
          if (const [
            'compressZip',
            'extractHere',
            'extractTo',
          ].contains(request['action'])) {
            await _desktop.invokeMethod<void>('finderError', '$error');
          } else {
            await _error(error);
          }
        }
      }
    } finally {
      _handlingFinderRequest = false;
      if (_finderRequests.isEmpty) {
        _finderTimer?.cancel();
        _finderTimer = null;
      }
    }
  }

  Future<void> _finderCompressZip(List<String> paths) async {
    if (paths.isEmpty) return;
    final parent = p.dirname(paths.first);
    final name = paths.length == 1 ? p.basename(paths.first) : 'Archive';
    var destination = p.join(parent, '$name.zip');
    var suffix = 2;
    while (FileSystemEntity.typeSync(destination, followLinks: false) !=
        FileSystemEntityType.notFound) {
      destination = p.join(parent, '$name ($suffix).zip');
      suffix++;
    }
    final result = await _run(
      '压缩',
      ArchiveRequest('compress', destination, inputs: paths),
    );
    if (result != null && mounted) {
      setState(() {
        _lastOutput = destination;
        _status = '压缩完成 · $destination';
      });
    }
  }

  Future<void> _finderExtract(
    List<String> paths, {
    required bool chooseFolder,
  }) async {
    final parent = chooseFolder
        ? await _desktop.invokeMethod<String>('finderChooseFolder')
        : null;
    if (chooseFolder && parent == null) return;
    for (final path in paths) {
      var password = '';
      while (mounted) {
        try {
          final result = await _runExtraction(
            path,
            chooseFolder && _preferences.smartExtraction
                ? _extractionDestination(parent!, path)
                : parent ?? p.dirname(path),
            password: password,
            codePage: _preferences.filenameEncoding.codePage,
            intoExisting: true,
            finder: true,
            smartDestination: chooseFolder && _preferences.smartExtraction,
          );
          if (result == null || !mounted) return;
          setState(() {
            _lastOutput = result['path'] as String;
            _status = '解压完成 · ${p.basename(path)}';
          });
          break;
        } on ArchiveFailure catch (error) {
          if (!error.passwordRequired) rethrow;
          final value = await _desktop.invokeMethod<String>('finderPassword', {
            'path': path,
            if (password.isNotEmpty)
              'error': '密码错误或加密数据损坏，请重新输入。\n${p.basename(path)}',
          });
          if (value == null || !mounted) return;
          password = value;
        }
      }
    }
  }

  Future<List<String>> _choose(String method) async {
    if (!_available) return [];
    setState(() => _choosing = true);
    try {
      return await _desktop.invokeListMethod<String>(method) ?? [];
    } finally {
      if (mounted) setState(() => _choosing = false);
    }
  }

  Future<Map<String, dynamic>?> _run(
    String task,
    ArchiveRequest request, {
    bool dragExport = false,
  }) async {
    if (!_engineAvailable || (_exportingDrag && !dragExport)) return null;
    final operation = Completer<void>();
    _activeOperation = operation;
    setState(() {
      _busy = true;
      _cancelling = false;
      _task = task;
      _currentFile = '';
      _progress = null;
      _status = task;
    });
    _timer = Timer.periodic(const Duration(milliseconds: 150), (_) {
      final value = _engine?.progress();
      if (!mounted || value == null) return;
      final total = value['total'] as int;
      final completed = value['completed'] as int;
      setState(() {
        _progress = total == 0 ? null : (completed / total).clamp(0.0, 1.0);
        _currentFile = value['file'] as String;
      });
    });
    try {
      final result = await _engine!.run(request);
      if (mounted) setState(() => _status = '$task完成');
      return result;
    } on ArchiveFailure catch (error) {
      if (mounted) setState(() => _status = error.cancelled ? '操作已取消' : '操作失败');
      if (!error.cancelled) rethrow;
      return null;
    } finally {
      _timer?.cancel();
      if (mounted) setState(() => _busy = false);
      _activeOperation = null;
      operation.complete();
    }
  }

  Future<void> _startArchiveDrag(_VisibleEntry row) async {
    if (!_interactive || row.dotEntry || _archive == null) return;
    final selection = _selected.contains(row.path) ? _selected : {row.path};
    final items = buildArchiveDragItems(_entries, selection);
    if (items.isEmpty) return;
    final id = '${DateTime.now().microsecondsSinceEpoch}';
    final session = _ArchiveDragSession(
      id: id,
      archive: _archive!,
      version: _archiveVersion,
      password: _password,
      codePage: _archiveCodePage,
      items: items,
    );
    _dragSessions[id] = session;
    try {
      await _desktop.invokeMethod<void>('startArchiveDrag', {
        'session': id,
        'items': items.map((item) => item.toJson()).toList(),
      });
    } catch (error) {
      _dragSessions.remove(id);
      session.expiry?.cancel();
      if (mounted) await _error(error);
    }
  }

  void _endArchiveDrag(Map<dynamic, dynamic> arguments) {
    final session = _dragSessions[arguments['session']];
    if (session == null) return;
    session.ended = true;
    if (arguments['cancelled'] == true) {
      session.cancelled = true;
      if (_activeDragId == session.id) _engine?.cancel();
    }
    _releaseArchiveDrag(session);
  }

  void _releaseArchiveDrag(_ArchiveDragSession session) {
    if (!session.ended || session.claimed.isNotEmpty) return;
    session.expiry?.cancel();
    if (session.cancelled || session.remaining.isEmpty) {
      _dragSessions.remove(session.id);
    } else {
      session.expiry = Timer(const Duration(minutes: 5), () {
        if (session.claimed.isEmpty) _dragSessions.remove(session.id);
      });
    }
  }

  Future<Map<String, dynamic>> _writeArchivePromise(
    Map<dynamic, dynamic> arguments,
  ) {
    final session = _dragSessions[arguments['session']];
    final itemId = arguments['item'];
    final destination = arguments['destination'];
    final item = session?.items[itemId];
    if (session == null ||
        item == null ||
        destination is! String ||
        !p.isAbsolute(destination) ||
        session.cancelled ||
        !session.remaining.contains(itemId) ||
        !session.claimed.add(itemId as String)) {
      throw PlatformException(code: 'drag', message: '拖出请求已失效，请重新拖动');
    }
    _pendingDragWrites++;
    setState(() => _exportingDrag = true);
    final next = _dragExports.then(
      (_) => _exportArchivePromise(session, item, destination),
    );
    _dragExports = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return next;
  }

  Future<Map<String, dynamic>> _exportArchivePromise(
    _ArchiveDragSession session,
    ArchiveDragItem item,
    String destination,
  ) async {
    try {
      await _activeOperation?.future;
      if (!mounted || session.cancelled) {
        throw const ArchiveFailure('拖出已取消', cancelled: true);
      }
      _activeDragId = session.id;
      while (mounted && !session.cancelled) {
        if (item.encrypted && session.password.isEmpty) {
          final password = await _desktop.invokeMethod<String>(
            'finderPassword',
            {'path': session.archive},
          );
          if (password == null) {
            throw const ArchiveFailure('拖出已取消', cancelled: true);
          }
          session.password = password;
        }
        try {
          final result = await _run(
            '拖出解压',
            ArchiveRequest(
              'export',
              session.archive,
              destination: destination,
              itemPath: item.path,
              expectedVersion: session.version,
              password: session.password,
              codePage: session.codePage,
              indices: item.indices,
            ),
            dragExport: true,
          );
          if (result == null) {
            throw const ArchiveFailure('拖出已取消', cancelled: true);
          }
          if (mounted) {
            setState(() {
              _lastOutput = result['path'] as String;
              _status = '拖出完成 · ${item.name}';
            });
          }
          return {'ok': true};
        } on ArchiveFailure catch (error) {
          if (!error.passwordRequired) rethrow;
          final password = await _desktop.invokeMethod<String>(
            'finderPassword',
            {'path': session.archive, 'error': '密码错误，请重新输入。'},
          );
          if (password == null) {
            throw const ArchiveFailure('拖出已取消', cancelled: true);
          }
          session.password = password;
        }
      }
      throw const ArchiveFailure('拖出已取消', cancelled: true);
    } catch (error) {
      if (error is ArchiveFailure && error.cancelled) session.cancelled = true;
      if (mounted) setState(() => _status = '拖出未完成 · $error');
      throw PlatformException(
        code: session.cancelled ? 'cancelled' : 'drag',
        message: '$error',
      );
    } finally {
      _activeDragId = null;
      session.claimed.remove(item.id);
      session.remaining.remove(item.id);
      _pendingDragWrites--;
      if (mounted) setState(() => _exportingDrag = _pendingDragWrites > 0);
      _releaseArchiveDrag(session);
    }
  }

  Future<void> _error(Object error) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('操作未完成'),
        content: SelectableText('$error'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _openDialog() async {
    final paths = await _choose('openArchive');
    if (paths.isNotEmpty) await _open(paths.first);
  }

  Future<String?> _askPassword({String? error}) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('压缩包密码'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    '打开失败。若文件已加密，请输入密码重试。\n$error',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              TextField(
                controller: controller,
                autofocus: true,
                obscureText: true,
                decoration: const InputDecoration(labelText: '密码'),
                onSubmitted: (value) => Navigator.pop(context, value),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    // 等待对话框退场，避免动画期间仍访问已释放的 controller。
    Future<void>.delayed(const Duration(seconds: 1), controller.dispose);
    return result;
  }

  Future<bool> _open(String path, {String password = ''}) async {
    if (!_interactive) return false;
    if (!await File(path).exists()) {
      await _error('压缩包不存在或已被移动。\n$path');
      return false;
    }
    try {
      final sessions =
          _edits?.sessions
              .where((session) => session.archive == path)
              .toList() ??
          [];
      final requested = _preferences.filenameEncoding.codePage;
      final requestedCodePage = requested == 0 && sessions.isNotEmpty
          ? sessions.first.codePage
          : requested;
      final result = await _run(
        '读取压缩包',
        ArchiveRequest(
          'list',
          path,
          password: password,
          codePage: requestedCodePage,
        ),
      );
      if (result == null || !mounted) return false;
      final codePage = result['codePage'] as int? ?? 0;
      if (_edits?.sessions.any(
            (session) =>
                session.archive == path &&
                session.codePage != 0 &&
                session.codePage != codePage,
          ) ??
          false) {
        await _error('此压缩包仍有外部编辑会话，请结束监控后再切换文件名编码');
        return false;
      }
      final items = (result['items'] as List)
          .map((item) => ArchiveEntry.fromJson(item as Map<String, dynamic>))
          .toList();
      setState(() {
        _archive = path;
        _archiveCodePage = codePage;
        _volumeCount = result['volumes'] as int? ?? 1;
        _password = password;
        _archiveVersion = result['version'] as String;
        _archiveComment = result['comment'] as String? ?? '';
        _editable = result['editable'] == true;
        _entries = items;
        _tree = buildArchiveTree(items);
        _folder = '';
        _navigation
          ..clear()
          ..add('');
        _navigationIndex = 0;
        _query = '';
        _search.clear();
        _selected.clear();
        _recent.remove(path);
        _recent.insert(0, path);
        if (_recent.length > 8) _recent.removeLast();
        _status = '已打开 ${p.basename(path)}';
      });
      unawaited(_desktop.invokeMethod<void>('rememberArchive', path));
      unawaited(_desktop.invokeMethod<void>('setArchiveTitle', path));
      return true;
    } catch (error) {
      if (!mounted) return false;
      if (error is ArchiveFailure &&
          error.volumeError &&
          !error.passwordRequired) {
        await _error(error);
        return false;
      }
      final retry = await _askPassword(error: '$error');
      if (retry != null && retry.isNotEmpty && mounted) {
        return _open(path, password: retry);
      }
      return false;
    }
  }

  Future<void> _extract({
    bool selectedOnly = false,
    bool besideArchive = false,
  }) async {
    final archive = _archive;
    if (!_interactive ||
        archive == null ||
        (selectedOnly && _selected.isEmpty)) {
      return;
    }
    var password = _password;
    if (password.isEmpty && _entries.any((entry) => entry.encrypted)) {
      final value = await _askPassword();
      if (value == null || !mounted) return;
      password = value;
    }
    String parent;
    if (besideArchive) {
      parent = p.dirname(archive);
    } else {
      final paths = await _choose('chooseFolder');
      if (paths.isEmpty) return;
      parent = paths.first;
    }
    if (!mounted || !_available) return;
    final destination = _extractionDestination(parent, archive);
    final indices = selectedOnly
        ? _entries
              .where((entry) => entry.isSelectedBy(_selected))
              .map((entry) => entry.index)
              .toList()
        : <int>[];
    try {
      final result = await _runExtraction(
        archive,
        destination,
        password: password,
        codePage: _archiveCodePage,
        indices: indices,
        intoExisting: Directory(destination).existsSync(),
        smartDestination: _preferences.smartExtraction,
      );
      if (result != null && mounted) {
        setState(() {
          _password = password;
          _lastOutput = result['path'] as String;
          _status = '解压完成 · $_lastOutput';
        });
      }
    } catch (error) {
      await _error(error);
    }
  }

  Future<Map<String, dynamic>?> _runExtraction(
    String archive,
    String destination, {
    required String password,
    required int codePage,
    required bool intoExisting,
    bool finder = false,
    bool smartDestination = false,
    List<int> indices = const [],
  }) async {
    var policy = ExtractionPolicy.fail;
    var expectedVersion = '';
    while (mounted) {
      try {
        return await _run(
          '解压',
          ArchiveRequest(
            smartDestination
                ? 'extractSmart'
                : intoExisting
                ? 'extractHere'
                : 'extract',
            archive,
            destination: destination,
            removeRedundantRoot: _preferences.removeRedundantRoot,
            password: password,
            codePage: codePage,
            indices: indices,
            extractionPolicy: policy,
            expectedDestinationVersion: expectedVersion,
          ),
        );
      } on ArchiveFailure catch (error) {
        if (error.conflicts.isEmpty || !mounted) rethrow;
        ExtractionPolicy? choice;
        if (finder) {
          final value = await _desktop.invokeMethod<String>(
            'finderExtractionConflict',
            {'paths': error.conflicts, 'destination': destination},
          );
          choice = ExtractionPolicy.values
              .where((item) => item.name == value)
              .firstOrNull;
        } else {
          choice = await showDialog<ExtractionPolicy>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('解压目标存在同名项目'),
              content: SizedBox(
                width: 420,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('以下 ${error.conflicts.length} 个项目已存在。选择的方式应用于本次解压。'),
                      const SizedBox(height: 8),
                      Text(error.conflicts.take(8).join('\n')),
                      const SizedBox(height: 12),
                      for (final option in [
                        (ExtractionPolicy.skip, '跳过同名文件', '合并文件夹，保留已有同名项目'),
                        (ExtractionPolicy.rename, '自动改名', '为同名文件或文件夹添加递增编号'),
                        (ExtractionPolicy.merge, '合并目录', '保留目录内其他内容，文件重名时再次询问'),
                        (
                          ExtractionPolicy.overwrite,
                          '替换同名文件',
                          '合并文件夹，仅替换普通文件，需再次确认',
                        ),
                      ])
                        ListTile(
                          key: ValueKey('extractionPolicy:${option.$1.name}'),
                          dense: true,
                          title: Text(option.$2),
                          subtitle: Text(option.$3),
                          onTap: () => Navigator.pop(context, option.$1),
                        ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消解压'),
                ),
              ],
            ),
          );
          if (choice == ExtractionPolicy.overwrite && mounted) {
            final confirmed = await _confirm(
              '替换已有文件？',
              '本次解压中同名的普通文件将被替换。文件夹会合并，其他文件会保留。',
            );
            if (!confirmed) choice = null;
          }
        }
        if (choice == null || choice == ExtractionPolicy.fail || !mounted) {
          if (mounted) setState(() => _status = '解压已取消');
          return null;
        }
        policy = choice;
        expectedVersion = error.destinationVersion;
      }
    }
    return null;
  }

  Future<void> _test() async {
    if (!_interactive || _archive == null) return;
    var password = _password;
    if (password.isEmpty && _entries.any((entry) => entry.encrypted)) {
      final value = await _askPassword();
      if (value == null || !mounted) return;
      password = value;
    }
    try {
      final result = await _run(
        '完整性测试',
        ArchiveRequest(
          'test',
          _archive!,
          password: password,
          codePage: _archiveCodePage,
        ),
      );
      if (result != null && mounted) {
        setState(() {
          _password = password;
          _status = '测试通过，压缩包中的文件完整';
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('测试通过，压缩包中的文件完整')));
      }
    } catch (error) {
      await _error(error);
    }
  }

  Future<void> _saveCompressionPresets(
    List<CompressionPreset> presets,
    String defaultName,
  ) async {
    final settings = _preferences.withCompressionPresets(presets, defaultName);
    await _desktop.invokeMethod<void>('saveSettings', settings.toJson());
    if (mounted) setState(() => _preferences = settings);
  }

  Future<void> _create([List<String>? dropped]) async {
    if (!_interactive) return;
    final inputs = dropped ?? await _choose('chooseInputs');
    if (inputs.isEmpty || !mounted) return;
    final options = await showDialog<_CompressionOptions>(
      context: context,
      builder: (_) => _CompressionDialog(
        inputs: inputs,
        settings: _preferences,
        onPresetsChanged: _saveCompressionPresets,
      ),
    );
    if (options == null || !mounted || !_available) return;
    setState(() => _choosing = true);
    String? destination;
    try {
      destination = await _desktop.invokeMethod<String>(
        'saveArchive',
        '${p.basenameWithoutExtension(inputs.first)}.${options.format}',
      );
    } finally {
      if (mounted) setState(() => _choosing = false);
    }
    if (destination == null || !mounted) return;
    if (!destination.toLowerCase().endsWith('.${options.format}')) {
      destination += '.${options.format}';
    }
    try {
      final result = await _run(
        '压缩',
        ArchiveRequest(
          'compress',
          destination,
          inputs: inputs,
          format: options.format == 'zip' && options.encryption == 'AES256'
              ? 'zip-aes256'
              : options.format == '7z' && !options.encryptNames
              ? '7z-visible'
              : options.format,
          level: options.level,
          volumeSize: options.volumeSize,
          password: options.password,
        ),
      );
      if (result == null || !mounted) return;
      final output = result['path'] as String;
      _lastOutput = output;
      await _open(output, password: options.password);
    } catch (error) {
      await _error(error);
    }
  }

  Future<void> _drop(List<String> paths) async {
    if (!_available || paths.isEmpty) return;
    final extension = p.extension(paths.first).toLowerCase();
    if (paths.length == 1 &&
        (const [
              '.zip',
              '.7z',
              '.rar',
              '.tar',
              '.gz',
              '.xz',
              '.bz2',
              '.iso',
              '.tgz',
              '.tbz',
              '.tbz2',
              '.txz',
              '.zst',
              '.001',
              '.cab',
              '.dmg',
            ].contains(extension) ||
            RegExp(r'^\.(?:z\d{2,}|r\d{2,}|\d{3,})$').hasMatch(extension))) {
      await _open(paths.first);
    } else if (_archive != null && _editable) {
      await _addFiles(paths);
    } else {
      await _create(paths);
    }
  }

  bool _editingTargets(Iterable<String> paths) {
    for (final session in _edits?.sessions ?? <EditSession>[]) {
      if (session.archive != _archive) continue;
      final path = p.posix.normalize(session.itemPath.replaceAll('\\', '/'));
      if (paths.any(
        (selected) => path == selected || path.startsWith('$selected/'),
      )) {
        return true;
      }
    }
    return false;
  }

  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SizedBox(width: 410, child: Text(message)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确定'),
            ),
          ],
        ),
      ) ??
      false;

  Future<String?> _askName(String title, String initial) async {
    final controller = TextEditingController(text: initial);
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: initial.length,
    );
    String? error;
    final name = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, refresh) {
          void submit() {
            final value = controller.text;
            if (value.trim().isEmpty ||
                value == '.' ||
                value == '..' ||
                value.contains(RegExp(r'[/\\\x00]'))) {
              refresh(() => error = '请输入有效名称，名称不能包含路径分隔符');
              return;
            }
            Navigator.pop(context, value);
          }

          return AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: 400,
              child: TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(labelText: '名称', errorText: error),
                onSubmitted: (_) => submit(),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(onPressed: submit, child: const Text('确定')),
            ],
          );
        },
      ),
    );
    Future<void>.delayed(const Duration(seconds: 1), controller.dispose);
    return name;
  }

  Future<bool> _mutateArchive(
    String operation, {
    List<String> inputs = const [],
    String item = '',
    String destination = '',
  }) async {
    if (!_interactive || !_editable || _archive == null) return false;
    final archive = _archive!;
    final version = _archiveVersion;
    var password = _password;
    setState(() => _mutating = true);
    try {
      if (_entries.any((entry) => entry.encrypted) && password.isEmpty) {
        final value = await _askPassword();
        if (value == null || !mounted) return false;
        password = value;
      }
      var action = operation;
      while (mounted) {
        try {
          final labels = {
            'add': '添加文件',
            'addReplace': '添加并替换文件',
            'remove': '删除条目',
            'rename': '重命名',
            'mkdir': '新建文件夹',
          };
          final result = await _run(
            labels[action]!,
            ArchiveRequest(
              action,
              archive,
              inputs: inputs,
              itemPath: item,
              destination: destination,
              password: password,
              expectedVersion: version,
              codePage: _archiveCodePage,
            ),
          );
          if (result == null || !mounted) return false;
          await _edits?.rebaseArchive(
            archive,
            version,
            result['version'] as String,
          );
          if (!mounted) return false;
          setState(() {
            _archiveVersion = result['version'] as String;
            _archiveComment = result['comment'] as String? ?? '';
            _password = password;
            _entries = (result['items'] as List)
                .map(
                  (value) =>
                      ArchiveEntry.fromJson(value as Map<String, dynamic>),
                )
                .toList();
            _tree = buildArchiveTree(_entries);
            String renamed(String path) =>
                operation == 'rename' &&
                    (path == item || path.startsWith('$item/'))
                ? '$destination${path.substring(item.length)}'
                : path;
            _folder = renamed(_folder);
            final selected = _selected.map(renamed).toSet();
            _selected
              ..clear()
              ..addAll(selected.where(_pathExists));
            while (_folder.isNotEmpty && !_pathExists(_folder)) {
              _folder = p.posix.dirname(_folder) == '.'
                  ? ''
                  : p.posix.dirname(_folder);
            }
            final previous = _navigation
                .map(renamed)
                .where((path) => path.isEmpty || _pathExists(path))
                .toList();
            _navigation
              ..clear()
              ..addAll(previous);
            if (_navigation.isEmpty || _navigation.last != _folder) {
              _navigation.add(_folder);
            }
            _navigationIndex = _navigation.length - 1;
            _status = '${labels[action]}完成';
          });
          return true;
        } on ArchiveFailure catch (error) {
          if (action != 'add' || error.conflicts.isEmpty) rethrow;
          if (_editingTargets(error.conflicts)) {
            throw const ArchiveFailure('重名文件正在外部编辑，请先结束对应编辑会话');
          }
          final names = error.conflicts.take(8).join('\n');
          if (!await _confirm(
            '替换同名文件',
            '以下 ${error.conflicts.length} 个文件已存在。是否替换？\n\n$names',
          )) {
            return false;
          }
          action = 'addReplace';
        }
      }
    } catch (error) {
      await _error(error);
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
    return false;
  }

  bool _pathExists(String path) => _entries.any(
    (entry) =>
        entry.normalizedPath == path ||
        entry.normalizedPath.startsWith('$path/'),
  );

  Future<void> _addFiles([List<String>? dropped]) async {
    if (!_interactive || !_editable || _archive == null) return;
    final paths = dropped ?? await _choose('chooseInputs');
    if (paths.isNotEmpty && mounted) {
      await _mutateArchive('add', inputs: paths, item: _folder);
    }
  }

  Future<void> _removeSelected() async {
    if (!_interactive || !_editable || _selected.isEmpty) return;
    final paths = _selected.toList();
    if (_editingTargets(paths)) {
      await _error('所选条目正在外部编辑，请先在“管理编辑文件”中结束监控');
      return;
    }
    if (!await _confirm(
      '从压缩包删除',
      '删除选中的 ${paths.length} 个条目及目录中的文件？\n\n${paths.take(8).join('\n')}',
    )) {
      return;
    }
    if (mounted) await _mutateArchive('remove', inputs: paths);
  }

  Future<void> _renameSelected() async {
    if (!_interactive || !_editable || _selected.length != 1) return;
    final path = _selected.single;
    if (_editingTargets([path])) {
      await _error('此条目正在外部编辑，请先结束对应编辑会话');
      return;
    }
    final name = await _askName('重命名', p.posix.basename(path));
    if (name != null && mounted && name != p.posix.basename(path)) {
      final parent = p.posix.dirname(path);
      await _mutateArchive(
        'rename',
        item: path,
        destination: parent == '.' ? name : '$parent/$name',
      );
    }
  }

  Future<void> _newFolder() async {
    if (!_interactive || !_editable) return;
    final name = await _askName('新建文件夹', '新建文件夹');
    if (name != null && mounted) {
      await _mutateArchive(
        'mkdir',
        destination: _folder.isEmpty ? name : '$_folder/$name',
      );
    }
  }

  void _closeArchive() {
    if (!_interactive) return;
    setState(() {
      _archive = null;
      _entries = [];
      _tree = buildArchiveTree([]);
      _selected.clear();
      _password = '';
      _archiveVersion = '';
      _archiveComment = '';
      _editable = false;
      _folder = '';
      _navigation
        ..clear()
        ..add('');
      _navigationIndex = 0;
    });
    _desktop.invokeMethod<void>('setArchiveTitle', '');
  }

  Future<void> _command(String command) async {
    if (!_interactive) return;
    switch (command) {
      case 'open':
        await _openDialog();
        break;
      case 'new':
        await _create();
        break;
      case 'add':
        await _addFiles();
        break;
      case 'extract':
        await _extract();
        break;
      case 'remove':
        await _removeSelected();
        break;
      case 'rename':
        await _renameSelected();
        break;
      case 'mkdir':
        await _newFolder();
        break;
      case 'test':
        await _test();
        break;
      case 'view':
        if (_selectedFile != null) await _openFile(_selectedFile!);
        break;
      case 'edit':
        if (_selectedFile != null) {
          await _openFile(_selectedFile!, editing: true);
        }
        break;
      case 'properties':
        await _properties();
        break;
      case 'back':
        _moveHistory(-1);
        break;
      case 'forward':
        _moveHistory(1);
        break;
      case 'tree':
        setState(() => _showTree = !_showTree);
        break;
      case 'close':
        _closeArchive();
        break;
    }
  }

  Future<void> _properties() async {
    if (_archive == null) return;
    final entry = _selectedFile;
    final files = _entries
        .where(
          (value) =>
              !value.directory &&
              (_selected.isEmpty || value.isSelectedBy(_selected)),
        )
        .toList();
    final size = files.fold<int>(0, (total, item) => total + item.size);
    final packed = files.fold<int>(0, (total, item) => total + item.packed);
    final values = <String, String>{
      '路径': entry?.path ?? _archive!,
      '文件数': '${files.length}',
      '原始大小': _size(size),
      '压缩后': _size(packed),
      if (entry == null && _archiveComment.isNotEmpty) '注释': _archiveComment,
      if (entry != null) ...{
        '修改时间': _date(entry.modified),
        '压缩方法': entry.method,
        'CRC32': entry.crc,
        '加密': entry.encrypted ? '是' : '否',
      },
    };
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('属性'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: values.entries
                  .map(
                    (value) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 7),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 86,
                            child: Text(
                              value.key,
                              style: TextStyle(
                                color: AppColors.of(context).secondary,
                              ),
                            ),
                          ),
                          Expanded(
                            child: SelectableText(
                              value.value.isEmpty ? '—' : value.value,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _moveHistory(int offset) {
    final index = _navigationIndex + offset;
    if (!_interactive || index < 0 || index >= _navigation.length) return;
    _navigationIndex = index;
    _navigate(_navigation[index], remember: false);
  }

  ArchiveEntry? get _selectedFile {
    if (_selected.length != 1) return null;
    for (final entry in _entries) {
      if (!entry.directory && entry.normalizedPath == _selected.single) {
        return entry;
      }
    }
    return null;
  }

  Future<void> _showSettings() async {
    if (!_interactive || Navigator.of(context).canPop()) return;
    final preferences = await showDialog<AppSettings>(
      context: context,
      builder: (_) => SettingsDialog(initial: _preferences),
    );
    if (preferences != null && mounted) {
      final encodingChanged =
          _preferences.filenameEncoding != preferences.filenameEncoding;
      setState(() => _preferences = preferences);
      widget.onSettingsChanged?.call(preferences);
      final archive = _archive;
      if (encodingChanged && archive != null) {
        await _open(archive, password: _password);
      }
    }
  }

  Future<void> _openFile(ArchiveEntry entry, {bool editing = false}) async {
    if (!_interactive || _archive == null) return;
    final workspace = _edits;
    if (editing && workspace == null) {
      await _error(_workspaceError ?? '编辑工作区尚未就绪，请稍后重试');
      return;
    }
    if (editing && !_editable) {
      await _error('当前支持 ZIP 和 7z 的编辑回写');
      return;
    }
    final archive = _archive!;
    final version = _archiveVersion;
    var password = _password;
    _openingFile = true;
    try {
      final existing = editing ? workspace!.find(archive, entry.path) : null;
      File file;
      if (existing != null) {
        file = existing.file;
      } else {
        final requiresPassword =
            _entries.any((item) => item.encrypted) || password.isNotEmpty;
        if (requiresPassword && password.isEmpty) {
          final value = await _askPassword();
          if (value == null || !mounted) return;
          password = value;
        }
        final directory = editing
            ? await workspace!.root.createTemp('edit-')
            : await Directory.systemTemp.createTemp('f7zip-view-');
        final destination = p.join(directory.path, 'files');
        final result = await _run(
          editing ? '准备编辑文件' : '准备查看文件',
          ArchiveRequest(
            'extract',
            archive,
            destination: destination,
            password: password,
            indices: [entry.index],
            codePage: _archiveCodePage,
          ),
        );
        if (result == null || !mounted) return;
        if (result['version'] != version) {
          throw const ArchiveFailure('压缩包已变化，请重新打开后再操作');
        }
        file = File(p.join(destination, entry.path));
        if (!await file.exists()) {
          file = File(p.join(destination, entry.normalizedPath));
        }
        if (!await file.exists()) throw const ArchiveFailure('解压后的文件不存在');
        if (editing) {
          await workspace!.track(
            directory: directory,
            archive: archive,
            itemPath: entry.path,
            file: file,
            version: version,
            requiresPassword: requiresPassword,
            codePage: _archiveCodePage,
            password: password,
          );
        }
        if (_archive == archive) _password = password;
      }
      await _desktop.invokeMethod<void>('launchFile', {
        'path': file.path,
        'application': editing ? _preferences.editor : _preferences.viewer,
      });
      if (mounted) {
        setState(
          () => _status = editing
              ? '正在监控编辑保存 · ${entry.path}'
              : '已打开 · ${entry.path}',
        );
      }
    } catch (error) {
      await _error(error);
    } finally {
      _openingFile = false;
    }
  }

  Future<String> _writeBack(EditSession session, String snapshot) async {
    final result = await _run(
      '回写编辑文件',
      ArchiveRequest(
        'update',
        session.archive,
        itemPath: session.itemPath,
        expectedVersion: session.version,
        password: session.password,
        codePage: session.codePage,
        inputs: [snapshot],
      ),
    );
    if (result == null) throw const ArchiveFailure('回写已取消，编辑文件已保留');
    if (mounted) {
      setState(() {
        if (_archive == session.archive) {
          _archiveVersion = result['version'] as String;
          _archiveComment = result['comment'] as String? ?? '';
          _entries = (result['items'] as List)
              .map(
                (item) => ArchiveEntry.fromJson(item as Map<String, dynamic>),
              )
              .toList();
          _tree = buildArchiveTree(_entries);
        }
        _status = '已自动更新压缩包 · ${session.itemPath}';
      });
    }
    return result['version'] as String;
  }

  void _activateRow(_VisibleEntry row) {
    if (!_interactive) return;
    if (row.dotEntry) {
      if (_folder.isNotEmpty) {
        _navigate(
          p.posix.dirname(_folder) == '.' ? '' : p.posix.dirname(_folder),
        );
      }
      return;
    }
    if (row.directory) {
      _navigate(row.path);
      return;
    }
    setState(() {
      _selected.clear();
      _selected.add(row.path);
    });
    if (row.entry != null) _openFile(row.entry!);
  }

  Future<void> _rowMenu(_VisibleEntry row, Offset position) async {
    if (!_interactive) return;
    if (!row.dotEntry && !_selected.contains(row.path)) {
      setState(() {
        _selected.clear();
        _selected.add(row.path);
      });
    }
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(value: 'open', child: Text(row.directory ? '打开' : '查看')),
        if (!row.directory)
          PopupMenuItem(
            value: 'edit',
            enabled: _editable,
            child: const Text('编辑并自动回写'),
          ),
        if (!row.dotEntry) ...[
          const PopupMenuItem(value: 'extract', child: Text('解压选中项…')),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'add',
            enabled: _editable,
            child: const Text('添加文件…'),
          ),
          PopupMenuItem(
            value: 'rename',
            enabled: _editable && _selected.length == 1,
            child: const Text('重命名…'),
          ),
          PopupMenuItem(
            value: 'remove',
            enabled: _editable,
            child: const Text('从压缩包删除…'),
          ),
          PopupMenuItem(
            value: 'mkdir',
            enabled: _editable,
            child: const Text('新建文件夹…'),
          ),
          const PopupMenuItem(value: 'properties', child: Text('属性')),
        ],
      ],
    );
    if (!mounted || !_available) return;
    switch (action) {
      case 'open':
        _activateRow(row);
        break;
      case 'edit':
        if (row.entry != null) await _openFile(row.entry!, editing: true);
        break;
      case 'extract':
        await _extract(selectedOnly: true);
        break;
      case 'add':
      case 'rename':
      case 'remove':
      case 'mkdir':
      case 'properties':
        await _command(action!);
        break;
    }
  }

  Widget _editStatus() {
    final workspace = _edits!;
    final pending = workspace.sessions
        .where((session) => session.pending)
        .length;
    final needsAttention = pending > 0 || workspace.recoveryErrors.isNotEmpty;
    final foreground = needsAttention
        ? AppColors.of(context).onWarning
        : AppColors.of(context).onTint;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      color: needsAttention
          ? AppColors.of(context).warning
          : AppColors.of(context).tint,
      child: Row(
        children: [
          Icon(Icons.edit_note, size: 18, color: foreground),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '编辑监控 ${workspace.sessions.length} 项${pending > 0 ? ' · $pending 项待回写或处理' : ' · 保存后自动更新压缩包'}',
              style: TextStyle(fontSize: 11, color: foreground),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: foreground),
            onPressed: _showEditSessions,
            child: const Text('管理编辑文件'),
          ),
        ],
      ),
    );
  }

  Future<void> _showEditSessions() async {
    final workspace = _edits;
    if (workspace == null) return;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, refresh) => AlertDialog(
          title: const Text('编辑文件'),
          content: SizedBox(
            width: 620,
            height: 300,
            child: ListView(
              children: [
                for (final session in List<EditSession>.of(workspace.sessions))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${p.basename(session.archive)} / ${session.itemPath}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          session.error ??
                              (session.pending ? '等待自动回写' : '已同步，正在监控保存'),
                          style: TextStyle(
                            fontSize: 11,
                            color: session.error == null
                                ? null
                                : Theme.of(context).colorScheme.error,
                          ),
                        ),
                        Wrap(
                          children: [
                            TextButton(
                              onPressed: () => _desktop.invokeMethod<void>(
                                'reveal',
                                session.file.path,
                              ),
                              child: const Text('定位编辑文件'),
                            ),
                            TextButton(
                              onPressed: _busy
                                  ? null
                                  : () async {
                                      if (session.requiresPassword &&
                                          session.password.isEmpty) {
                                        final password = await _askPassword();
                                        if (password == null) return;
                                        session.password = password;
                                      }
                                      workspace.retry(session);
                                      if (context.mounted) refresh(() {});
                                    },
                              child: const Text('重试回写'),
                            ),
                            TextButton(
                              onPressed: _busy
                                  ? null
                                  : () async {
                                      await workspace.stop(session);
                                      if (context.mounted) refresh(() {});
                                    },
                              child: const Text('结束监控（保留文件）'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                for (final error in workspace.recoveryErrors)
                  Text(
                    error,
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  _desktop.invokeMethod<void>('reveal', workspace.root.path),
              child: const Text('会话目录'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }

  void _navigate(String folder, {bool remember = true}) {
    if (!_interactive) return;
    setState(() {
      if (remember && folder != _folder) {
        _navigation.removeRange(_navigationIndex + 1, _navigation.length);
        _navigation.add(folder);
        _navigationIndex = _navigation.length - 1;
      }
      _folder = folder;
      _selected.clear();
      _query = '';
      _search.clear();
      if (_fileList.hasClients) _fileList.jumpTo(0);
    });
  }

  List<_VisibleEntry> get _visible {
    final rows = <String, _VisibleEntry>{};
    for (final entry in _entries) {
      final path = entry.normalizedPath;
      if (path.isEmpty) continue;
      if (_query.isNotEmpty) {
        if (path.toLowerCase().contains(_query.toLowerCase())) {
          rows[path] = _VisibleEntry(path, entry.directory, entry);
        }
        continue;
      }
      final prefix = _folder.isEmpty ? '' : '$_folder/';
      if (!path.startsWith(prefix) || path == _folder) continue;
      final rest = path.substring(prefix.length);
      final slash = rest.indexOf('/');
      if (slash >= 0) {
        final folder = '$prefix${rest.substring(0, slash)}';
        rows.putIfAbsent(folder, () => _VisibleEntry(folder, true, null));
      } else if (rest.isNotEmpty) {
        rows[path] = _VisibleEntry(path, entry.directory, entry);
      }
    }
    final result = rows.values.toList();
    result.sort((a, b) {
      if (a.directory != b.directory) return a.directory ? -1 : 1;
      int order;
      switch (_sortColumn) {
        case 'type':
          order = _fileType(a.path).compareTo(_fileType(b.path));
          break;
        case 'size':
          order = (a.entry?.size ?? 0).compareTo(b.entry?.size ?? 0);
          break;
        case 'packed':
          order = (a.entry?.packed ?? 0).compareTo(b.entry?.packed ?? 0);
          break;
        case 'modified':
          order = (a.entry?.modified ?? 0).compareTo(b.entry?.modified ?? 0);
          break;
        default:
          order = a.path.toLowerCase().compareTo(b.path.toLowerCase());
      }
      if (order == 0) order = a.path.compareTo(b.path);
      return _sortAscending ? order : -order;
    });
    if (_preferences.showDotEntries && _query.isEmpty && _folder.isNotEmpty) {
      result.insert(0, const _VisibleEntry('..', true, null, dotEntry: true));
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final archive = _archive;
    final commandState = <String, bool>{
      'open': _interactive,
      'new': _interactive,
      'extract': _interactive && archive != null,
      'test': _interactive && archive != null,
      'add': _interactive && _editable && archive != null,
      'mkdir': _interactive && _editable && archive != null,
      'remove': _interactive && _editable && _selected.isNotEmpty,
      'rename': _interactive && _editable && _selected.length == 1,
      'view': _interactive && _selectedFile != null,
      'edit': _interactive && _editable && _selectedFile != null,
      'properties': _interactive && archive != null,
      'close': _interactive && archive != null,
      'tree': _interactive,
      'treeVisible': _showTree,
      'back': _interactive && _navigationIndex > 0,
      'forward': _interactive && _navigationIndex + 1 < _navigation.length,
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _desktop.invokeMethod<void>('updateCommands', commandState);
    });
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyO, meta: true): _openDialog,
        const SingleActivator(LogicalKeyboardKey.keyE, meta: true): _extract,
        const SingleActivator(LogicalKeyboardKey.keyI, meta: true): _properties,
        const SingleActivator(LogicalKeyboardKey.keyA, meta: true, shift: true):
            _addFiles,
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true, shift: true):
            _newFolder,
        const SingleActivator(LogicalKeyboardKey.backspace, meta: true):
            _removeSelected,
        const SingleActivator(LogicalKeyboardKey.f2): _renameSelected,
        const SingleActivator(LogicalKeyboardKey.f3): () => _command('view'),
        const SingleActivator(LogicalKeyboardKey.f4): () => _command('edit'),
        const SingleActivator(LogicalKeyboardKey.bracketLeft, meta: true): () =>
            _moveHistory(-1),
        const SingleActivator(
          LogicalKeyboardKey.bracketRight,
          meta: true,
        ): () =>
            _moveHistory(1),
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true): _create,
        const SingleActivator(LogicalKeyboardKey.comma, meta: true):
            _showSettings,
        const SingleActivator(LogicalKeyboardKey.keyA, meta: true): () {
          if (archive != null && !_busy) {
            setState(
              () => _selected.addAll(
                _visible
                    .where((entry) => !entry.dotEntry)
                    .map((entry) => entry.path),
              ),
            );
          }
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: DropTarget(
            onDragEntered: (_) => setState(() => _dragging = true),
            onDragExited: (_) => setState(() => _dragging = false),
            onDragDone: (details) {
              setState(() => _dragging = false);
              _drop(details.files.map((file) => file.path).toList());
            },
            child: Stack(
              children: [
                Column(
                  children: [
                    _toolbar(),
                    Expanded(
                      child: Row(
                        children: [
                          if (_showTree || archive == null) ...[
                            _sidebar(),
                            MouseRegion(
                              cursor: SystemMouseCursors.resizeColumn,
                              child: GestureDetector(
                                key: const ValueKey('tree-divider'),
                                onHorizontalDragUpdate: archive == null
                                    ? null
                                    : (details) => setState(
                                        () => _treeWidth =
                                            (_treeWidth + details.delta.dx)
                                                .clamp(170, 340),
                                      ),
                                onDoubleTap: () =>
                                    setState(() => _treeWidth = 200),
                                child: Container(
                                  width: 5,
                                  color: AppColors.of(context).sidebar,
                                  alignment: Alignment.center,
                                  child: Container(
                                    width: 1,
                                    color: AppColors.of(context).border,
                                  ),
                                ),
                              ),
                            ),
                          ],
                          Expanded(
                            child: _engineError != null
                                ? _engineFailure()
                                : archive == null
                                ? _welcome()
                                : _browser(),
                          ),
                        ],
                      ),
                    ),
                    if (_edits != null &&
                        (_edits!.sessions.isNotEmpty ||
                            _edits!.recoveryErrors.isNotEmpty))
                      _editStatus(),
                    if (_busy) _progressPanel(),
                    _statusbar(),
                  ],
                ),
                if (_dragging)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Container(
                        margin: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: AppColors.of(context).accent
                              .withValues(alpha: 0.09),
                          border: Border.all(
                            color: AppColors.of(context).accent,
                            width: 3,
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Center(
                          child: Card(
                            child: Padding(
                              padding: EdgeInsets.all(24),
                              child: Text(
                                '松开以打开压缩包，或创建新压缩包',
                                style: TextStyle(
                                  fontSize: 18,
                                  color: AppColors.of(context).accent,
                                ),
                              ),
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
    );
  }

  Widget _toolbar() => Container(
    height: 60,
    padding: const EdgeInsets.symmetric(horizontal: 10),
    decoration: BoxDecoration(
      color: AppColors.of(context).canvas,
      border: Border(bottom: BorderSide(color: AppColors.of(context).border)),
    ),
    child: Row(
      children: [
        _tool(
          Icons.folder_open_rounded,
          '打开',
          '⌘O',
          _interactive ? _openDialog : null,
          emphasized: _archive == null,
        ),
        _tool(
          Icons.inventory_2_outlined,
          '新建压缩包',
          '⌘N',
          _interactive ? _create : null,
        ),
        const SizedBox(height: 26, child: VerticalDivider(width: 16)),
        _tool(
          Icons.drive_folder_upload_outlined,
          '解压到…',
          '⌘E',
          _interactive && _archive != null ? _extract : null,
          emphasized: _archive != null,
        ),
        _tool(
          Icons.add_box_outlined,
          '添加',
          '⇧⌘A',
          _interactive && _editable && _archive != null ? _addFiles : null,
        ),
        _tool(
          Icons.delete_outline,
          '删除',
          '⌘⌫',
          _interactive && _editable && _selected.isNotEmpty
              ? _removeSelected
              : null,
        ),
        _tool(
          Icons.verified_outlined,
          '测试',
          '检查完整性',
          _interactive && _archive != null ? _test : null,
        ),
        const SizedBox(height: 26, child: VerticalDivider(width: 16)),
        _tool(
          Icons.visibility_outlined,
          '查看',
          'F3',
          _interactive && _selectedFile != null
              ? () => _openFile(_selectedFile!)
              : null,
        ),
        _tool(
          Icons.edit_outlined,
          '编辑',
          'F4',
          _interactive && _editable && _selectedFile != null
              ? () => _openFile(_selectedFile!, editing: true)
              : null,
        ),
        _tool(
          Icons.article_outlined,
          '属性',
          '⌘I',
          _interactive && _archive != null ? _properties : null,
        ),
        const Spacer(),
        PopupMenuButton<String>(
          tooltip: '最近打开',
          enabled: _interactive && _recent.isNotEmpty,
          icon: const Icon(Icons.history_rounded, size: 19),
          onSelected: _open,
          itemBuilder: (_) => _recent
              .map(
                (path) => PopupMenuItem(
                  value: path,
                  child: Tooltip(
                    message: path,
                    child: Text(
                      p.basename(path),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              )
              .toList(),
        ),
        IconButton(
          tooltip: '设置',
          onPressed: _interactive ? _showSettings : null,
          icon: const Icon(Icons.settings_outlined, size: 19),
        ),
        PopupMenuButton<String>(
          tooltip: '更多操作',
          enabled: _interactive,
          icon: const Icon(Icons.more_horiz, size: 22),
          onSelected: (action) async {
            switch (action) {
              case 'quick':
                await _extract(besideArchive: true);
                break;
              case 'selected':
                await _extract(selectedOnly: true);
                break;
              case 'about':
                await _about();
                break;
              case 'finder':
                await _desktop.invokeMethod<void>(
                  'reveal',
                  _archive ?? _lastOutput,
                );
                break;
              default:
                await _command(action);
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'quick',
              enabled: _archive != null,
              child: const Text('快速解压到同级目录'),
            ),
            PopupMenuItem(
              value: 'selected',
              enabled: _selected.isNotEmpty,
              child: const Text('解压选中项…'),
            ),
            const PopupMenuDivider(),
            PopupMenuItem(
              value: 'rename',
              enabled: _editable && _selected.length == 1,
              child: const Text('重命名…'),
            ),
            PopupMenuItem(
              value: 'mkdir',
              enabled: _editable && _archive != null,
              child: const Text('新建文件夹…'),
            ),
            PopupMenuItem(
              value: 'tree',
              child: Text(_showTree ? '隐藏文件树' : '显示文件树'),
            ),
            PopupMenuItem(
              value: 'finder',
              enabled: _archive != null || _lastOutput != null,
              child: const Text('在 Finder 显示'),
            ),
            const PopupMenuItem(value: 'about', child: Text('关于 F7Zip')),
            PopupMenuItem(
              value: 'close',
              enabled: _archive != null,
              child: const Text('关闭压缩包'),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _tool(
    IconData icon,
    String label,
    String hint,
    VoidCallback? action, {
    bool emphasized = false,
  }) => Tooltip(
    message: hint.isEmpty ? label : '$label  $hint',
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: SizedBox(
        width: label == '新建压缩包' ? 78 : 56,
        height: 48,
        child: TextButton(
          onPressed: action,
          style: TextButton.styleFrom(
            foregroundColor: emphasized
                ? AppColors.of(context).onTint
                : AppColors.of(context).text,
            backgroundColor: emphasized ? AppColors.of(context).tint : null,
            disabledForegroundColor: AppColors.of(context).secondary
                .withValues(alpha: 0.4),
            padding: const EdgeInsets.symmetric(vertical: 4),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20),
              const SizedBox(height: 3),
              Text(label, maxLines: 1, style: const TextStyle(fontSize: 11)),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _sidebar() => Container(
    width: _archive == null ? 192 : _treeWidth,
    color: AppColors.of(context).sidebar,
    padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: AppColors.of(context).tint,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(
                  Icons.folder_zip_outlined,
                  size: 19,
                  color: AppColors.of(context).accent,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'F7Zip',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.of(context).text,
                  letterSpacing: -0.5,
                ),
              ),
            ],
          ),
        ),
        if (_archive == null)
          Padding(
            padding: EdgeInsets.only(left: 10, bottom: 6),
            child: Text(
              '工作区',
              style: TextStyle(
                fontSize: 11,
                color: AppColors.of(context).secondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        if (_archive == null)
          _sideItem(Icons.home_outlined, '开始', true, _closeArchive),
        if (_archive != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 2, 8, 6),
            child: Text(
              '压缩包目录',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.of(context).secondary,
              ),
            ),
          ),
        if (_archive != null)
          _sideItem(
            Icons.folder_zip_outlined,
            p.basename(_archive!),
            _folder.isEmpty,
            _available ? () => _navigate('') : null,
          ),
        SizedBox(height: _archive == null ? 14 : 2),
        if (_archive == null)
          Padding(
            padding: const EdgeInsets.only(left: 10, bottom: 6),
            child: Text(
              _archive == null ? '最近打开' : '压缩包文件树',
              style: TextStyle(
                fontSize: 11,
                color: AppColors.of(context).secondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        if (_archive == null && _recent.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              '打开的压缩包会显示在这里',
              style: TextStyle(
                fontSize: 11,
                color: AppColors.of(context).secondary,
              ),
            ),
          ),
        Expanded(
          child: _archive != null
              ? ArchiveTreeView(
                  key: ValueKey(_archive),
                  root: _tree,
                  folder: _folder,
                  selected: _selected,
                  enabled: _interactive,
                  onNavigate: _navigate,
                  onSelectFile: (path) {
                    _navigate(
                      p.posix.dirname(path) == '.' ? '' : p.posix.dirname(path),
                    );
                    setState(() => _selected.add(path));
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted || !_fileList.hasClients) return;
                      final index = _visible.indexWhere(
                        (entry) => entry.path == path,
                      );
                      if (index >= 0) {
                        _fileList.jumpTo(
                          (index * _fileRowHeight).clamp(
                            0,
                            _fileList.position.maxScrollExtent,
                          ),
                        );
                      }
                    });
                  },
                )
              : ListView(
                  children: _recent
                      .map(
                        (path) => Tooltip(
                          message: path,
                          child: _sideItem(
                            Icons.history,
                            p.basename(path),
                            false,
                            _available ? () => _open(path) : null,
                          ),
                        ),
                      )
                      .toList(),
                ),
        ),
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppColors.of(context).alternate,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            children: [
              Icon(
                Icons.memory_outlined,
                size: 17,
                color: AppColors.of(context).secondary,
              ),
              SizedBox(width: 8),
              Flexible(
                child: Text(
                  '7-Zip 原生引擎',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.of(context).secondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _sideItem(
    IconData icon,
    String text,
    bool selected,
    VoidCallback? action,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: Material(
      color: selected ? AppColors.of(context).tint : Colors.transparent,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        onTap: action,
        borderRadius: BorderRadius.circular(7),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            children: [
              Icon(
                icon,
                size: 17,
                color: selected
                    ? AppColors.of(context).onTint
                    : AppColors.of(context).secondary,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: selected
                        ? AppColors.of(context).onTint
                        : AppColors.of(context).secondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _welcome() => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxHeight < 560;
      return Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: constraints.maxWidth < 700 ? 24 : 32,
            vertical: compact ? 16 : 24,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: compact ? 48 : 56,
                  height: compact ? 48 : 56,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        AppColors.of(context).tint,
                        AppColors.of(context).panel,
                      ],
                    ),
                    border: Border.all(color: AppColors.of(context).border),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(
                    Icons.folder_zip_outlined,
                    size: 28,
                    color: AppColors.of(context).accent,
                  ),
                ),
                SizedBox(height: compact ? 14 : 20),
                Text(
                  '文件打包，从容有序',
                  style: TextStyle(
                    fontSize: constraints.maxWidth < 700 ? 24 : 28,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -1,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '浏览、解压与加密压缩，一处轻松完成。',
                  style: TextStyle(
                    color: AppColors.of(context).secondary,
                    fontSize: 13,
                  ),
                ),
                SizedBox(height: compact ? 14 : 20),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 36),
                        visualDensity: VisualDensity.standard,
                      ),
                      onPressed: _available ? _openDialog : null,
                      icon: const Icon(Icons.folder_open_rounded, size: 19),
                      label: const Text('打开压缩包'),
                    ),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 36),
                        visualDensity: VisualDensity.standard,
                      ),
                      onPressed: _available ? _create : null,
                      icon: const Icon(Icons.add_rounded, size: 19),
                      label: const Text('新建压缩包'),
                    ),
                  ],
                ),
                SizedBox(height: compact ? 16 : 24),
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(compact ? 12 : 16),
                  decoration: BoxDecoration(
                    color: AppColors.of(context).field,
                    border: Border.all(color: AppColors.of(context).border),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.file_download_outlined,
                        size: 24,
                        color: AppColors.of(context).accent,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '将文件拖到这里',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '拖入压缩包直接浏览，拖入文件或文件夹开始打包',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppColors.of(context).secondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: compact ? 12 : 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final format in [
                      'ZIP',
                      '7Z',
                      'RAR',
                      'TAR',
                      'GZ',
                      'XZ',
                    ])
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: AppColors.of(context).border,
                          ),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          format,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: AppColors.of(context).secondary,
                          ),
                        ),
                      ),
                  ],
                ),
                SizedBox(height: compact ? 8 : 12),
                Text(
                  '本地处理文件 · 支持加密压缩 · 开源桌面工具',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.of(context).secondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _engineFailure() => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: SelectableText(
        '原生引擎加载失败\n\n$_engineError\n\n请使用 scripts/build_macos.sh 重新构建完整应用。',
      ),
    ),
  );

  Widget _browser() {
    final rows = _visible;
    final selectable = rows.where((entry) => !entry.dotEntry).toList();
    final total = _entries
        .where((entry) => !entry.directory)
        .fold<int>(0, (sum, entry) => sum + entry.size);
    return LayoutBuilder(
      builder: (context, constraints) {
        final showPacked = constraints.maxWidth >= 650;
        final showModified = constraints.maxWidth >= 540;
        final showType = constraints.maxWidth >= 800;
        return Column(
          children: [
            Container(
              height: 54,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: AppColors.of(context).border),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: AppColors.of(context).tint,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.folder_zip_outlined,
                      size: 20,
                      color: AppColors.of(context).onTint,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          p.basename(_archive!),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${_entries.where((entry) => !entry.directory).length} 个文件 · ${_size(total)}${_volumeCount > 1 ? ' · $_volumeCount 卷' : ''}',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.of(context).secondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.of(context).field,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      _editable ? '可编辑' : '只读浏览',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.of(context).secondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: AppColors.of(context).canvas,
                border: Border(
                  bottom: BorderSide(color: AppColors.of(context).border),
                ),
              ),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '后退',
                    icon: const Icon(Icons.arrow_back, size: 17),
                    onPressed: _interactive && _navigationIndex > 0
                        ? () => _moveHistory(-1)
                        : null,
                  ),
                  IconButton(
                    tooltip: '前进',
                    icon: const Icon(Icons.arrow_forward, size: 17),
                    onPressed:
                        _interactive &&
                            _navigationIndex + 1 < _navigation.length
                        ? () => _moveHistory(1)
                        : null,
                  ),
                  IconButton(
                    tooltip: '上一级',
                    icon: const Icon(Icons.arrow_upward, size: 18),
                    onPressed: _folder.isNotEmpty && !_busy
                        ? () => _navigate(
                            p.posix.dirname(_folder) == '.'
                                ? ''
                                : p.posix.dirname(_folder),
                          )
                        : null,
                  ),
                  Icon(
                    Icons.folder_zip_outlined,
                    size: 18,
                    color: AppColors.of(context).accent,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      '${p.basename(_archive!)}${_folder.isEmpty ? '' : ' / $_folder'}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  SizedBox(
                    width: constraints.maxWidth < 650 ? 165 : 210,
                    child: TextField(
                      controller: _search,
                      enabled: !_busy,
                      decoration: InputDecoration(
                        hintText: '搜索压缩包内的文件',
                        prefixIcon: const Icon(Icons.search, size: 18),
                        suffixIcon: _query.isEmpty
                            ? null
                            : IconButton(
                                tooltip: '清除搜索',
                                icon: const Icon(Icons.close, size: 16),
                                onPressed: _busy
                                    ? null
                                    : () => setState(() {
                                        _search.clear();
                                        _query = '';
                                        _selected.clear();
                                      }),
                              ),
                        contentPadding: const EdgeInsets.symmetric(vertical: 6),
                      ),
                      style: const TextStyle(fontSize: 12),
                      onChanged: (value) => setState(() {
                        _query = value;
                        _selected.clear();
                      }),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: AppColors.of(context).panel,
                border: Border(
                  bottom: BorderSide(color: AppColors.of(context).border),
                ),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 32,
                    child: Checkbox(
                      value: selectable.isEmpty
                          ? false
                          : selectable.every(
                              (entry) => _selected.contains(entry.path),
                            ),
                      onChanged: _busy || selectable.isEmpty
                          ? null
                          : (value) => setState(() {
                              if (value == true) {
                                _selected.addAll(
                                  selectable.map((entry) => entry.path),
                                );
                              } else {
                                _selected.clear();
                              }
                            }),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const SizedBox(width: 31),
                  Expanded(child: _sortHeader('名称', 'name')),
                  SizedBox(width: 92, child: _sortHeader('大小', 'size')),
                  if (showPacked)
                    SizedBox(width: 92, child: _sortHeader('压缩后', 'packed')),
                  if (showType)
                    SizedBox(width: 76, child: _sortHeader('类型', 'type')),
                  if (showModified)
                    SizedBox(
                      width: 135,
                      child: _sortHeader('修改时间', 'modified'),
                    ),
                ],
              ),
            ),
            Expanded(
              child: rows.isEmpty
                  ? Center(
                      child: Text(
                        _query.isEmpty ? '这里没有文件' : '未找到匹配的文件',
                        style: TextStyle(
                          color: AppColors.of(context).secondary,
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _fileList,
                      itemCount: rows.length,
                      itemExtent: _fileRowHeight,
                      itemBuilder: (context, index) {
                        final row = rows[index];
                        final entry = row.entry;
                        final selected = _selected.contains(row.path);
                        return Material(
                          color: selected
                              ? AppColors.of(context).selection
                              : !_preferences.alternateRows || index.isEven
                              ? AppColors.of(context).canvas
                              : AppColors.of(context).alternate,
                          child: InkWell(
                            key: ValueKey(
                              'row:${row.dotEntry ? 'navigation:' : ''}${row.path}',
                            ),
                            onTap: !_interactive
                                ? null
                                : () {
                                    if (_preferences.singleClickOpen) {
                                      _activateRow(row);
                                    } else if (!row.dotEntry) {
                                      setState(() {
                                        if (!_selected.add(row.path)) {
                                          _selected.remove(row.path);
                                        }
                                      });
                                    }
                                  },
                            onDoubleTap:
                                !_interactive || _preferences.singleClickOpen
                                ? null
                                : () => _activateRow(row),
                            onSecondaryTapDown: !_interactive
                                ? null
                                : (details) =>
                                      _rowMenu(row, details.globalPosition),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 32,
                                    child: row.dotEntry
                                        ? null
                                        : Checkbox(
                                            value: selected,
                                            onChanged: !_interactive
                                                ? null
                                                : (value) => setState(() {
                                                    if (value == true) {
                                                      _selected.add(row.path);
                                                    } else {
                                                      _selected.remove(
                                                        row.path,
                                                      );
                                                    }
                                                  }),
                                            materialTapTargetSize:
                                                MaterialTapTargetSize
                                                    .shrinkWrap,
                                            visualDensity:
                                                VisualDensity.compact,
                                          ),
                                  ),
                                  Icon(
                                    row.directory
                                        ? Icons.folder_rounded
                                        : Icons.insert_drive_file_outlined,
                                    size: 20,
                                    color: selected
                                        ? AppColors.of(context).onSelection
                                        : row.directory
                                        ? AppColors.of(context).folder
                                        : AppColors.of(context).secondary,
                                  ),
                                  const SizedBox(width: 11),
                                  Expanded(
                                    child: GestureDetector(
                                      key: ValueKey('drag:${row.path}'),
                                      behavior: HitTestBehavior.opaque,
                                      onPanStart: !_interactive || row.dotEntry
                                          ? null
                                          : (_) => _startArchiveDrag(row),
                                      child: Text(
                                        _query.isEmpty
                                            ? p.posix.basename(row.path)
                                            : row.path,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: selected
                                              ? AppColors.of(context)
                                                    .onSelection
                                              : AppColors.of(context).text,
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (entry?.encrypted == true)
                                    Padding(
                                      padding: const EdgeInsets.only(right: 8),
                                      child: Icon(
                                        Icons.lock_outline,
                                        size: 13,
                                        color: selected
                                            ? AppColors.of(context).onSelection
                                            : AppColors.of(context).secondary,
                                      ),
                                    ),
                                  _cell(
                                    row.directory
                                        ? '—'
                                        : _size(entry?.size ?? 0),
                                    92,
                                    selected: selected,
                                  ),
                                  if (showPacked)
                                    _cell(
                                      row.directory || entry?.packed == 0
                                          ? '—'
                                          : _size(entry?.packed ?? 0),
                                      92,
                                      selected: selected,
                                    ),
                                  if (showType)
                                    _cell(
                                      row.directory
                                          ? '文件夹'
                                          : _fileType(row.path),
                                      76,
                                      selected: selected,
                                    ),
                                  if (showModified)
                                    _cell(
                                      _date(entry?.modified ?? 0),
                                      135,
                                      selected: selected,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Container(
              height: 26,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: AppColors.of(context).border),
                ),
              ),
              child: Row(
                children: [
                  Text(
                    '${_entries.where((entry) => !entry.directory).length} 个文件',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.of(context).secondary,
                    ),
                  ),
                  const SizedBox(width: 24),
                  Text(
                    '原始大小 ${_size(total)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.of(context).secondary,
                    ),
                  ),
                  const Spacer(),
                  if (_selected.isNotEmpty)
                    Text(
                      '已选 ${_selected.length} 项',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.of(context).accent,
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _sortHeader(String label, String column) => InkWell(
    key: ValueKey('sort:$column'),
    onTap: () => setState(() {
      if (_sortColumn == column) {
        _sortAscending = !_sortAscending;
      } else {
        _sortColumn = column;
        _sortAscending = true;
      }
    }),
    child: SizedBox(
      height: 28,
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.of(context).secondary,
            ),
          ),
          if (_sortColumn == column)
            Padding(
              padding: const EdgeInsets.only(left: 3),
              child: Icon(
                _sortAscending ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                size: 17,
                color: AppColors.of(context).accent,
              ),
            ),
        ],
      ),
    ),
  );

  Widget _cell(String text, double width, {bool selected = false}) => SizedBox(
    width: width,
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 11,
        color: selected
            ? AppColors.of(context).onSelection
            : AppColors.of(context).secondary,
      ),
    ),
  );

  Widget _progressPanel() => Container(
    padding: const EdgeInsets.fromLTRB(14, 8, 12, 8),
    color: AppColors.of(context).tint,
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    _cancelling ? '正在取消…' : _task,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.of(context).onTint,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _progress == null
                        ? '准备中…'
                        : '${(_progress! * 100).toStringAsFixed(0)}%',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.of(context).onTint,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 7),
              LinearProgressIndicator(
                value: _progress,
                minHeight: 4,
                borderRadius: BorderRadius.circular(4),
              ),
              if (_currentFile.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: Text(
                    _currentFile,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      color: AppColors.of(context).onTint,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 20),
        TextButton(
          onPressed: _cancelling
              ? null
              : () {
                  _engine?.cancel();
                  setState(() => _cancelling = true);
                },
          child: const Text('取消'),
        ),
      ],
    ),
  );

  Widget _statusbar() => Container(
    height: 24,
    padding: const EdgeInsets.symmetric(horizontal: 16),
    decoration: BoxDecoration(
      color: AppColors.of(context).canvas,
      border: Border(top: BorderSide(color: AppColors.of(context).border)),
    ),
    child: Row(
      children: [
        Icon(
          _busy ? Icons.sync : Icons.circle,
          size: _busy ? 13 : 6,
          color: _busy
              ? AppColors.of(context).accent
              : Theme.of(context).colorScheme.tertiary,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            _status,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10,
              color: AppColors.of(context).secondary,
            ),
          ),
        ),
        if (_lastOutput != null && !_busy)
          TextButton(
            onPressed: () => _desktop.invokeMethod<void>('reveal', _lastOutput),
            child: const Text('查看结果', style: TextStyle(fontSize: 10)),
          ),
        Text(
          'macOS · 0.2.2',
          style: TextStyle(
            fontSize: 10,
            color: AppColors.of(context).secondary,
          ),
        ),
      ],
    ),
  );

  Future<void> _about() async {
    final licenses = _engine == null
        ? ''
        : p.normalize(
            p.join(
              _engine!.directory,
              '..',
              '..',
              'Resources',
              'F7ZipLicenses',
            ),
          );
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('F7Zip 0.2.2'),
        content: const SizedBox(
          width: 400,
          child: SelectableText(
            '开源 macOS 压缩工具\n\nFlutter 界面 · 7-Zip 26.06 原生引擎\nbit7z 4.0.10 C++ 封装\n\nF7Zip 使用 MIT 许可证。\n7-Zip 遵循 LGPL、BSD 及 unRAR 限制。\nbit7z 遵循 MPL-2.0。\n\n支持 ZIP / 7z / TAR / GZIP / XZ / BZIP2 创建，ZIP / 7z 编辑回写，多格式浏览与解压。',
          ),
        ),
        actions: [
          if (licenses.isNotEmpty)
            TextButton(
              onPressed: () => _desktop.invokeMethod<void>('reveal', licenses),
              child: const Text('第三方许可证'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}

class _ArchiveDragSession {
  _ArchiveDragSession({
    required this.id,
    required this.archive,
    required this.version,
    required this.password,
    required this.codePage,
    required List<ArchiveDragItem> items,
  }) : items = {for (final item in items) item.id: item},
       remaining = items.map((item) => item.id).toSet();
  final String id;
  final String archive;
  final String version;
  String password;
  final int codePage;
  final Map<String, ArchiveDragItem> items;
  final Set<String> remaining;
  final Set<String> claimed = {};
  bool cancelled = false;
  bool ended = false;
  Timer? expiry;
}

class _VisibleEntry {
  const _VisibleEntry(
    this.path,
    this.directory,
    this.entry, {
    this.dotEntry = false,
  });
  final String path;
  final bool directory;
  final ArchiveEntry? entry;
  final bool dotEntry;
}

class _CompressionOptions {
  const _CompressionOptions(
    this.format,
    this.level,
    this.password, {
    this.volumeSize = 0,
    this.encryption = 'AES256',
    this.encryptNames = true,
  });
  final String format;
  final int level;
  final String password;
  final int volumeSize;
  final String encryption;
  final bool encryptNames;
}

class _CompressionDialog extends StatefulWidget {
  const _CompressionDialog({
    required this.inputs,
    required this.settings,
    required this.onPresetsChanged,
  });
  final List<String> inputs;
  final AppSettings settings;
  final Future<void> Function(List<CompressionPreset>, String) onPresetsChanged;
  @override
  State<_CompressionDialog> createState() => _CompressionDialogState();
}

class _CompressionDialogState extends State<_CompressionDialog> {
  String _format = 'zip';
  String _volume = 'none';
  final _customVolume = TextEditingController();
  int? get _volumeSize {
    if (!_supportsPassword || _volume == 'none') return 0;
    final mib = int.tryParse(
      _volume == 'custom' ? _customVolume.text.trim() : _volume,
    );
    if (mib == null || mib < 1 || mib > 2097151) return null;
    return mib * 1024 * 1024;
  }

  int _level = 5;
  String _encryption = 'AES256';
  bool _encryptNames = true;
  final _password = TextEditingController();
  bool _showPassword = false;
  bool get _supportsPassword => _format == 'zip' || _format == '7z';
  bool get _singleFileFormat => const {'gz', 'xz', 'bz2'}.contains(_format);
  bool get _validInput =>
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
    _presets = widget.settings.compressionPresets.toList();
    _defaultPreset = widget.settings.defaultCompressionPreset;
    final initial = _presets
        .where((preset) => preset.name == _defaultPreset)
        .firstOrNull;
    if (initial != null) _loadPreset(initial);
  }

  void _loadPreset(CompressionPreset preset) {
    _presetRevision++;
    _presetName = preset.name;
    _format = preset.format;
    _level = preset.level;
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
      await widget.onPresetsChanged(presets, defaultName);
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

  @override
  void dispose() {
    _customVolume.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('新建压缩包'),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
                    initialValue: _level,
                    decoration: const InputDecoration(labelText: '压缩等级'),
                    items: const [
                      DropdownMenuItem(value: 0, child: Text('仅存储')),
                      DropdownMenuItem(value: 1, child: Text('最快')),
                      DropdownMenuItem(value: 5, child: Text('标准')),
                      DropdownMenuItem(value: 7, child: Text('最大')),
                      DropdownMenuItem(value: 9, child: Text('极限')),
                    ],
                    onChanged: _savingPreset || _format == 'tar'
                        ? null
                        : (value) => _changeOptions(() => _level = value!),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_supportsPassword) ...[
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
            if (_supportsPassword)
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
            if (_format == 'zip')
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
            if (_format == '7z')
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('同时加密文件名'),
                value: _encryptNames,
                onChanged: _savingPreset
                    ? null
                    : (value) => _changeOptions(() => _encryptNames = value!),
              ),
            const SizedBox(height: 12),
            Text(
              !_validInput
                  ? '此格式需要选择一个普通文件。多个文件或文件夹可选择 ZIP、7z 或 TAR。'
                  : switch (_format) {
                      '7z' => '7z 使用 AES-256。填写密码后启用加密。',
                      'zip' => '填写密码后启用所选加密算法。ZIP 密码请使用 ASCII 字符。',
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
            : () => Navigator.pop(
                context,
                _CompressionOptions(
                  _format,
                  _level,
                  _supportsPassword ? _password.text : '',
                  volumeSize: _volumeSize!,
                  encryption: _encryption,
                  encryptNames: _encryptNames,
                ),
              ),
        child: const Text('选择保存位置'),
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

String _extractionDestination(String parent, String archive) {
  final stem = _archiveStem(archive);
  var destination = p.join(parent, stem);
  var suffix = 2;
  while (FileSystemEntity.typeSync(destination, followLinks: false) !=
          FileSystemEntityType.notFound &&
      FileSystemEntity.typeSync(destination, followLinks: false) !=
          FileSystemEntityType.directory) {
    destination = p.join(parent, '$stem ($suffix)');
    suffix++;
  }
  return destination;
}

String _archiveStem(String path) {
  var name = p
      .basename(path)
      .replaceFirst(RegExp(r'\.[0-9]{3,}$'), '')
      .replaceFirst(RegExp(r'\.part[0-9]+\.rar$', caseSensitive: false), '.rar')
      .replaceFirst(RegExp(r'\.z[0-9]{2,}$', caseSensitive: false), '.zip')
      .replaceFirst(RegExp(r'\.r[0-9]{2,}$', caseSensitive: false), '.rar');
  for (final suffix in [
    '.tar.gz',
    '.tar.bz2',
    '.tar.xz',
    '.zip',
    '.7z',
    '.rar',
    '.tar',
    '.gz',
    '.xz',
    '.bz2',
    '.tgz',
    '.tbz',
    '.tbz2',
    '.txz',
    '.iso',
    '.zst',
  ]) {
    if (name.toLowerCase().endsWith(suffix)) {
      name = name.substring(0, name.length - suffix.length);
      break;
    }
  }
  return name.isEmpty || name == '.' || name == '..' ? 'Extracted' : name;
}

String _size(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
}

String _date(int seconds) {
  if (seconds == 0) return '—';
  final time = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
}

String _fileType(String path) {
  final extension = p.posix.extension(path);
  return extension.isEmpty
      ? '文件'
      : '${extension.substring(1).toUpperCase()} 文件';
}
