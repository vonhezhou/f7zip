import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

class EditSession {
  EditSession({
    required this.directory,
    required this.archive,
    required this.itemPath,
    required this.file,
    required this.version,
    required this.savedDigest,
    required this.requiresPassword,
    this.password = '',
    this.codePage = 0,
  });

  final Directory directory;
  final String archive;
  final String itemPath;
  final File file;
  final bool requiresPassword;
  final int codePage;
  String version;
  String savedDigest;
  String password;
  String? error;
  String? observedDigest;
  String observedStat = '';
  DateTime stableSince = DateTime.now();
  bool get pending =>
      error != null ||
      (observedDigest != null && observedDigest != savedDigest);

  Future<void> persist() async {
    final temporary = File(p.join(directory.path, 'session.json.tmp'));
    await temporary.writeAsString(
      jsonEncode({
        'archive': archive,
        'itemPath': itemPath,
        'file': file.path,
        'version': version,
        'savedDigest': savedDigest,
        'requiresPassword': requiresPassword,
        'codePage': codePage,
      }),
      flush: true,
    );
    await temporary.rename(p.join(directory.path, 'session.json'));
  }
}

class EditWorkspace {
  EditWorkspace({
    required this.root,
    required this.canUpdate,
    required this.update,
    required this.onChanged,
    this.settleTime = const Duration(milliseconds: 700),
    this.canTryPasswords,
  });

  final Directory root;
  final bool Function() canUpdate;
  final bool Function()? canTryPasswords;
  final Future<String> Function(EditSession session, String snapshot) update;
  final void Function() onChanged;
  final Duration settleTime;
  final List<EditSession> sessions = [];
  final List<String> recoveryErrors = [];
  Timer? _timer;
  bool _checking = false;
  bool _closed = false;

  static Future<String> digest(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  Future<void> restore() async {
    await root.create(recursive: true);
    await for (final entry in root.list(followLinks: false)) {
      if (entry is! Directory) continue;
      final manifest = File(p.join(entry.path, 'session.json'));
      if (!await manifest.exists()) continue;
      try {
        final json =
            jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
        final file = File(json['file'] as String);
        if (!p.isWithin(entry.absolute.path, file.absolute.path)) {
          throw const FormatException('编辑文件路径越界');
        }
        sessions.add(
          EditSession(
            directory: entry,
            archive: json['archive'] as String,
            itemPath: json['itemPath'] as String,
            file: file,
            version: json['version'] as String,
            savedDigest: json['savedDigest'] as String,
            requiresPassword: json['requiresPassword'] as bool? ?? false,
            codePage: json['codePage'] as int? ?? 0,
          ),
        );
      } catch (error) {
        recoveryErrors.add('${entry.path} · $error');
      }
    }
    _ensureTimer();
  }

  EditSession? find(String archive, String itemPath) {
    for (final session in sessions) {
      if (session.archive == archive && session.itemPath == itemPath) {
        return session;
      }
    }
    return null;
  }

  Future<EditSession> track({
    required Directory directory,
    required String archive,
    required String itemPath,
    required File file,
    required String version,
    required bool requiresPassword,
    required String password,
    int codePage = 0,
  }) async {
    final session = EditSession(
      directory: directory,
      archive: archive,
      itemPath: itemPath,
      file: file,
      version: version,
      savedDigest: await digest(file),
      requiresPassword: requiresPassword,
      codePage: codePage,
      password: password,
    );
    await session.persist();
    sessions.add(session);
    _ensureTimer();
    onChanged();
    return session;
  }

  void _ensureTimer() {
    if (!_closed && sessions.isNotEmpty) {
      _timer ??= Timer.periodic(
        const Duration(milliseconds: 600),
        (_) => poll(),
      );
    }
  }

  Future<void> poll() async {
    if (_closed || _checking) return;
    _checking = true;
    try {
      for (final session in List<EditSession>.of(sessions)) {
        if (_closed) break;
        if (session.error != null) continue;
        try {
          final stat = await session.file.stat();
          if (stat.type != FileSystemEntityType.file) continue;
          final signature =
              '${stat.size}:${stat.modified.microsecondsSinceEpoch}:${stat.changed.microsecondsSinceEpoch}';
          if (signature != session.observedStat) {
            session.observedStat = signature;
            session.observedDigest = await digest(session.file);
            session.stableSince = DateTime.now();
            onChanged();
          }
          final observed = session.observedDigest;
          if (observed == null ||
              observed == session.savedDigest ||
              DateTime.now().difference(session.stableSince) < settleTime ||
              !canUpdate()) {
            continue;
          }
          if (session.requiresPassword &&
              session.password.isEmpty &&
              !(canTryPasswords?.call() ?? false)) {
            throw const FileSystemException('请点击重试并输入压缩包密码');
          }
          final snapshot = File(p.join(session.directory.path, 'snapshot.tmp'));
          try {
            await session.file.copy(snapshot.path);
            if (await digest(snapshot) != observed ||
                await digest(session.file) != observed) {
              session.observedStat = '';
              continue;
            }
            if (_closed || !sessions.contains(session) || !canUpdate()) {
              continue;
            }
            final previous = session.version;
            final next = await update(session, snapshot.path);
            session.savedDigest = observed;
            // 同一压缩包的其他编辑会话接续本应用刚完成的更新，继续保护外部修改。
            for (final related in sessions) {
              if (related.archive == session.archive &&
                  related.version == previous) {
                related.version = next;
                await related.persist();
              }
            }
          } finally {
            if (await snapshot.exists()) await snapshot.delete();
          }
          onChanged();
        } catch (error) {
          session.error = '$error';
          onChanged();
        }
      }
    } finally {
      _checking = false;
    }
  }

  Future<void> rebaseArchive(
    String archive,
    String previous,
    String next,
  ) async {
    for (final session in sessions) {
      if (session.archive == archive && session.version == previous) {
        session.version = next;
        await session.persist();
      }
    }
    onChanged();
  }

  void retry(EditSession session) {
    session.error = null;
    session.observedStat = '';
    onChanged();
  }

  Future<void> stop(EditSession session) async {
    final manifest = File(p.join(session.directory.path, 'session.json'));
    if (await manifest.exists()) await manifest.delete();
    sessions.remove(session);
    if (sessions.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
    onChanged();
  }

  void close() {
    _closed = true;
    _timer?.cancel();
  }
}
