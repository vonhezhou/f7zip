import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'window_chrome.dart';
import 'archive_engine.dart';
import 'archive_backup.dart';
import 'archive_drag.dart';
import 'archive_task.dart';
import 'archive_task_panel.dart';
import 'archive_preview.dart';
import 'nested_archive.dart';
import 'archive_tree.dart';
import 'app_settings.dart';
import 'edit_workspace.dart';
import 'app_theme.dart';
import 'compression_preset.dart';
import 'compression_dialog.dart';
import 'welcome_panel.dart';
import 'checksum_dialog.dart';
import 'password_recovery_dialog.dart';

const _desktop = MethodChannel('sevenzip/desktop');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDesktopWindow();
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
  CustomColorTheme? _customTheme;

  void _applySettings(AppSettings settings) {
    if (_themeMode != settings.themeMode ||
        _colorTheme != settings.colorTheme ||
        _customTheme != settings.customTheme) {
      setState(() {
        _themeMode = settings.themeMode;
        _colorTheme = settings.colorTheme;
        _customTheme = settings.customTheme;
      });
    }
    _desktop.invokeMethod<void>('setAppearance', settings.themeMode.name);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'F7Zip',
    debugShowCheckedModeBanner: false,
    theme: buildAppTheme(
      Brightness.light,
      colorTheme: _colorTheme,
      customTheme: _customTheme,
    ),
    darkTheme: buildAppTheme(
      Brightness.dark,
      colorTheme: _colorTheme,
      customTheme: _customTheme,
    ),
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
  bool _commentEditable = false;
  bool _openingFile = false;
  bool _tryingPasswords = false;
  final Map<String, String> _operationPasswords = {};
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
  bool _checksumDialogOpen = false;
  bool _dragging = false;
  bool _cancelling = false;
  List<ArchiveEntry> _entries = [];
  ArchiveTreeNode _tree = buildArchiveTree([]);
  final List<ArchiveTask> _archiveTasks = [];
  ArchiveTask? _activeQueuedTask;
  int _nextTaskId = 0;
  bool _showTasks = false;
  Timer? _finderTimer;
  bool _handlingFinderRequest = false;
  final Set<String> _selected = {};
  final List<String> _recent = [];
  final _search = TextEditingController();
  final _fileList = ScrollController();
  final _moreMenuFocus = FocusNode();
  Timer? _timer;
  final Map<String, _ArchiveDragSession> _dragSessions = {};
  Future<void> _dragExports = Future.value();
  Completer<void>? _activeOperation;
  String? _activeDragId;
  int _pendingDragWrites = 0;
  bool _exportingDrag = false;
  final Map<String, String> _previewDirectories = {};
  final List<ArchiveParent> _archiveParents = [];
  final Set<String> _nestedDirectories = {};

  bool get _engineAvailable =>
      _desktopReady && !_busy && !_choosing && _engine != null;
  bool get _available => _engineAvailable && !_exportingDrag;

  bool get _interactive =>
      _available &&
      !_openingFile &&
      !_mutating &&
      !_tryingPasswords &&
      !_checksumDialogOpen;

  @override
  void initState() {
    super.initState();
    try {
      _engine = ArchiveEngine();
    } catch (error) {
      _engineError = '$error';
    }
    _desktop.setMethodCallHandler((call) async {
      if (call.method == 'archivePreviewClosed') {
        final arguments = call.arguments as Map;
        await _releasePreview(arguments['id'] as String);
      }
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
                !_tryingPasswords &&
                !Navigator.of(context).canPop(),
            canTryPasswords: () => _preferences.autoTryPasswords,
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
    _moreMenuFocus.dispose();
    _timer?.cancel();
    _finderTimer?.cancel();
    _edits?.close();
    _engine?.cancel();
    _operationPasswords.clear();
    for (final session in _dragSessions.values) {
      session.cancelled = true;
      session.expiry?.cancel();
    }
    _dragSessions.clear();
    unawaited(_clearNestedArchives());
    final previews = Map<String, String>.from(_previewDirectories);
    _previewDirectories.clear();
    unawaited(
      _desktop
          .invokeMethod<void>('closeArchivePreviews', previews.keys.toList())
          .then((_) async {
            for (final directory in previews.values) {
              await _desktop.invokeMethod<void>(
                'discardArchivePreviewDirectory',
                directory,
              );
            }
          })
          .catchError((Object error) {}),
    );
    _search.dispose();
    _fileList.dispose();
    _desktop.setMethodCallHandler(null);
    super.dispose();
  }

  void _enqueueFinderRequest(Map<String, dynamic> request) {
    if (!mounted) return;
    final action = request['action'] as String;
    if (!const [
      'open',
      'compress',
      'compressZip',
      'extract',
      'extractHere',
      'extractTo',
      'batchExtract',
      'test',
    ].contains(action)) {
      return;
    }
    final paths = (request['paths'] as List).cast<String>();
    final destination = ArchiveTaskDestination();
    if (request['destination'] is String) {
      destination.chosen = true;
      destination.path = request['destination'] as String;
    }
    final groups =
        const ['compress', 'compressZip'].contains(action) || paths.isEmpty
        ? [paths]
        : paths.map((path) => [path]);
    setState(() {
      for (final group in groups) {
        _archiveTasks.add(
          ArchiveTask(
            id: ++_nextTaskId,
            action: action,
            paths: List.unmodifiable(group),
            fromFinder: request['fromFinder'] != false,
            destination: destination,
          ),
        );
      }
      if (action != 'open') _showTasks = true;
      _trimArchiveTaskHistory();
    });
    _scheduleArchiveTasks();
  }

  void _trimArchiveTaskHistory() {
    // 只裁剪已结束的历史，保留全部等待和执行中的任务。
    while (_archiveTasks.where((task) => task.finished).length > 100) {
      _archiveTasks.remove(_archiveTasks.firstWhere((task) => task.finished));
    }
  }

  void _scheduleArchiveTasks() {
    _finderTimer ??= Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => _processFinderRequests(),
    );
    _processFinderRequests();
  }

  void _cancelArchiveTask(ArchiveTask task) {
    if (task.finished) return;
    setState(() {
      task.cancelRequested = true;
      if (task.state == ArchiveTaskState.queued) {
        task.state = ArchiveTaskState.cancelled;
      } else {
        _engine?.cancel();
        _cancelling = true;
      }
    });
  }

  void _retryArchiveTask(ArchiveTask task) {
    if (!task.finished || task.state == ArchiveTaskState.succeeded) return;
    setState(() {
      task.state = ArchiveTaskState.queued;
      task.cancelRequested = false;
      task.error = null;
      task.output = null;
      task.progress = null;
      task.file = '';
      task.phase = '';
      if (task.destination.path == null) task.destination.chosen = false;
      _archiveTasks.remove(task);
      _archiveTasks.add(task);
    });
    _scheduleArchiveTasks();
  }

  Future<void> _processFinderRequests() async {
    if (!mounted ||
        _handlingFinderRequest ||
        !_interactive ||
        Navigator.of(context).canPop()) {
      return;
    }
    _handlingFinderRequest = true;
    try {
      while (mounted && _interactive && !Navigator.of(context).canPop()) {
        final pending = _archiveTasks.where(
          (task) => task.state == ArchiveTaskState.queued,
        );
        if (pending.isEmpty) break;
        final task = pending.first;
        setState(() {
          task.state = ArchiveTaskState.running;
          _activeQueuedTask = task;
        });
        var succeeded = false;
        try {
          succeeded = await _executeArchiveTask(task);
        } catch (error) {
          task.error = '$error';
          if (task.fromFinder && !task.cancelRequested) {
            await _desktop.invokeMethod<void>('finderError', '$error');
          }
        } finally {
          if (mounted) {
            setState(() {
              task.state = succeeded
                  ? ArchiveTaskState.succeeded
                  : task.cancelRequested || task.error == null
                  ? ArchiveTaskState.cancelled
                  : ArchiveTaskState.failed;
              if (succeeded) task.progress = 1;
              _activeQueuedTask = null;
              _trimArchiveTaskHistory();
            });
          }
        }
      }
    } finally {
      _handlingFinderRequest = false;
      if (!_archiveTasks.any((task) => task.state == ArchiveTaskState.queued)) {
        _finderTimer?.cancel();
        _finderTimer = null;
      }
    }
  }

  Future<bool> _executeArchiveTask(ArchiveTask task) async {
    switch (task.action) {
      case 'compress':
        return _create(task.paths);
      case 'compressZip':
        return _finderCompressZip(task.paths);
      case 'extractTo':
        if (!task.destination.chosen) {
          task.destination.chosen = true;
          setState(() => _choosing = true);
          try {
            task.destination.path = await _desktop.invokeMethod<String>(
              'finderChooseFolder',
            );
          } finally {
            if (mounted) setState(() => _choosing = false);
          }
        }
        if (task.destination.path == null || task.cancelRequested || !mounted) {
          return false;
        }
        return _finderExtract(
          task.paths,
          chooseFolder: true,
          chosenParent: task.destination.path,
        );
      case 'batchExtract':
        return _finderExtract(
          task.paths,
          chooseFolder: true,
          chosenParent: task.destination.path,
          separate: true,
          finder: false,
        );
      case 'extractHere':
        return _finderExtract(task.paths, chooseFolder: false);
      case 'extract':
        if (task.paths.isEmpty || !await _open(task.paths.single)) return false;
        return _extract(besideArchive: true);
      case 'open':
        return task.paths.isNotEmpty && await _open(task.paths.single);
      case 'test':
        var password = '';
        while (mounted && !task.cancelRequested) {
          try {
            return await _run(
                  '完整性测试',
                  ArchiveRequest(
                    'test',
                    task.paths.single,
                    password: password,
                    codePage: _preferences.filenameEncoding.codePage,
                  ),
                ) !=
                null;
          } on ArchiveFailure catch (error) {
            if (!error.passwordRequired) rethrow;
            final value = await _askPassword(error: error.message);
            if (value == null || !mounted) return false;
            password = value;
          }
        }
        return false;
    }
    return false;
  }

  Future<void> _enqueueBatch(String action) async {
    if (!_desktopReady || _choosing || Navigator.of(context).canPop()) return;
    setState(() => _choosing = true);
    try {
      final paths =
          await _desktop.invokeListMethod<String>('chooseArchives') ?? [];
      if (paths.isEmpty || !mounted) return;
      String? destination;
      if (action == 'batchExtract') {
        final directories =
            await _desktop.invokeListMethod<String>('chooseFolder') ?? [];
        if (directories.isEmpty || !mounted) return;
        destination = directories.first;
      }
      _enqueueFinderRequest({
        'action': action,
        'paths': paths,
        'fromFinder': false,
        'destination': ?destination,
      });
    } finally {
      if (mounted) {
        setState(() => _choosing = false);
        _processFinderRequests();
      }
    }
  }

  Future<bool> _finderCompressZip(List<String> paths) async {
    if (paths.isEmpty) return false;
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
    return result != null;
  }

  Future<bool> _finderExtract(
    List<String> paths, {
    required bool chooseFolder,
    String? chosenParent,
    bool separate = false,
    bool finder = true,
  }) async {
    final parent = chosenParent;
    if (chooseFolder && parent == null) return false;
    for (final path in paths) {
      var password = '';
      while (mounted) {
        try {
          final result = await _runExtraction(
            path,
            (separate || chooseFolder && _preferences.smartExtraction)
                ? _extractionDestination(parent!, path)
                : parent ?? p.dirname(path),
            password: password,
            codePage: _preferences.filenameEncoding.codePage,
            intoExisting:
                !separate ||
                Directory(_extractionDestination(parent!, path)).existsSync(),
            finder: finder,
            smartDestination: chooseFolder && _preferences.smartExtraction,
          );
          if (result == null || !mounted) return false;
          setState(() {
            _lastOutput = result['path'] as String;
            _status = '解压完成 · ${p.basename(path)}';
          });
          break;
        } on ArchiveFailure catch (error) {
          if (!error.passwordRequired) rethrow;
          String? value;
          if (finder) {
            setState(() => _choosing = true);
            try {
              value = await _desktop.invokeMethod<String>('finderPassword', {
                'path': path,
                if (password.isNotEmpty)
                  'error': '密码错误或加密数据损坏，请重新输入。\n${p.basename(path)}',
              });
            } finally {
              if (mounted) setState(() => _choosing = false);
            }
          } else {
            value = await _askPassword(error: error.message);
          }
          if (value == null || !mounted) {
            _activeQueuedTask?.cancelRequested = true;
            return false;
          }
          password = value;
        }
      }
    }
    return mounted;
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
    if (_tryingPasswords) return null;
    request = request.withPassword(
      request.password,
      filenameNormalization: _preferences.filenameNormalization,
      autoUnpackTar: _preferences.autoUnpackTar,
    );
    final automatic =
        _preferences.autoTryPasswords && request.operation != 'compress';
    if (!automatic) return _runOnce(task, request, dragExport: dragExport);
    _tryingPasswords = true;
    final dragSession = dragExport ? _dragSessions[_activeDragId] : null;
    final attempted = <String>{request.password};
    List<String>? candidates;
    var password = request.password;
    String? keychainError;
    try {
      while (mounted &&
          _activeQueuedTask?.cancelRequested != true &&
          dragSession?.cancelled != true) {
        try {
          return await _runOnce(
            task,
            request.withPassword(password),
            dragExport: dragExport,
          );
        } on ArchiveFailure catch (error) {
          if (!error.passwordRequired) rethrow;
          if (candidates == null) {
            try {
              candidates =
                  await _desktop.invokeListMethod<String>(
                    'archivePasswordCandidates',
                  ) ??
                  [];
            } catch (_) {
              candidates = [];
              keychainError = '钥匙串暂时不可用，请手动输入密码';
            }
          }
          if (!mounted ||
              _activeQueuedTask?.cancelRequested == true ||
              dragSession?.cancelled == true) {
            return null;
          }
          final remaining = candidates.where(
            (value) => value.isNotEmpty && !attempted.contains(value),
          );
          if (remaining.isNotEmpty) {
            password = remaining.first;
            attempted.add(password);
            continue;
          }
          String? value;
          if (dragExport || _activeQueuedTask?.fromFinder == true) {
            setState(() => _choosing = true);
            try {
              value = await _desktop.invokeMethod<String>('finderPassword', {
                'path': request.archive,
                'error': keychainError ?? error.message,
              });
            } finally {
              if (mounted) setState(() => _choosing = false);
            }
          } else {
            value = await _askPassword(
              error: keychainError ?? error.message,
              allowAutomatic: false,
            );
          }
          if (value == null || !mounted) {
            _activeQueuedTask?.cancelRequested = true;
            if (dragSession != null) dragSession.cancelled = true;
            if (mounted) setState(() => _status = '操作已取消');
            return null;
          }
          password = value;
          attempted.add(password);
        }
      }
      return null;
    } finally {
      _tryingPasswords = false;
      if (mounted) setState(() {});
    }
  }

  Future<Map<String, dynamic>?> _runOnce(
    String task,
    ArchiveRequest request, {
    bool dragExport = false,
  }) async {
    if (!_engineAvailable ||
        (_exportingDrag && !dragExport) ||
        _activeQueuedTask?.cancelRequested == true) {
      return null;
    }
    final queued = dragExport ? null : _activeQueuedTask;
    final operation = Completer<void>();
    _activeOperation = operation;
    setState(() {
      _busy = true;
      _cancelling = false;
      _task = task;
      _currentFile = '';
      _progress = null;
      _status = task;
      if (queued != null) {
        queued.phase = task;
        queued.progress = null;
        queued.error = null;
      }
    });
    _timer = Timer.periodic(const Duration(milliseconds: 150), (_) {
      final value = _engine?.progress();
      if (!mounted || value == null) return;
      final total = value['total'] as int;
      final completed = value['completed'] as int;
      setState(() {
        _progress = total == 0 ? null : (completed / total).clamp(0.0, 1.0);
        _currentFile = value['file'] as String;
        queued?.progress = _progress;
        queued?.file = _currentFile;
      });
    });
    try {
      final result = await _engine!.run(request);
      if (!const {
        'checksum',
        'checksumSave',
        'checksumVerify',
        'splitFile',
        'joinFile',
        'partsInfo',
        'passwordSearch',
        'passwordSearchInfo',
        'repairZip',
        'trash',
      }.contains(request.operation)) {
        _operationPasswords.remove(request.archive);
        _operationPasswords[request.archive] = request.password;
        if (_operationPasswords.length > 32) {
          _operationPasswords.remove(_operationPasswords.keys.first);
        }
      }
      if (mounted) {
        setState(() {
          _status = '$task完成';
          queued?.error = null;
          if (result['path'] is String) {
            queued?.output = result['path'] as String;
          }
        });
      }
      return result;
    } on ArchiveFailure catch (error) {
      queued?.error = error.cancelled || error.passwordRequired
          ? null
          : error.message;
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
    if (_activeQueuedTask != null ||
        (_tryingPasswords && _activeDragId == null)) {
      throw PlatformException(code: 'busy', message: '请等待当前队列任务完成后重新拖出');
    }
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
        if (item.encrypted &&
            session.password.isEmpty &&
            !_preferences.autoTryPasswords) {
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
          session.password =
              _operationPasswords[session.archive] ?? session.password;
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

  Future<String?> _askPassword({
    String? error,
    bool allowAutomatic = true,
  }) async {
    if (allowAutomatic && error == null && _preferences.autoTryPasswords) {
      return '';
    }
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
    if (result == null) _activeQueuedTask?.cancelRequested = true;
    return result;
  }

  Future<bool> _open(
    String path, {
    String password = '',
    bool nested = false,
    int? codePage,
  }) async {
    if (!_interactive) return false;
    _openingFile = true;
    try {
      if (!await File(path).exists()) {
        _activeQueuedTask?.error = '压缩包不存在或已被移动。\n$path';
        await _error('压缩包不存在或已被移动。\n$path');
        return false;
      }
      final sessions =
          _edits?.sessions
              .where((session) => session.archive == path)
              .toList() ??
          [];
      final requested = codePage ?? _preferences.filenameEncoding.codePage;
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
      final resolvedCodePage = result['codePage'] as int? ?? 0;
      if (_edits?.sessions.any(
            (session) =>
                session.archive == path &&
                session.codePage != 0 &&
                session.codePage != resolvedCodePage,
          ) ??
          false) {
        await _error('此压缩包仍有外部编辑会话，请结束监控后再切换文件名编码');
        return false;
      }
      final items = (result['items'] as List)
          .map((item) => ArchiveEntry.fromJson(item as Map<String, dynamic>))
          .toList();
      if (!nested) await _clearNestedArchives();
      if (!mounted) return false;
      setState(() {
        _archive = path;
        _archiveCodePage = resolvedCodePage;
        _volumeCount = result['volumes'] as int? ?? 1;
        _password = _operationPasswords[_archive] ?? password;
        _archiveVersion = result['version'] as String;
        _archiveComment = result['comment'] as String? ?? '';
        _editable = !nested && result['editable'] == true;
        _commentEditable = !nested && result['commentEditable'] == true;
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
        if (!nested) {
          _recent.remove(path);
          _recent.insert(0, path);
          if (_recent.length > 8) _recent.removeLast();
        }
        _status = '已打开 ${p.basename(path)}';
      });
      if (!nested) {
        unawaited(_desktop.invokeMethod<void>('rememberArchive', path));
      }
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
        _openingFile = false;
        return await _open(
          path,
          password: retry,
          nested: nested,
          codePage: codePage,
        );
      }
      return false;
    } finally {
      _openingFile = false;
      if (mounted) setState(() {});
    }
  }

  Future<bool> _extract({
    bool selectedOnly = false,
    bool besideArchive = false,
    bool trashSource = false,
  }) async {
    final archive = _archive;
    if (!_interactive ||
        archive == null ||
        (selectedOnly && _selected.isEmpty)) {
      return false;
    }
    if (trashSource) {
      if (selectedOnly ||
          _archiveParents.isNotEmpty ||
          (_edits?.sessions.any((session) => session.archive == archive) ??
              false)) {
        await _error('请先结束此压缩包的外部编辑监控，并在顶层归档执行完整解压。');
        return false;
      }
      if (!await _confirm(
        '解压成功后移至废纸篓？',
        '完整解压成功后，将把 ${p.basename(archive)} 移至 macOS 废纸篓。跳过同名文件、分卷、失败或取消时保留源包。',
      )) {
        return false;
      }
    }
    var password = _password;
    if (password.isEmpty && _entries.any((entry) => entry.encrypted)) {
      final value = await _askPassword();
      if (value == null || !mounted) return false;
      password = value;
    }
    String parent;
    if (besideArchive && _archiveParents.isEmpty) {
      parent = p.dirname(archive);
    } else {
      final paths = await _choose('chooseFolder');
      if (paths.isEmpty) return false;
      parent = paths.first;
    }
    if (!mounted || !_available) return false;
    final destination = _extractionDestination(parent, archive);
    final indices = selectedOnly
        ? _entries
              .where((entry) => entry.isSelectedBy(_selected))
              .map((entry) => entry.index)
              .toList()
        : <int>[];
    setState(() => _mutating = true);
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
          _password = _operationPasswords[_archive] ?? password;
          _lastOutput = result['path'] as String;
          _status = '解压完成 · $_lastOutput';
        });
        if (trashSource) {
          if (result['complete'] != true) {
            setState(() => _status = '解压完成，已保留源包（跳过同名文件或分卷归档） · $_lastOutput');
          } else {
            try {
              final recycled = await _run(
                '移至废纸篓',
                ArchiveRequest(
                  'trash',
                  archive,
                  expectedVersion: result['version'] as String,
                ),
              );
              if (recycled != null && mounted) {
                setState(() => _status = '解压完成，原包已移至废纸篓 · $_lastOutput');
                _mutating = false;
                _closeArchive();
              } else if (mounted) {
                setState(() => _status = '解压完成，已保留源包 · $_lastOutput');
              }
            } catch (error) {
              if (mounted) {
                setState(() => _status = '解压完成，源包回收未完成 · $_lastOutput');
              }
              await _error('解压结果已保存。源包移至废纸篓失败，请核对后手动处理。\n$error');
            }
          }
        }
      }
      return result != null;
    } catch (error) {
      await _error(error);
      return false;
    } finally {
      if (mounted) setState(() => _mutating = false);
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
          _activeQueuedTask?.cancelRequested = true;
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
          _password = _operationPasswords[_archive] ?? password;
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

  Future<bool> _create([List<String>? dropped]) async {
    if (!_interactive) return false;
    final inputs = dropped ?? await _choose('chooseInputs');
    if (inputs.isEmpty || !mounted) return false;
    final options = await showDialog<CompressionOptions>(
      context: context,
      builder: (_) => CompressionDialog(
        inputs: inputs,
        presets: _preferences.compressionPresets,
        defaultPreset: _preferences.defaultCompressionPreset,
        onPresetsChanged: _saveCompressionPresets,
      ),
    );
    if (options == null || !mounted || !_available) return false;
    setState(() => _choosing = true);
    String? destination;
    try {
      destination = await _desktop.invokeMethod<String>(
        'saveArchive',
        '${p.basenameWithoutExtension(inputs.first)}.${options.format == 'sfx' ? 'exe' : options.format}',
      );
    } finally {
      if (mounted) setState(() => _choosing = false);
    }
    if (destination == null || !mounted) return false;
    final extension = options.format == 'sfx' ? 'exe' : options.format;
    if (!destination.toLowerCase().endsWith('.$extension')) {
      destination += '.$extension';
    }
    try {
      final result = await _run(
        '压缩',
        ArchiveRequest(
          'compress',
          destination,
          inputs: inputs,
          format:
              const {'zip', 'zipx'}.contains(options.format) &&
                  options.encryption == 'AES256'
              ? '${options.format}-aes256'
              : const {'7z', 'sfx'}.contains(options.format) &&
                    !options.encryptNames
              ? '${options.format}-visible'
              : options.format,
          level: options.level,
          parameters: options.parameters,
          volumeSize: options.volumeSize,
          password: options.password,
        ),
      );
      if (result == null || !mounted) return false;
      final output = result['path'] as String;
      _lastOutput = output;
      await _open(output, password: options.password);
      return true;
    } catch (error) {
      await _error(error);
      return false;
    }
  }

  Future<void> _drop(List<String> paths) async {
    if (!_available || paths.isEmpty) return;
    final extension = p.extension(paths.first).toLowerCase();
    if (paths.length == 1 &&
        (const [
              '.zip',
              '.exe',
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
    if (const {
          'restore',
          'updateNewer',
          'updateExisting',
          'syncDirectory',
        }.contains(operation) &&
        (_edits?.sessions.any((session) => session.archive == _archive) ??
            false)) {
      await _error('此压缩包正在外部编辑，请先在“管理编辑文件”中结束全部监控');
      return false;
    }
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
            'restore': '恢复原包备份',
            'updateNewer': '按时间更新',
            'updateExisting': '仅更新已有条目',
            'syncDirectory': '同步目录',
            'fileComment': '编辑文件注释',
            'archiveComment': '编辑归档注释',
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
            _password = _operationPasswords[_archive] ?? password;
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

  Future<void> _recoverPassword() async {
    if (!_interactive) return;
    setState(() => _mutating = true);
    try {
      final paths = await _choose('openArchive');
      if (paths.isEmpty || !mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PasswordRecoveryDialog(
          archive: paths.single,
          codePage: _preferences.filenameEncoding.codePage,
          run: (request) => _runOnce('搜索归档密码', request),
          cancel: () => _engine?.cancel(),
        ),
      );
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  Future<void> _repairZip() async {
    if (!_interactive) return;
    setState(() => _mutating = true);
    try {
      final paths = await _choose('openArchive');
      if (paths.isEmpty || !mounted) return;
      if (!await _confirm(
            '修复 ZIP 到新文件',
            '扫描小于 4 GiB 的经典单卷 ZIP，逐项校验后重建目录，原包保留。\n'
                'ZIP64 暂不支持。损坏、越界及重复条目会跳过，单项最多 512 MiB、总量最多 2 GiB。\n'
                '仅中央目录记录的注释、权限和链接属性无法恢复，加密数据保持原样并需要密码验证。',
          ) ||
          !mounted) {
        return;
      }
      setState(() => _choosing = true);
      String? output;
      try {
        output = await _desktop.invokeMethod<String>(
          'saveArchive',
          '${p.basenameWithoutExtension(paths.single)}-repaired.zip',
        );
      } finally {
        if (mounted) setState(() => _choosing = false);
      }
      if (output == null || !mounted) return;
      var password = _operationPasswords[paths.single] ?? '';
      while (mounted) {
        try {
          final result = await _run(
            '扫描并修复 ZIP',
            ArchiveRequest(
              'repairZip',
              paths.single,
              destination: output,
              password: password,
              codePage: _preferences.filenameEncoding.codePage,
            ),
          );
          if (result == null || !mounted) return;
          setState(() {
            _lastOutput = result['path'] as String;
            _status =
                'ZIP 修复完成 · 恢复 ${result['recovered']} 项，跳过 ${result['rejected']} 项';
          });
          final skipped = result['skipped'] as List;
          if (skipped.isNotEmpty) {
            await _error(
              '已保存修复结果，以下候选未通过检查（最多显示 20 项）\n\n'
              '${skipped.take(20).map((item) => '${item['entry']}\n${item['error']}').join('\n\n')}',
            );
          }
          return;
        } on ArchiveFailure catch (error) {
          if (!error.passwordRequired) rethrow;
          final value = await _askPassword(error: error.message);
          if (value == null || !mounted) return;
          password = value;
        }
      }
    } catch (error) {
      await _error(error);
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  Future<void> _filePartsTool({required bool join}) async {
    if (!_interactive) return;
    setState(() => _mutating = true);
    try {
      if (join) {
        await _joinPlainFile();
      } else {
        await _splitPlainFile();
      }
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  Future<void> _splitPlainFile() async {
    final paths = await _choose('openArchive');
    if (paths.isEmpty || !mounted) return;
    final controller = TextEditingController(text: '100');
    final size = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, refresh) {
          final mib = int.tryParse(controller.text.trim());
          final valid = mib != null && mib >= 1 && mib <= 2097151;
          return AlertDialog(
            title: const Text('分割普通文件'),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.basename(paths.single)),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('filePartSize'),
                    controller: controller,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => refresh(() {}),
                    decoration: InputDecoration(
                      labelText: '每片大小（MiB）',
                      errorText: valid ? null : '请输入 1–2097151 的整数',
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '生成 .001、.002 等分片及 SHA-256 清单，合并时需要完整分片和清单，最多 10000 片。',
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
                onPressed: valid
                    ? () => Navigator.pop(context, mib * 1048576)
                    : null,
                child: const Text('选择输出名称'),
              ),
            ],
          );
        },
      ),
    );
    Future<void>.delayed(const Duration(seconds: 1), controller.dispose);
    if (size == null || !mounted) return;
    setState(() => _choosing = true);
    String? output;
    try {
      output = await _desktop.invokeMethod<String>(
        'saveArchive',
        '${p.basename(paths.single)}.part',
      );
    } finally {
      if (mounted) setState(() => _choosing = false);
    }
    if (output == null || !mounted) return;
    try {
      final result = await _runOnce(
        '分割文件',
        ArchiveRequest(
          'splitFile',
          paths.single,
          destination: output,
          volumeSize: size,
        ),
      );
      if (result != null && mounted) {
        setState(() {
          _lastOutput = result['path'] as String;
          _status = '文件分割完成 · ${result['count']} 片，已保存校验清单';
        });
      }
    } catch (error) {
      await _error(error);
    }
  }

  Future<void> _joinPlainFile() async {
    final paths = await _choose('openArchive');
    if (paths.isEmpty || !mounted) return;
    try {
      final info = await _runOnce(
        '读取分片清单',
        ArchiveRequest('partsInfo', paths.single),
      );
      if (info == null || !mounted) return;
      if (!await _confirm(
            '合并普通文件',
            '${info['name']} · ${info['count']} 片 · ${_size(info['size'] as int)}\n'
                '将逐片校验顺序、大小和 SHA-256，再保存合并结果。',
          ) ||
          !mounted) {
        return;
      }
      setState(() => _choosing = true);
      String? output;
      try {
        output = await _desktop.invokeMethod<String>(
          'saveArchive',
          info['name'] as String,
        );
      } finally {
        if (mounted) setState(() => _choosing = false);
      }
      if (output == null || !mounted) return;
      final result = await _runOnce(
        '合并文件',
        ArchiveRequest(
          'joinFile',
          paths.single,
          destination: output,
          expectedVersion: info['version'] as String,
        ),
      );
      if (result != null && mounted) {
        setState(() {
          _lastOutput = result['path'] as String;
          _status = '文件合并完成 · SHA-256 一致';
        });
      }
    } catch (error) {
      await _error(error);
    }
  }

  Future<void> _editComment({bool archive = false}) async {
    if (!_interactive || !_commentEditable) return;
    final entry = archive ? null : _selectedFile;
    if (!archive && entry == null) return;
    final controller = TextEditingController(
      text: archive ? _archiveComment : entry!.comment,
    );
    final comment = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, refresh) {
          final size = utf8.encode(controller.text).length;
          final valid = size <= 16384 && !controller.text.contains('\x00');
          return AlertDialog(
            title: Text(archive ? '编辑归档注释' : '编辑文件注释'),
            content: SizedBox(
              width: 480,
              child: TextField(
                key: const ValueKey('archiveCommentText'),
                controller: controller,
                minLines: 3,
                maxLines: 8,
                autofocus: true,
                onChanged: (_) => refresh(() {}),
                decoration: InputDecoration(
                  labelText: archive ? 'ZIP 归档注释' : entry!.path,
                  helperText: '$size / 16384 UTF-8 字节，留空可清除注释',
                  errorText: valid ? null : '注释超出长度限制或含空字符',
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: valid
                    ? () => Navigator.pop(context, controller.text)
                    : null,
                child: const Text('保存注释'),
              ),
            ],
          );
        },
      ),
    );
    Future<void>.delayed(const Duration(seconds: 1), controller.dispose);
    if (comment == null || !mounted) return;
    await _mutateArchive(
      archive ? 'archiveComment' : 'fileComment',
      item: entry?.path ?? '',
      destination: comment,
    );
  }

  Future<void> _showChecksums() async {
    if (!_interactive) return;
    setState(() => _checksumDialogOpen = true);
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ChecksumDialog(
          archive: _archiveParents.isEmpty ? _archive : null,
          run: (task, request) => _runOnce(task, request),
          cancel: () => _engine?.cancel(),
        ),
      );
    } finally {
      if (mounted) setState(() => _checksumDialogOpen = false);
    }
  }

  Future<void> _updateArchive() async {
    if (!_interactive || !_editable || _archive == null) return;
    if (_edits?.sessions.any((session) => session.archive == _archive) ??
        false) {
      await _error('此压缩包正在外部编辑，请先在“管理编辑文件”中结束全部监控');
      return;
    }
    final mode = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('更新模式'),
        children: [
          for (final (value, title, description) in [
            ('updateNewer', '按时间更新', '添加新条目，替换来源修改时间较新的文件。'),
            ('updateExisting', '仅更新已有条目', '只替换已有且来源修改时间较新的文件。'),
            ('syncDirectory', '同步目录', '以所选文件夹为准，替换对应目录内容并删除来源中已不存在的条目。'),
          ])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, value),
              child: SizedBox(
                width: 390,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title),
                      const SizedBox(height: 4),
                      Text(description, style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    if (mode == null || !mounted) return;
    final paths = await _choose('chooseInputs');
    if (paths.isEmpty || !mounted) return;
    if (mode == 'syncDirectory') {
      if (paths.any(
        (path) =>
            FileSystemEntity.typeSync(path, followLinks: false) !=
            FileSystemEntityType.directory,
      )) {
        await _error('同步目录需要选择实际文件夹');
        return;
      }
      if (!await _confirm(
            '确认同步目录',
            '将在包内 ${_folder.isEmpty ? '根目录' : _folder} 下同步以下同名文件夹。'
                '对应目录内的文件将以来源为准，来源中已不存在的条目会被删除。'
                '修改前会完整备份原包。\n\n${paths.map(p.basename).join('\n')}',
          ) ||
          !mounted) {
        return;
      }
    }
    await _mutateArchive(mode, inputs: paths, item: _folder);
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
      '删除选中的 ${paths.length} 个条目及目录中的文件？修改前会完整备份原包，可通过“更多操作 → 编辑压缩包 → 恢复原包备份”恢复。\n\n${paths.take(8).join('\n')}',
    )) {
      return;
    }
    if (mounted) await _mutateArchive('remove', inputs: paths);
  }

  Future<void> _restoreBackup() async {
    if (!_interactive || !_editable || _archive == null) return;
    final archive = _archive!;
    try {
      final backups = await findArchiveBackups(archive);
      if (!mounted) return;
      if (backups.isEmpty) {
        await _error('此压缩包还没有原包备份。修改前的完整备份会保存在原包同级的独立目录中。');
        return;
      }
      final selected = await showDialog<ArchiveBackup>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('恢复原包备份'),
          content: SizedBox(
            width: 480,
            height: 300,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '选择修改前的完整版本。恢复会替换整个压缩包，当前版本也会先备份。备份占用磁盘空间，可在 Finder 中手动清理。',
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.builder(
                    itemCount: backups.length,
                    itemBuilder: (context, index) {
                      final backup = backups[index];
                      return ListTile(
                        dense: true,
                        title: Text(backup.modified.toLocal().toString()),
                        subtitle: Text(
                          '${backup.size} 字节 · ${p.basename(p.dirname(backup.path))}',
                        ),
                        onTap: () => Navigator.pop(context, backup),
                        trailing: IconButton(
                          tooltip: '在 Finder 显示备份',
                          icon: const Icon(Icons.folder_open_outlined),
                          onPressed: () => _desktop.invokeMethod<void>(
                            'reveal',
                            backup.path,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
          ],
        ),
      );
      if (selected == null || !mounted || _archive != archive) return;
      final listing = await _run(
        '读取备份',
        ArchiveRequest(
          'list',
          selected.path,
          password: _password,
          codePage: _archiveCodePage,
        ),
      );
      if (listing == null || !mounted) return;
      if (!await _confirm(
        '恢复整个压缩包？',
        '将恢复到 ${selected.modified.toLocal()} 的版本，包含当时的全部条目。当前版本将另存备份。',
      )) {
        return;
      }
      if (mounted && _archive == archive) {
        await _mutateArchive(
          'restore',
          item: listing['version'] as String,
          destination: selected.path,
        );
      }
    } catch (error) {
      await _error(error);
    }
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
    unawaited(_clearNestedArchives());
    setState(() {
      _archive = null;
      _entries = [];
      _tree = buildArchiveTree([]);
      _selected.clear();
      _password = '';
      _archiveVersion = '';
      _archiveComment = '';
      _editable = false;
      _commentEditable = false;
      _folder = '';
      _navigation
        ..clear()
        ..add('');
      _navigationIndex = 0;
    });
    _desktop.invokeMethod<void>('setArchiveTitle', '');
  }

  Future<void> _clearRecentArchives() async {
    if (!_interactive || _recent.isEmpty) return;
    setState(() => _choosing = true);
    try {
      await _desktop.invokeMethod<void>('clearRecentArchives');
      if (!mounted) return;
      setState(() {
        _recent.clear();
        _status = '已清空最近打开记录';
      });
    } catch (error) {
      if (mounted) await _error(error);
    } finally {
      if (mounted) setState(() => _choosing = false);
    }
  }

  Future<void> _command(String command) async {
    if (command == 'tasks') {
      setState(() => _showTasks = !_showTasks);
      return;
    }
    if (command == 'batchExtract' || command == 'batchTest') {
      await _enqueueBatch(command == 'batchTest' ? 'test' : command);
      return;
    }
    if (!_interactive || _activeQueuedTask != null) return;
    switch (command) {
      case 'clearRecent':
        await _clearRecentArchives();
        break;
      case 'open':
        await _openDialog();
        break;
      case 'new':
        await _create();
        break;
      case 'add':
        await _addFiles();
        break;
      case 'splitFile':
        await _filePartsTool(join: false);
        break;
      case 'repairZip':
        await _repairZip();
        break;
      case 'recoverPassword':
        await _recoverPassword();
        break;
      case 'joinFile':
        await _filePartsTool(join: true);
        break;
      case 'fileComment':
        await _editComment();
        break;
      case 'archiveComment':
        await _editComment(archive: true);
        break;
      case 'checksums':
        await _showChecksums();
        break;
      case 'updateMode':
        await _updateArchive();
        break;
      case 'extract':
        await _extract();
        break;
      case 'extractTrash':
        await _extract(trashSource: true);
        break;
      case 'remove':
        await _removeSelected();
        break;
      case 'restore':
        await _restoreBackup();
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
      case 'nested':
        if (_selectedFile != null) await _enterNestedArchive(_selectedFile!);
        break;
      case 'parentArchive':
        await _returnToParentArchive();
        break;
      case 'preview':
        if (_selectedFile != null) await _previewFile(_selectedFile!);
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
        if (entry.comment.isNotEmpty || entry.commented)
          '注释': entry.comment.isNotEmpty
              ? entry.comment
              : '此条目包含注释，文本不可用（格式不支持或校验失败）',
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

  Future<void> _discardNestedDirectory(String directory) async {
    try {
      await _desktop.invokeMethod<void>(
        'discardNestedArchiveDirectory',
        directory,
      );
      _nestedDirectories.remove(directory);
    } catch (error) {
      if (mounted) {
        setState(() => _workspaceError = '子包暂存清理失败。$directory\n$error');
      }
    }
  }

  Future<void> _clearNestedArchives() async {
    _archiveParents.clear();
    for (final directory in _nestedDirectories.toList()) {
      await _discardNestedDirectory(directory);
    }
  }

  Future<void> _enterNestedArchive(ArchiveEntry entry) async {
    final archive = _archive;
    if (!_interactive ||
        archive == null ||
        !isNestedArchive(entry.normalizedPath)) {
      return;
    }
    if (_archiveParents.length >= nestedArchiveDepth) {
      await _error(const ArchiveFailure('最多进入八层子压缩包，请先返回父包'));
      return;
    }
    if (entry.size > nestedArchiveLimit) {
      await _error(const ArchiveFailure('子压缩包超过 256 MiB 浏览上限，请先解压'));
      return;
    }
    final version = _archiveVersion;
    var password = _password;
    String? directory;
    var retained = false;
    _openingFile = true;
    try {
      if (entry.encrypted && password.isEmpty) {
        final value = await _askPassword();
        if (value == null || !mounted) return;
        password = value;
      }
      directory = await _desktop.invokeMethod<String>(
        'createNestedArchiveDirectory',
      );
      if (directory == null) throw const ArchiveFailure('无法创建子包暂存目录');
      _nestedDirectories.add(directory);
      if (!mounted) return;
      final destination = p.join(
        directory,
        p.posix.basename(entry.normalizedPath),
      );
      while (mounted) {
        try {
          final result = await _run(
            '准备子压缩包',
            ArchiveRequest(
              'export',
              archive,
              destination: destination,
              password: password,
              codePage: _archiveCodePage,
              itemPath: entry.normalizedPath,
              expectedVersion: version,
              indices: [entry.index],
              outputLimit: nestedArchiveLimit,
            ),
          );
          if (result == null || !mounted) return;
          break;
        } on ArchiveFailure catch (error) {
          if (!error.passwordRequired) rethrow;
          final value = await _askPassword(error: error.message);
          if (value == null || !mounted) return;
          password = value;
        }
      }
      if (!mounted) return;
      final parent = ArchiveParent(
        archive: archive,
        password: _operationPasswords[archive] ?? password,
        codePage: _archiveCodePage,
        folder: _folder,
        query: _query,
        selection: Set.of(_selected),
        navigation: List.of(_navigation),
        navigationIndex: _navigationIndex,
        directory: directory,
      );
      // 交接给统一打开流程，期间继续由打开流程占用操作入口。
      _openingFile = false;
      if (!await _open(destination, nested: true) || !mounted) return;
      setState(() {
        _archiveParents.add(parent);
        _status = '已进入子包 · ${entry.normalizedPath}';
      });
      retained = true;
    } catch (error) {
      if (mounted) await _error(error);
    } finally {
      if (!retained && directory != null) {
        await _discardNestedDirectory(directory);
      }
      _openingFile = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _returnToParentArchive() async {
    if (!_interactive || _archiveParents.isEmpty) return;
    final parent = _archiveParents.last;
    final nested = _archiveParents.length > 1;
    if (!await _open(
          parent.archive,
          password: parent.password,
          codePage: parent.codePage,
          nested: nested,
        ) ||
        !mounted) {
      return;
    }
    bool folderExists(String folder) =>
        folder.isEmpty ||
        _entries.any(
          (entry) =>
              (entry.directory && entry.normalizedPath == folder) ||
              entry.normalizedPath.startsWith('$folder/'),
        );
    setState(() {
      if (nested) _archiveParents.removeLast();
      _folder = folderExists(parent.folder) ? parent.folder : '';
      _query = parent.query;
      _search.text = _query;
      _navigation
        ..clear()
        ..addAll(parent.navigation.where(folderExists));
      if (_navigation.isEmpty) _navigation.add('');
      _navigationIndex = _navigation.lastIndexOf(_folder);
      if (_navigationIndex < 0) {
        _navigation.add(_folder);
        _navigationIndex = _navigation.length - 1;
      } else if (parent.navigationIndex < _navigation.length &&
          _navigation[parent.navigationIndex] == _folder) {
        _navigationIndex = parent.navigationIndex;
      }
      _selected.addAll(
        parent.selection.where(
          (path) => _entries.any(
            (entry) =>
                entry.normalizedPath == path ||
                entry.normalizedPath.startsWith('$path/'),
          ),
        ),
      );
      _status = '已返回父包 · ${p.basename(parent.archive)}';
    });
    if (nested) await _discardNestedDirectory(parent.directory);
  }

  bool get _canPreview {
    final entry = _selectedFile;
    return _interactive &&
        entry != null &&
        ArchivePreviewKind.forPath(entry.normalizedPath) != null;
  }

  Future<void> _releasePreview(String id) async {
    final directory = _previewDirectories[id];
    if (directory == null) return;
    try {
      await _desktop.invokeMethod<void>(
        'discardArchivePreviewDirectory',
        directory,
      );
      if (mounted) {
        setState(() => _previewDirectories.remove(id));
      } else {
        _previewDirectories.remove(id);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _workspaceError = '预览暂存清理失败。$directory\n$error');
      }
    }
  }

  Future<void> _previewFile(ArchiveEntry entry) async {
    final archive = _archive;
    final kind = ArchivePreviewKind.forPath(entry.normalizedPath);
    if (!_interactive || archive == null || kind == null) return;
    if (_previewDirectories.length >= 2) {
      await _error(const ArchiveFailure('最多同时打开两个预览，请先关闭已有预览'));
      return;
    }
    if (entry.size > kind.outputLimit) {
      await _error(
        ArchiveFailure('文件超过 ${kind.outputLimit ~/ 1048576} MiB 预览上限'),
      );
      return;
    }
    final id = '${DateTime.now().microsecondsSinceEpoch}';
    final version = _archiveVersion;
    final codePage = _archiveCodePage;
    var password = _password;
    var opened = false;
    Object? failure;
    _openingFile = true;
    try {
      if (entry.encrypted && password.isEmpty) {
        final value = await _askPassword();
        if (value == null || !mounted) return;
        password = value;
      }
      final directory = await _desktop.invokeMethod<String>(
        'createArchivePreviewDirectory',
      );
      if (directory == null) throw const ArchiveFailure('无法创建预览暂存目录');
      _previewDirectories[id] = directory;
      if (!mounted) return;
      final file = p.join(directory, kind.outputName(entry.normalizedPath));
      while (mounted) {
        try {
          final result = await _run(
            '准备预览',
            ArchiveRequest(
              'export',
              archive,
              destination: file,
              itemPath: entry.normalizedPath,
              expectedVersion: version,
              codePage: codePage,
              password: password,
              indices: [entry.index],
              outputLimit: kind.outputLimit,
            ),
          );
          if (result == null || !mounted) return;
          break;
        } on ArchiveFailure catch (error) {
          if (!error.passwordRequired) rethrow;
          final value = await _askPassword(error: error.message);
          if (value == null || !mounted) return;
          password = value;
        }
      }
      if (!mounted) return;
      await _desktop.invokeMethod<void>('showArchivePreview', {
        'id': id,
        'path': file,
        'directory': directory,
        'kind': kind.name,
        'title': entry.normalizedPath,
      });
      opened = true;
      if (mounted) {
        setState(() {
          _status = '正在预览 · ${entry.normalizedPath}';
          if (_archive == archive && _archiveVersion == version) {
            _password = _operationPasswords[_archive] ?? password;
          }
        });
      }
    } catch (error) {
      failure = error;
    } finally {
      if (!opened) await _releasePreview(id);
      _openingFile = false;
      if (mounted) setState(() {});
    }
    if (failure != null && mounted) await _error(failure);
  }

  Future<void> _showSettings() async {
    if (!_interactive || Navigator.of(context).canPop()) return;
    final preferences = await showDialog<AppSettings>(
      context: context,
      builder: (_) => SettingsDialog(initial: _preferences),
    );
    if (preferences != null && mounted) {
      final archiveViewChanged =
          _preferences.filenameEncoding != preferences.filenameEncoding ||
          _preferences.autoUnpackTar != preferences.autoUnpackTar;
      setState(() => _preferences = preferences);
      widget.onSettingsChanged?.call(preferences);
      final archive = _archive;
      if (archiveViewChanged && archive != null) {
        await _open(
          archive,
          password: _password,
          nested: _archiveParents.isNotEmpty,
        );
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
        password = _operationPasswords[archive] ?? password;
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
        if (_archive == archive) {
          _password = _operationPasswords[_archive] ?? password;
        }
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
    session.password = _operationPasswords[session.archive] ?? session.password;
    if (mounted) {
      setState(() {
        if (_archive == session.archive) {
          _password = session.password;
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
    if (row.entry != null) {
      if (isNestedArchive(row.path)) {
        _enterNestedArchive(row.entry!);
      } else {
        _openFile(row.entry!);
      }
    }
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
        if (!row.directory && isNestedArchive(row.path))
          const PopupMenuItem(value: 'nested', child: Text('进入子压缩包')),
        PopupMenuItem(value: 'open', child: Text(row.directory ? '打开' : '查看')),
        if (!row.directory && row.entry != null)
          PopupMenuItem(
            value: 'preview',
            enabled: ArchivePreviewKind.forPath(row.path) != null,
            child: const Text('内置预览'),
          ),
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
      case 'nested':
        if (row.entry != null) await _enterNestedArchive(row.entry!);
        break;
      case 'preview':
        if (row.entry != null) await _previewFile(row.entry!);
        break;
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
      'tasks': true,
      'batchExtract': _desktopReady && !_choosing,
      'batchTest': _desktopReady && !_choosing,
      'open': _interactive,
      'clearRecent': _interactive && _recent.isNotEmpty,
      'new': _interactive,
      'extract': _interactive && archive != null,
      'test': _interactive && archive != null,
      'add': _interactive && _editable && archive != null,
      'mkdir': _interactive && _editable && archive != null,
      'remove': _interactive && _editable && _selected.isNotEmpty,
      'rename': _interactive && _editable && _selected.length == 1,
      'nested':
          _interactive &&
          _selectedFile != null &&
          isNestedArchive(_selectedFile!.normalizedPath),
      'parentArchive': _interactive && _archiveParents.isNotEmpty,
      'preview': _canPreview,
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
                    if (_showTasks) _archiveTaskPanel(),
                    if (_busy && (!_showTasks || _activeQueuedTask == null))
                      _progressPanel(),
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
    height: 52,
    padding: EdgeInsets.only(right: windowControlsOnRight ? 0 : 8),
    decoration: BoxDecoration(
      color: AppColors.of(context).canvas,
      border: Border(bottom: BorderSide(color: AppColors.of(context).border)),
    ),
    child: Stack(
      children: [
        if (_showTree || _archive == null)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: (_archive == null ? 192 : _treeWidth) + 5,
            child: ColoredBox(color: AppColors.of(context).sidebar),
          ),
        Row(
          children: [
            if (windowControlsOnLeft) const WindowControls(),
            IconButton(
              tooltip: _showTree ? '隐藏侧栏' : '显示侧栏',
              onPressed: _archive == null
                  ? null
                  : () => setState(() => _showTree = !_showTree),
              icon: const Icon(Icons.vertical_split_outlined, size: 19),
            ),
            const SizedBox(width: 8),
            _tool(
              Icons.folder_open_rounded,
              '打开',
              '⌘O',
              _interactive ? _openDialog : null,
              emphasized: _archive == null,
            ),
            _tool(
              Icons.inventory_2_outlined,
              '新建',
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
            if (MediaQuery.sizeOf(context).width >= 1100)
              _tool(
                Icons.preview_outlined,
                '预览',
                '内置预览',
                _canPreview ? () => _previewFile(_selectedFile!) : null,
              ),
            if (MediaQuery.sizeOf(context).width >= 1000)
              _tool(
                Icons.visibility_outlined,
                '查看',
                'F3',
                _interactive && _selectedFile != null
                    ? () => _openFile(_selectedFile!)
                    : null,
              ),
            if (MediaQuery.sizeOf(context).width >= 940)
              _tool(
                Icons.edit_outlined,
                '编辑',
                'F4',
                _interactive && _editable && _selectedFile != null
                    ? () => _openFile(_selectedFile!, editing: true)
                    : null,
              ),
            if (MediaQuery.sizeOf(context).width >= 1200)
              _tool(
                Icons.article_outlined,
                '属性',
                '⌘I',
                _interactive && _archive != null ? _properties : null,
              ),
            Expanded(
              child: WindowDragArea(
                child: SizedBox(
                  height: 52,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        _archive == null ? 'F7Zip' : p.basename(_archive!),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.of(context).secondary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            PopupMenuButton<String>(
              tooltip: '最近打开',
              enabled: _interactive && _recent.isNotEmpty,
              icon: const Icon(Icons.history_rounded, size: 19),
              onSelected: (path) async {
                if (path.isEmpty) {
                  await _clearRecentArchives();
                } else {
                  await _open(path);
                }
              },
              itemBuilder: (_) => [
                ..._recent.map(
                  (path) => PopupMenuItem<String>(
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
                ),
                const PopupMenuDivider(),
                const PopupMenuItem<String>(value: '', child: Text('清空最近打开')),
              ],
            ),
            IconButton(
              tooltip: '任务队列',
              constraints: const BoxConstraints.tightFor(width: 32, height: 36),
              padding: EdgeInsets.zero,
              onPressed: () => setState(() => _showTasks = !_showTasks),
              icon: const Icon(Icons.list_alt_outlined, size: 19),
            ),
            IconButton(
              tooltip: '设置',
              onPressed: _interactive ? _showSettings : null,
              icon: const Icon(Icons.settings_outlined, size: 19),
            ),
            _moreMenu(),
            if (windowControlsOnRight) const WindowControls(),
          ],
        ),
      ],
    ),
  );

  Future<void> _moreAction(String action) async {
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
        await _desktop.invokeMethod<void>('reveal', _archive ?? _lastOutput);
        break;
      default:
        await _command(action);
    }
  }

  Widget _moreMenu() {
    final colors = AppColors.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final buttonStyle = MenuItemButton.styleFrom(
      minimumSize: const Size(180, 32),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      textStyle: const TextStyle(fontSize: 13),
      visualDensity: VisualDensity.compact,
    );
    Widget item(String action, String label, {bool enabled = true}) =>
        MenuItemButton(
          onPressed: enabled ? () => _moreAction(action) : null,
          child: Text(label),
        );

    return MenuTheme(
      data: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(colors.panel),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(vertical: 4),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: colors.border),
            ),
          ),
        ),
      ),
      child: MenuButtonTheme(
        data: MenuButtonThemeData(style: buttonStyle),
        child: MenuAnchor(
          childFocusNode: _moreMenuFocus,
          menuChildren: [
            item('properties', '属性', enabled: _archive != null),
            SubmenuButton(
              menuChildren: [
                if (width < 1000)
                  item('view', '查看', enabled: _selectedFile != null),
                item('preview', '内置预览', enabled: _canPreview),
                item(
                  'nested',
                  '进入子压缩包',
                  enabled:
                      _selectedFile != null &&
                      isNestedArchive(_selectedFile!.normalizedPath),
                ),
                item(
                  'parentArchive',
                  '返回父压缩包',
                  enabled: _archiveParents.isNotEmpty,
                ),
                const Divider(height: 8),
                item('tree', _showTree ? '隐藏文件树' : '显示文件树'),
              ],
              child: const Text('查看与导航'),
            ),
            SubmenuButton(
              menuChildren: [
                item('quick', '快速解压到同级目录', enabled: _archive != null),
                item('selected', '解压选中项…', enabled: _selected.isNotEmpty),
                const Divider(height: 8),
                item(
                  'extractTrash',
                  '解压后移至废纸篓…',
                  enabled: _archive != null && _archiveParents.isEmpty,
                ),
              ],
              child: const Text('解压'),
            ),
            SubmenuButton(
              menuChildren: [
                if (width < 940)
                  item(
                    'edit',
                    '编辑',
                    enabled: _editable && _selectedFile != null,
                  ),
                item(
                  'rename',
                  '重命名…',
                  enabled: _editable && _selected.length == 1,
                ),
                item('mkdir', '新建文件夹…', enabled: _editable && _archive != null),
                const Divider(height: 8),
                item(
                  'fileComment',
                  '编辑文件注释…',
                  enabled: _commentEditable && _selectedFile != null,
                ),
                item('archiveComment', '编辑归档注释…', enabled: _commentEditable),
                const Divider(height: 8),
                item(
                  'updateMode',
                  '更新模式…',
                  enabled: _editable && _archive != null,
                ),
                item(
                  'restore',
                  '恢复原包备份…',
                  enabled: _editable && _archive != null,
                ),
              ],
              child: const Text('编辑压缩包'),
            ),
            SubmenuButton(
              menuChildren: [
                item('splitFile', '分割普通文件…'),
                item('joinFile', '合并分片…'),
                const Divider(height: 8),
                item('repairZip', '修复 ZIP…'),
                item('recoverPassword', '自有归档密码恢复…'),
                item('checksums', '校验工具…'),
              ],
              child: const Text('工具'),
            ),
            const Divider(height: 8),
            item(
              'finder',
              '在 Finder 显示',
              enabled: _archive != null || _lastOutput != null,
            ),
            item('close', '关闭压缩包', enabled: _archive != null),
            const Divider(height: 8),
            item('about', '关于 F7Zip'),
          ],
          builder: (context, controller, child) => IconButton(
            focusNode: _moreMenuFocus,
            tooltip: '更多操作',
            onPressed: _interactive
                ? () =>
                      controller.isOpen ? controller.close() : controller.open()
                : null,
            icon: const Icon(Icons.more_horiz, size: 22),
          ),
        ),
      ),
    );
  }

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
        width: ['打开', '新建', '解压到…'].contains(label)
            ? (label == '解压到…' ? 96 : 76)
            : 36,
        height: 32,
        child: TextButton(
          onPressed: action,
          style: TextButton.styleFrom(
            foregroundColor: emphasized
                ? AppColors.of(context).onTint
                : AppColors.of(context).text,
            backgroundColor: emphasized ? AppColors.of(context).tint : null,
            disabledForegroundColor: AppColors.of(context).secondary
                .withValues(alpha: 0.4),
            minimumSize: Size.zero,
            padding: const EdgeInsets.symmetric(horizontal: 6),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18),
              if (['打开', '新建', '解压到…'].contains(label)) ...[
                const SizedBox(width: 6),
                Text(label, maxLines: 1, style: const TextStyle(fontSize: 12)),
              ],
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
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '最近打开',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.of(context).secondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (_recent.isNotEmpty)
                  IconButton(
                    tooltip: '清空最近打开',
                    constraints: const BoxConstraints.tightFor(
                      width: 28,
                      height: 24,
                    ),
                    padding: EdgeInsets.zero,
                    onPressed: _interactive ? _clearRecentArchives : null,
                    icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                  ),
              ],
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

  Widget _welcome() => WelcomePanel(
    onOpen: _available ? _openDialog : null,
    onCreate: _available ? _create : null,
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
                      _archiveParents.isNotEmpty
                          ? '子包 · 只读浏览'
                          : (_editable ? '可编辑' : '只读浏览'),
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
                  if (_archiveParents.isNotEmpty)
                    IconButton(
                      tooltip: '返回父压缩包',
                      icon: const Icon(
                        Icons.drive_folder_upload_outlined,
                        size: 18,
                      ),
                      onPressed: _interactive ? _returnToParentArchive : null,
                    ),
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

  Widget _archiveTaskPanel() => ArchiveTaskPanel(
    tasks: _archiveTasks,
    engineBusy: _busy,
    onCancel: _cancelArchiveTask,
    onRetry: _retryArchiveTask,
    onClear: () =>
        setState(() => _archiveTasks.removeWhere((task) => task.finished)),
    onClose: () => setState(() => _showTasks = false),
    onReveal: (path) => _desktop.invokeMethod<void>('reveal', path),
    onBatchExtract: _desktopReady && !_choosing
        ? () => _enqueueBatch('batchExtract')
        : null,
    onBatchTest: _desktopReady && !_choosing
        ? () => _enqueueBatch('test')
        : null,
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
                  final task = _activeQueuedTask;
                  if (task != null) {
                    _cancelArchiveTask(task);
                  } else {
                    _engine?.cancel();
                    setState(() => _cancelling = true);
                  }
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
            '开源跨平台桌面压缩工具\n\nFlutter 界面 · 7-Zip 26.06 原生引擎\nbit7z 4.0.10 C++ 封装\n\nF7Zip 使用 MIT 许可证。\n7-Zip 遵循 LGPL、BSD 及 unRAR 限制。\nbit7z 遵循 MPL-2.0。\n\n支持 ZIP / ZIPX / 7z / Windows SFX / WIM / TAR / GZIP / XZ / BZIP2 创建，ZIP / 7z 编辑回写，多格式浏览与解压。',
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
    '.zipx',
    '.exe',
    '.wim',
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
