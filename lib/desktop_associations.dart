import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

class DesktopAssociations {
  static const _mimeTypes = {
    'zip': 'application/zip',
    'zipx': 'application/zip',
    '7z': 'application/x-7z-compressed',
    'rar': 'application/vnd.rar',
    'tar': 'application/x-tar',
    'gz': 'application/gzip',
    'xz': 'application/x-xz',
    'bz2': 'application/x-bzip2',
    'iso': 'application/x-cd-image',
    'tgz': 'application/x-compressed-tar',
    'tbz': 'application/x-bzip-compressed-tar',
    'tbz2': 'application/x-bzip-compressed-tar',
    'txz': 'application/x-xz-compressed-tar',
    '001': 'application/x-f7zip-volume',
    'z01': 'application/x-f7zip-volume',
    'r00': 'application/x-f7zip-volume',
    'zst': 'application/zstd',
    'cab': 'application/vnd.ms-cab-compressed',
    'dmg': 'application/x-apple-diskimage',
    'wim': 'application/x-ms-wim',
    'jar': 'application/java-archive',
    'apk': 'application/vnd.android.package-archive',
  };
  static const extensions = [
    'zip',
    'zipx',
    '7z',
    'rar',
    'tar',
    'gz',
    'xz',
    'bz2',
    'iso',
    'tgz',
    'tbz',
    'tbz2',
    'txz',
    '001',
    'z01',
    'r00',
    'zst',
    'cab',
    'dmg',
    'wim',
    'jar',
    'apk',
  ];
  static Future<String> _command(String binary, List<String> args) async {
    final result = await Process.run(binary, args);
    if (result.exitCode != 0) throw StateError('${result.stderr}'.trim());
    return '${result.stdout}'.trim();
  }

  static Future<String> _registry(String path, [String? name]) async {
    final result = await Process.run('reg.exe', [
      'query',
      path,
      name == null ? '/ve' : '/v',
      ?name,
    ]);
    if (result.exitCode != 0) return '';
    final match = RegExp(r'REG_SZ\s+([^\r\n]+)').firstMatch('${result.stdout}');
    return match?.group(1)?.trim() ?? '';
  }

  static Future<void> _writeRegistry(
    String path,
    String value, [
    String? name,
  ]) async {
    await _command('reg.exe', [
      'add',
      path,
      name == null ? '/ve' : '/v',
      ?name,
      '/t',
      'REG_SZ',
      '/d',
      value,
      '/f',
    ]);
  }

  static Future<String> _mime(String extension) async => _mimeTypes[extension]!;

  static Future<void> _registerMimeTypes(String root) async {
    final package = File(
      p.join(root, 'mime', 'packages', 'org.f7zip.F7Zip.xml'),
    );
    await package.parent.create(recursive: true);
    final definitions = _mimeTypes.entries
        .map(
          (entry) =>
              '<mime-type type="${entry.value}"><glob pattern="*.${entry.key}"/></mime-type>',
        )
        .join();
    await package.writeAsString(
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">$definitions</mime-info>',
    );
    await _command('update-mime-database', [p.join(root, 'mime')]);
  }

  static Future<String> _current(String extension) async {
    if (Platform.isWindows) {
      final choice = await _registry(
        'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FileExts\\.$extension\\UserChoice',
        'ProgId',
      );
      return choice.isNotEmpty ? choice : _registry('HKCR\\.$extension');
    }
    return _command('xdg-mime', ['query', 'default', await _mime(extension)]);
  }

  static Future<File> get _backupFile async => File(
    p.join((await getApplicationSupportDirectory()).path, 'associations.json'),
  );
  static Future<Map<String, dynamic>> _backups() async {
    final file = await _backupFile;
    return await file.exists()
        ? Map<String, dynamic>.from(
            jsonDecode(await file.readAsString()) as Map,
          )
        : {};
  }

  static Future<List<Map<String, dynamic>>> states() async {
    final backups = await _backups();
    return Future.wait(
      extensions.map((extension) async {
        final current = await _current(extension);
        final ours =
            current ==
            (Platform.isWindows ? 'F7Zip.Archive' : 'org.f7zip.F7Zip.desktop');
        return {
          'extension': extension,
          'application': ours
              ? 'F7Zip'
              : current.isEmpty
              ? '未设置'
              : current,
          'ours': ours,
          'canRestore':
              ours &&
              backups[extension] is String &&
              (backups[extension] as String).isNotEmpty,
        };
      }),
    );
  }

  static Future<void> set(Map<String, dynamic> arguments) async {
    final extension = arguments['extension'] as String;
    if (!extensions.contains(extension)) {
      throw const FormatException('无法识别文件后缀');
    }
    final backups = await _backups();
    final current = await _current(extension);
    final ours = Platform.isWindows
        ? 'F7Zip.Archive'
        : 'org.f7zip.F7Zip.desktop';
    final restore = arguments['restore'] == true;
    if (restore &&
        (backups[extension] is! String ||
            (backups[extension] as String).isEmpty)) {
      throw StateError('没有可恢复的关联');
    }
    if (!restore && current != ours) {
      backups[extension] = current;
      final file = await _backupFile;
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(backups), flush: true);
    }
    if (Platform.isWindows) {
      await _writeRegistry(
        'HKCU\\Software\\Classes\\F7Zip.Archive',
        'F7Zip 压缩包',
      );
      await _writeRegistry(
        'HKCU\\Software\\Classes\\F7Zip.Archive\\shell\\open\\command',
        '"${Platform.resolvedExecutable}" "%1"',
      );
      await _writeRegistry(
        'HKCU\\Software\\Classes\\.$extension',
        restore ? backups[extension] as String : ours,
      );
      await _writeRegistry(
        'HKCU\\Software\\F7Zip\\Capabilities',
        'F7Zip',
        'ApplicationName',
      );
      await _writeRegistry(
        'HKCU\\Software\\F7Zip\\Capabilities\\FileAssociations',
        ours,
        '.$extension',
      );
      await _writeRegistry(
        'HKCU\\Software\\RegisteredApplications',
        'Software\\F7Zip\\Capabilities',
        'F7Zip',
      );
      // Windows 对已有 UserChoice 要求由用户在系统设置中选择默认应用。
      if (await _current(extension) != (restore ? backups[extension] : ours)) {
        await launchUrl(
          Uri.parse('ms-settings:defaultapps?registeredAppUser=F7Zip'),
        );
      }
    } else {
      final root =
          Platform.environment['XDG_DATA_HOME'] ??
          p.join(Platform.environment['HOME']!, '.local', 'share');
      final desktop = File(
        p.join(root, 'applications', 'org.f7zip.F7Zip.desktop'),
      );
      await _registerMimeTypes(root);
      await desktop.parent.create(recursive: true);
      final executable = Platform.resolvedExecutable
          .replaceAll(r'\', r'\\')
          .replaceAll('"', r'\"')
          .replaceAll('`', r'\`')
          .replaceAll(r'$', r'\$')
          .replaceAll('%', '%%');
      await desktop.writeAsString(
        '[Desktop Entry]\nType=Application\nName=F7Zip\nExec="$executable" %F\nTerminal=false\nCategories=Utility;Archiving;\nMimeType=${_mimeTypes.values.toSet().join(';')};\n',
      );
      await _command('xdg-mime', [
        'default',
        restore ? backups[extension] as String : ours,
        await _mime(extension),
      ]);
    }
  }
}
