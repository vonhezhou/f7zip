import 'dart:convert';
import 'dart:io';

import 'package:f7zip/archive_engine.dart';
import 'package:f7zip/edit_workspace.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('f7zip-edit-test-'));
  tearDown(() => root.deleteSync(recursive: true));

  Future<EditSession> track(
    EditWorkspace workspace,
    String name, {
    String password = '',
    int codePage = 0,
  }) async {
    final directory = await workspace.root.createTemp('edit-');
    final file = File(p.join(directory.path, name));
    await file.writeAsString('original');
    return workspace.track(
      directory: directory,
      archive: p.join(root.path, 'archive.zip'),
      itemPath: name,
      file: file,
      version: 'v1',
      requiresPassword: password.isNotEmpty,
      password: password,
      codePage: codePage,
    );
  }

  test('编辑保存自动回写一次，使用内容快照并持久化新版本', () async {
    final snapshots = <String>[];
    final workspace = EditWorkspace(
      root: root,
      settleTime: Duration.zero,
      canUpdate: () => true,
      onChanged: () {},
      update: (session, snapshot) async {
        snapshots.add(await File(snapshot).readAsString());
        return 'v2';
      },
    );
    addTearDown(workspace.close);
    final session = await track(workspace, 'document.txt');
    await session.file.writeAsString('saved edits', flush: true);
    await workspace.poll();
    await workspace.poll();
    expect(snapshots, ['saved edits']);
    expect(session.version, 'v2');
    expect(session.pending, isFalse);
    final manifest = jsonDecode(
      await File(p.join(session.directory.path, 'session.json')).readAsString(),
    ) as Map;
    expect(manifest['version'], 'v2');
    expect(
      File(p.join(session.directory.path, 'snapshot.tmp')).existsSync(),
      isFalse,
    );
  });

  test('包内结构修改接续当前编辑版本，旧版本会话仍保留冲突保护', () async {
    final workspace = EditWorkspace(
      root: root,
      canUpdate: () => false,
      onChanged: () {},
      update: (session, snapshot) async => 'unused',
    );
    addTearDown(workspace.close);
    final current = await track(workspace, 'current.txt', codePage: 932);
    final stale = await track(workspace, 'stale.txt');
    stale.version = 'external-version';
    await stale.persist();
    final oldManifest = File(p.join(stale.directory.path, 'session.json'));
    final oldData =
        jsonDecode(await oldManifest.readAsString()) as Map<String, dynamic>;
    oldData.remove('codePage');
    await oldManifest.writeAsString(jsonEncode(oldData));
    await workspace.rebaseArchive(current.archive, 'v1', 'v2');
    expect(current.version, 'v2');
    expect(stale.version, 'external-version');
    final restored = EditWorkspace(
      root: root,
      canUpdate: () => false,
      onChanged: () {},
      update: (session, snapshot) async => 'unused',
    );
    addTearDown(restored.close);
    await restored.restore();
    expect(restored.find(current.archive, current.itemPath)!.version, 'v2');
    expect(restored.find(current.archive, current.itemPath)!.codePage, 932);
    expect(restored.find(stale.archive, stale.itemPath)!.codePage, 0);
    expect(
      restored.find(stale.archive, stale.itemPath)!.version,
      'external-version',
    );
  });

  test('前台任务繁忙时保留待回写修改，空闲后自动继续', () async {
    var available = false;
    var calls = 0;
    final workspace = EditWorkspace(
      root: root,
      settleTime: Duration.zero,
      canUpdate: () => available,
      onChanged: () {},
      update: (session, snapshot) async {
        calls++;
        return 'v2';
      },
    );
    addTearDown(workspace.close);
    final session = await track(workspace, 'document.txt');
    await session.file.writeAsString('pending');
    await workspace.poll();
    expect(calls, 0);
    expect(session.pending, isTrue);
    available = true;
    await workspace.poll();
    expect(calls, 1);
    expect(session.pending, isFalse);
  });

  test('回写失败保留文件并停止重复尝试，显式重试后恢复', () async {
    var failed = true;
    var calls = 0;
    final workspace = EditWorkspace(
      root: root,
      settleTime: Duration.zero,
      canUpdate: () => true,
      onChanged: () {},
      update: (session, snapshot) async {
        calls++;
        if (failed) throw const ArchiveFailure('原压缩包已变化');
        return 'v2';
      },
    );
    addTearDown(workspace.close);
    final session = await track(workspace, 'document.txt');
    await session.file.writeAsString('important edits');
    await workspace.poll();
    await workspace.poll();
    expect(calls, 1);
    expect(session.error, contains('已变化'));
    expect(await session.file.readAsString(), 'important edits');
    failed = false;
    workspace.retry(session);
    await workspace.poll();
    expect(calls, 2);
    expect(session.error, isNull);
    expect(session.pending, isFalse);
  });

  test('重启恢复编辑会话，密码只驻留内存，输入密码后继续回写', () async {
    final first = EditWorkspace(
      root: root,
      settleTime: Duration.zero,
      canUpdate: () => true,
      onChanged: () {},
      update: (session, snapshot) async => 'v2',
    );
    final session = await track(
      first,
      'secret.txt',
      password: 'private-password',
    );
    first.close();
    final manifest = File(p.join(session.directory.path, 'session.json'));
    expect(await manifest.readAsString(), isNot(contains('private-password')));
    await session.file.writeAsString('recover edits');
    final restored = EditWorkspace(
      root: root,
      settleTime: Duration.zero,
      canUpdate: () => true,
      onChanged: () {},
      update: (session, snapshot) async {
        expect(session.password, 'private-password');
        return 'v2';
      },
    );
    addTearDown(restored.close);
    await restored.restore();
    await restored.poll();
    expect(restored.sessions.single.error, contains('密码'));
    restored.sessions.single.password = 'private-password';
    restored.retry(restored.sessions.single);
    await restored.poll();
    expect(restored.sessions.single.pending, isFalse);
  });

  test('同一压缩包多个编辑会话连续更新时接续本应用的新版本', () async {
    final versions = <String>[];
    final workspace = EditWorkspace(
      root: root,
      settleTime: Duration.zero,
      canUpdate: () => true,
      onChanged: () {},
      update: (session, snapshot) async {
        versions.add(session.version);
        return 'v${versions.length + 1}';
      },
    );
    addTearDown(workspace.close);
    final first = await track(workspace, 'first.txt');
    final second = await track(workspace, 'second.txt');
    await first.file.writeAsString('first change');
    await second.file.writeAsString('second change');
    await workspace.poll();
    expect(versions, ['v1', 'v2']);
    expect(first.version, 'v3');
    expect(second.version, 'v3');
  });

  test('结束监控保留编辑文件并停止重启恢复', () async {
    final workspace = EditWorkspace(
      root: root,
      canUpdate: () => true,
      onChanged: () {},
      update: (session, snapshot) async => 'v2',
    );
    addTearDown(workspace.close);
    final session = await track(workspace, 'document.txt');
    await session.file.writeAsString('keep this');
    await workspace.stop(session);
    expect(await session.file.readAsString(), 'keep this');
    expect(workspace.sessions, isEmpty);
    expect(
      File(p.join(session.directory.path, 'session.json')).existsSync(),
      isFalse,
    );
  });

  test('外部程序原子保存后通过真实 FFI 自动更新 ZIP 并保留其他文件', () async {
    final engine = ArchiveEngine();
    final source = File(p.join(root.path, 'document.txt'))
      ..writeAsStringSync('before');
    final other = File(p.join(root.path, 'other.txt'))
      ..writeAsStringSync('keep');
    final archive = p.join(root.path, 'actual.zip');
    await engine.run(
      ArchiveRequest('compress', archive, inputs: [source.path, other.path]),
    );
    final listing = await engine.run(ArchiveRequest('list', archive));
    final index =
        (listing['items'] as List).firstWhere(
              (entry) => entry['path'] == 'document.txt',
            )['index']
            as int;
    final workspace = EditWorkspace(
      root: Directory(p.join(root.path, 'sessions'))..createSync(),
      settleTime: Duration.zero,
      canUpdate: () => true,
      onChanged: () {},
      update: (session, snapshot) async {
        final result = await engine.run(
          ArchiveRequest(
            'update',
            session.archive,
            itemPath: session.itemPath,
            expectedVersion: session.version,
            inputs: [snapshot],
          ),
        );
        return result['version'] as String;
      },
    );
    addTearDown(workspace.close);
    final directory = await workspace.root.createTemp('edit-');
    final files = p.join(directory.path, 'files');
    await engine.run(
      ArchiveRequest('extract', archive, destination: files, indices: [index]),
    );
    final working = File(p.join(files, 'document.txt'));
    final session = await workspace.track(
      directory: directory,
      archive: archive,
      itemPath: 'document.txt',
      file: working,
      version: listing['version'] as String,
      requiresPassword: false,
      password: '',
    );
    final replacement = File('${working.path}.new')
      ..writeAsStringSync('after external save');
    await replacement.rename(working.path);
    await workspace.poll();
    expect(session.error, isNull);
    final output = p.join(root.path, 'output');
    await engine.run(ArchiveRequest('extract', archive, destination: output));
    expect(
      File(p.join(output, 'document.txt')).readAsStringSync(),
      'after external save',
    );
    expect(File(p.join(output, 'other.txt')).readAsStringSync(), 'keep');
  });
}
