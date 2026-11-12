import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop_preview.dart';
import 'desktop_associations.dart';

final desktopNavigatorKey = GlobalKey<NavigatorState>();
bool get usesPortableDesktop => Platform.isWindows || Platform.isLinux;

/// 保持既有调用契约，Windows、Linux 复用 Flutter 插件和系统服务。
class DesktopBridge {
  const DesktopBridge({this.channel = 'sevenzip/desktop'});
  final String channel;
  static Future<dynamic> Function(MethodCall)? _handler;
  static Map<String, dynamic> _state = {};
  static final _directories = <String>{};
  static final _previews = <String, DialogRoute<void>>{};
  static final _previewTasks = <String, Future<void>>{};
  static bool _closing = false;
  static const _passwordStore = FlutterSecureStorage();
  static Future<void> _passwordWrites = Future.value();
  static Future<void> _stateWrites = Future.value();
  static List<String> arguments = [];

  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    if (!usesPortableDesktop) {
      return MethodChannel(channel).invokeMethod<T>(method, arguments);
    }
    final value = await _invoke(method, arguments);
    return value as T?;
  }

  Future<List<T>?> invokeListMethod<T>(
    String method, [
    dynamic arguments,
  ]) async {
    final value = await invokeMethod<List<dynamic>>(method, arguments);
    return value?.cast<T>();
  }

  Future<Map<K, V>?> invokeMapMethod<K, V>(
    String method, [
    dynamic arguments,
  ]) async {
    final value = await invokeMethod<Map<dynamic, dynamic>>(method, arguments);
    return value?.cast<K, V>();
  }

  void setMethodCallHandler(Future<dynamic> Function(MethodCall)? handler) {
    if (!usesPortableDesktop) {
      MethodChannel(channel).setMethodCallHandler(handler);
    } else if (channel == 'sevenzip/desktop') {
      _handler = handler;
    }
  }

  static BuildContext get _context =>
      desktopNavigatorKey.currentState!.overlay!.context;
  static Future<Directory> get _support async {
    final root = await getApplicationSupportDirectory();
    await root.create(recursive: true);
    return root;
  }

  static Future<void> _save() {
    final snapshot = jsonEncode(_state);
    final operation = _stateWrites.then((_) => _saveSnapshot(snapshot));
    _stateWrites = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  static Future<void> _saveSnapshot(String snapshot) async {
    final root = await _support;
    final temporary = File(p.join(root.path, 'preferences.pending'));
    await temporary.writeAsString(snapshot, flush: true);
    final target = File(p.join(root.path, 'preferences.json'));
    // Windows rename 不覆盖已有文件。保留备份，重启时可恢复中断的保存。
    final backup = File('${target.path}.backup');
    if (await target.exists()) {
      if (await backup.exists()) await backup.delete();
      await target.rename(backup.path);
    }
    await temporary.rename(target.path);
  }

  static Future<void> _load() async {
    final root = await _support;
    var file = File(p.join(root.path, 'preferences.json'));
    if (!await file.exists()) file = File('${file.path}.backup');
    if (await file.exists()) {
      _state = Map<String, dynamic>.from(
        jsonDecode(await file.readAsString()) as Map,
      );
    }
  }

  static Future<Map<String, String>> _passwords() async {
    final value = await _passwordStore.read(key: 'archivePasswords');
    return value == null
        ? {}
        : Map<String, String>.from(jsonDecode(value) as Map);
  }

  static Future<List<String>> _changePassword(String method, Map args) {
    final operation = _passwordWrites.then((_) async {
      final passwords = await _passwords();
      final name = args['name'] as String? ?? '';
      final password = args['password'] as String? ?? '';
      if (name.trim().isEmpty || utf8.encode(name).length > 256) {
        throw const FormatException('请输入有效的密码名称');
      }
      if (method == 'deleteArchivePassword') {
        passwords.remove(name);
      } else {
        if (password.isEmpty ||
            utf8.encode(password).length > 4096 ||
            password.contains('\x00')) {
          throw const FormatException('密码须为 1–4096 个 UTF-8 字节');
        }
        if (passwords.containsKey(name) && args['replace'] != true) {
          throw const FormatException('已存在同名密码');
        }
        if (!passwords.containsKey(name) && passwords.length >= 20) {
          throw const FormatException('最多保存 20 项密码');
        }
        passwords[name] = password;
      }
      await _passwordStore.write(
        key: 'archivePasswords',
        value: jsonEncode(passwords),
      );
      return passwords.keys.toList()..sort();
    });
    _passwordWrites = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  static Future<String> _temporary(String prefix, [int? maximum]) async {
    if (_closing) throw StateError('应用正在退出');
    if (maximum != null &&
        _directories
                .where((path) => p.basename(path).startsWith(prefix))
                .length >=
            maximum) {
      throw StateError('已达到同时打开数量上限');
    }
    final root = await getTemporaryDirectory();
    final directory = await Directory(root.path).createTemp(prefix);
    if (_closing) {
      await directory.delete();
      throw StateError('应用正在退出');
    }
    _directories.add(directory.path);
    return directory.path;
  }

  static Future<void> _discard(String path) async {
    if (!_directories.contains(path)) return;
    final directory = Directory(path);
    if (await directory.exists()) await directory.delete(recursive: true);
    _directories.remove(path);
  }

  static Future<void> cleanup() async {
    _closing = true;
    await _handler?.call(const MethodCall('desktopShutdown'));
    await _closePreviews(_previews.keys.toList());
    await _stateWrites;
    await _passwordWrites;
    for (final path in _directories.toList()) {
      await _discard(path);
    }
  }

  static Future<void> _closePreviews(List<dynamic> ids) async {
    final tasks = <Future<void>>[];
    for (final id in ids) {
      final route = _previews[id];
      final task = _previewTasks[id];
      if (task != null) tasks.add(task);
      if (route?.isActive == true) route!.navigator!.removeRoute(route);
    }
    await Future.wait(tasks);
  }

  static Future<void> _process(
    String executable,
    List<String> arguments,
  ) async {
    final result = await Process.run(executable, arguments);
    if (result.exitCode != 0) throw StateError('${result.stderr}'.trim());
  }

  static Future<void> _launchFile(Map args) async {
    final path = args['path'] as String;
    final application = args['application'] as String? ?? '';
    if (application.isNotEmpty) {
      await Process.start(application, [path], mode: ProcessStartMode.detached);
    } else if (!await launchUrl(
      Uri.file(path),
      mode: LaunchMode.externalApplication,
    )) {
      throw StateError('无法打开文件');
    }
  }

  static Future<String?> _passwordDialog(Map args) async {
    final controller = TextEditingController();
    try {
      return await showDialog<String>(
        context: _context,
        builder: (context) => AlertDialog(
          title: const Text('压缩包密码'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                args['error'] as String? ??
                    p.basename(args['path'] as String? ?? ''),
              ),
              TextField(
                controller: controller,
                obscureText: true,
                autofocus: true,
                onSubmitted: (value) => Navigator.pop(context, value),
              ),
            ],
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
    } finally {
      controller.dispose();
    }
  }

  static Future<int?> _chooseColor(int initial) async {
    var color = Color(initial);
    return showDialog<int>(
      context: _context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('选择颜色'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(height: 60, color: color),
                for (final channel in ['R', 'G', 'B'])
                  Row(
                    children: [
                      Text(channel),
                      Expanded(
                        child: Slider(
                          value: switch (channel) {
                            'R' => color.r,
                            'G' => color.g,
                            _ => color.b,
                          },
                          onChanged: (value) => setState(
                            () => color = Color.from(
                              alpha: 1,
                              red: channel == 'R' ? value : color.r,
                              green: channel == 'G' ? value : color.g,
                              blue: channel == 'B' ? value : color.b,
                            ),
                          ),
                        ),
                      ),
                    ],
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
              onPressed: () => Navigator.pop(context, color.toARGB32()),
              child: const Text('选择'),
            ),
          ],
        ),
      ),
    );
  }

  Future<dynamic> _invoke(String method, dynamic arguments) async {
    switch (method) {
      case 'chooseColor':
        return _chooseColor(arguments as int);
      case 'loadSettings':
        await _load();
        return _state['preferences'] ?? {};
      case 'saveSettings':
        _state['preferences'] = arguments;
        await _save();
        return null;
      case 'recentArchives':
        return _state['recentArchives'] ?? <String>[];
      case 'clearRecentArchives':
        _state['recentArchives'] = <String>[];
        await _save();
        return null;
      case 'rememberArchive':
        final recent = List<String>.from(
          _state['recentArchives'] as List? ?? [],
        );
        recent.remove(arguments);
        recent.insert(0, arguments as String);
        _state['recentArchives'] = recent.take(8).toList();
        await _save();
        return null;
      case 'workspaceDirectory':
        final root = await _support;
        return (await Directory(p.join(root.path, 'EditSessions'))
                .create(recursive: true))
            .path;
      case 'takeFinderRequests':
        final paths = DesktopBridge.arguments
            .where((path) => !path.startsWith('--'))
            .map(p.absolute)
            .toList();
        DesktopBridge.arguments = [];
        return paths.isEmpty
            ? []
            : [
                {'action': 'open', 'paths': paths},
              ];
      case 'setAppearance':
      case 'updateCommands':
        return null;
      case 'setArchiveTitle':
        await windowManager.setTitle(
          arguments == ''
              ? 'F7Zip'
              : '${p.basename(arguments as String)} — F7Zip',
        );
        return null;
      case 'openArchive':
        final file = await openFile();
        return file == null ? <String>[] : [file.path];
      case 'chooseArchives':
      case 'chooseChecksumFiles':
        return (await openFiles()).map((file) => file.path).toList();
      case 'chooseInputs':
        final directory = await showDialog<bool>(
          context: _context,
          builder: (context) => SimpleDialog(
            title: const Text('选择压缩来源'),
            children: [
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('选择文件'),
              ),
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('选择文件夹'),
              ),
            ],
          ),
        );
        if (directory == null) return <String>[];
        if (!directory) {
          return (await openFiles()).map((file) => file.path).toList();
        }
        final path = await getDirectoryPath();
        return path == null ? <String>[] : [path];
      case 'chooseFolder':
        final path = await getDirectoryPath();
        return path == null ? <String>[] : [path];
      case 'finderChooseFolder':
        return getDirectoryPath();
      case 'saveArchive':
        return (await getSaveLocation(
          suggestedName: arguments as String? ?? 'Archive.zip',
        ))?.path;
      case 'importTheme':
        return (await openFile(
          acceptedTypeGroups: [
            const XTypeGroup(label: 'JSON', extensions: ['json']),
          ],
        ))?.path;
      case 'exportTheme':
        return (await getSaveLocation(suggestedName: 'F7Zip-theme.json'))?.path;
      case 'chooseApplication':
        return (await openFile())?.path;
      case 'launchFile':
        await _launchFile(arguments as Map);
        return null;
      case 'reveal':
        final path = arguments as String;
        if (Platform.isWindows) {
          await Process.start('explorer.exe', [
            '/select,',
            p.normalize(path),
          ], mode: ProcessStartMode.detached);
        } else {
          await _process('xdg-open', [
            await FileSystemEntity.isDirectory(path) ? path : p.dirname(path),
          ]);
        }
        return null;
      case 'listArchivePasswords':
        await _passwordWrites;
        return (await _passwords()).keys.toList()..sort();
      case 'archivePasswordCandidates':
        if ((_state['preferences'] as Map?)?['autoTryPasswords'] != true) {
          return <String>[];
        }
        await _passwordWrites;
        return (await _passwords()).values.toList();
      case 'saveArchivePassword':
      case 'deleteArchivePassword':
        return _changePassword(method, arguments as Map);
      case 'createNestedArchiveDirectory':
        return _temporary('f7zip-nested-', 8);
      case 'createArchivePreviewDirectory':
        return _temporary('f7zip-preview-', 2);
      case 'createArchiveDragDirectory':
        return _temporary('f7zip-drag-');
      case 'discardNestedArchiveDirectory':
      case 'discardArchivePreviewDirectory':
      case 'discardArchiveDragDirectory':
        await _discard(arguments as String);
        return null;
      case 'showArchivePreview':
        final args = Map<String, String>.from(arguments as Map);
        if (!_directories.contains(args['directory']) ||
            p.dirname(args['path']!) != args['directory']) {
          throw StateError('预览文件路径无效');
        }
        final preview = await prepareDesktopPreview(args);
        if (_closing || !_directories.contains(args['directory'])) {
          await preview.dispose();
          return null;
        }
        final navigator = desktopNavigatorKey.currentState;
        if (navigator == null || !navigator.mounted) {
          await preview.dispose();
          return null;
        }
        final route = DialogRoute<void>(
          context: navigator.context,
          builder: (context) {
            return DesktopPreviewDialog(
              preview: preview,
              title: args['title']!,
            );
          },
        );
        _previews[args['id']!] = route;
        final task = navigator.push(route).whenComplete(() async {
          await route.completed;
          _previews.remove(args['id']);
          await preview.dispose();
          await _handler?.call(
            MethodCall('archivePreviewClosed', {'id': args['id']}),
          );
          _previewTasks.remove(args['id']);
        });
        _previewTasks[args['id']!] = task;
        unawaited(task);
        return null;
      case 'closeArchivePreviews':
        await _closePreviews(arguments as List);
        return null;
      case 'finderPassword':
        return _passwordDialog(arguments as Map);
      case 'finderError':
        await showDialog<void>(
          context: _context,
          builder: (context) => AlertDialog(
            title: const Text('操作未完成'),
            content: Text(arguments as String),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
        return null;
      case 'finderExtractionConflict':
        final choice = await showDialog<String>(
          context: _context,
          builder: (context) => SimpleDialog(
            title: const Text('解压目标存在同名项目'),
            children: [
              for (final choice in {
                'skip': '跳过同名文件',
                'rename': '自动改名',
                'merge': '合并目录',
                'overwrite': '替换同名普通文件',
              }.entries)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, choice.key),
                  child: Text(choice.value),
                ),
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消解压'),
              ),
            ],
          ),
        );
        if (choice != 'overwrite') return choice;
        final navigator = desktopNavigatorKey.currentState;
        if (navigator == null || !navigator.mounted) return null;
        final confirmed = await showDialog<bool>(
          context: navigator.context,
          builder: (context) => AlertDialog(
            title: const Text('确认替换已有普通文件？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('确认替换'),
              ),
            ],
          ),
        );
        return confirmed == true ? choice : null;
      case 'fileAssociations':
        return DesktopAssociations.states();
      case 'setFileAssociation':
        return DesktopAssociations.set(
          Map<String, dynamic>.from(arguments as Map),
        );
      default:
        throw MissingPluginException('尚未实现桌面操作 $method');
    }
  }
}
