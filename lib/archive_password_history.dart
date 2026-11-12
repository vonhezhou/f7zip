import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ArchivePasswordRecord {
  const ArchivePasswordRecord({
    required this.id,
    required this.path,
    required this.password,
    required this.createdAt,
  });

  factory ArchivePasswordRecord.fromJson(Map<String, dynamic> json) =>
      ArchivePasswordRecord(
        id: json['id'] as String,
        path: json['path'] as String,
        password: json['password'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
      );

  final String id;
  final String path;
  final String password;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'path': path,
    'password': password,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };
}

class ArchivePasswordHistory {
  static const _storage = FlutterSecureStorage(
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );
  static const _key = 'createdArchivePasswordHistory';
  static Future<void>? _writes;

  static Future<List<ArchivePasswordRecord>> _read() async {
    final value = await _storage.read(key: _key);
    if (value == null) return [];
    return (jsonDecode(value) as List)
        .map(
          (item) => ArchivePasswordRecord.fromJson(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .toList();
  }

  static Future<List<ArchivePasswordRecord>> load() async {
    await _writes;
    return _read();
  }

  // 串行读改写，避免创建与删除同时发生时覆盖其他记录。
  static Future<void> _change(
    void Function(List<ArchivePasswordRecord>) update,
  ) {
    final operation = (_writes ?? Future<void>.value()).then((_) async {
      final records = await _read();
      update(records);
      if (records.isEmpty) {
        await _storage.delete(key: _key);
      } else {
        await _storage.write(
          key: _key,
          value: jsonEncode(records.map((record) => record.toJson()).toList()),
        );
      }
    });
    late final Future<void> settled;
    settled = operation
        .then<void>((_) {}, onError: (Object error, StackTrace stack) {})
        .whenComplete(() {
          if (identical(_writes, settled)) _writes = null;
        });
    _writes = settled;
    return operation;
  }

  static Future<void> remember(String path, String password) {
    if (password.isEmpty) return Future.value();
    final random = Random.secure();
    final record = ArchivePasswordRecord(
      id: List.generate(
        16,
        (_) => random.nextInt(256),
      ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(),
      path: path,
      password: password,
      createdAt: DateTime.now(),
    );
    return _change((records) => records.insert(0, record));
  }

  static Future<void> delete(String id) =>
      _change((records) => records.removeWhere((record) => record.id == id));
}

String generateArchivePassword({
  int length = 20,
  bool uppercase = true,
  bool lowercase = true,
  bool digits = true,
  bool symbols = true,
  bool excludeAmbiguous = true,
}) {
  var groups = [
    if (uppercase) 'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
    if (lowercase) 'abcdefghijklmnopqrstuvwxyz',
    if (digits) '0123456789',
    if (symbols) '!@#\$%^&*()-_=+[]{}?',
  ];
  if (excludeAmbiguous) {
    groups = groups
        .map(
          (group) => group
              .split('')
              .where((character) => !'IloO01'.contains(character))
              .join(),
        )
        .toList();
  }
  if (groups.isEmpty || length < groups.length || length > 128) {
    throw ArgumentError('请选择字符类型，密码长度须为 ${groups.length}–128');
  }
  final random = Random.secure();
  final alphabet = groups.join();
  final characters = [
    for (final group in groups) group[random.nextInt(group.length)],
    for (var index = groups.length; index < length; index++)
      alphabet[random.nextInt(alphabet.length)],
  ];
  characters.shuffle(random);
  return characters.join();
}
