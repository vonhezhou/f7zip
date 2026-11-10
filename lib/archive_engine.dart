import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'filename_normalization.dart';

typedef _ExportOptionsNative = Void Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Pointer<Utf8>,
);
typedef _ExportOptions = void Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Pointer<Utf8>,
);

typedef _ExtractionOptionsNative = Void Function(
  Pointer<Void>,
  Uint32,
  Pointer<Utf8>,
);
typedef _ExtractionOptions = void Function(Pointer<Void>, int, Pointer<Utf8>);

enum ExtractionPolicy { fail, skip, rename, merge, overwrite }

typedef _VolumeSizeNative = Void Function(Pointer<Void>, Uint64);
typedef _VolumeSize = void Function(Pointer<Void>, int);

typedef _CodePageNative = Void Function(Pointer<Void>, Uint32);
typedef _CodePage = void Function(Pointer<Void>, int);

typedef _CreateNative = Pointer<Void> Function();
typedef _Create = Pointer<Void> Function();
typedef _JobNative = Void Function(Pointer<Void>);
typedef _Job = void Function(Pointer<Void>);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _Free = void Function(Pointer<Utf8>);
typedef _ProgressNative = Pointer<Utf8> Function(Pointer<Void>);
typedef _Progress = Pointer<Utf8> Function(Pointer<Void>);
typedef _RunNative = Pointer<Utf8> Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Int32,
  Pointer<Pointer<Utf8>>,
  Int32,
  Pointer<Uint32>,
  Int32,
);
typedef _Run = Pointer<Utf8> Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  int,
  Pointer<Pointer<Utf8>>,
  int,
  Pointer<Uint32>,
  int,
);

typedef _UpdateNative = Pointer<Utf8> Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
);
typedef _Update = Pointer<Utf8> Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
);

typedef _MutateNative = Pointer<Utf8> Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Pointer<Utf8>>,
  Int32,
);
typedef _Mutate = Pointer<Utf8> Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Pointer<Utf8>>,
  int,
);

class ArchiveEntry {
  const ArchiveEntry({
    required this.index,
    required this.path,
    required this.size,
    required this.packed,
    required this.directory,
    required this.encrypted,
    required this.modified,
    this.method = '',
    this.crc = '',
  });

  factory ArchiveEntry.fromJson(Map<String, dynamic> json) => ArchiveEntry(
    index: json['index'] as int,
    path: json['path'] as String,
    size: json['size'] as int,
    packed: json['packed'] as int,
    directory: json['directory'] as bool,
    encrypted: json['encrypted'] as bool,
    modified: json['modified'] as int,
    method: json['method'] as String? ?? '',
    crc: json['crc'] as String? ?? '',
  );

  final int index;
  final String path;
  final int size;
  final int packed;
  final bool directory;
  final bool encrypted;
  final int modified;
  final String method;
  final String crc;

  String get normalizedPath {
    var value = path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
    while (value.startsWith('./')) {
      value = value.substring(2);
    }
    return value == '.' ? '' : value;
  }

  bool isSelectedBy(Set<String> selection) {
    var candidate = normalizedPath;
    while (candidate.isNotEmpty) {
      if (selection.contains(candidate)) return true;
      final slash = candidate.lastIndexOf('/');
      if (slash < 0) break;
      candidate = candidate.substring(0, slash);
    }
    return false;
  }
}

class ArchiveRequest {
  const ArchiveRequest(
    this.operation,
    this.archive, {
    this.destination = '',
    this.removeRedundantRoot = false,
    this.itemPath = '',
    this.expectedVersion = '',
    this.password = '',
    this.codePage = 0,
    this.filenameNormalization = FilenameNormalization.preserve,
    this.volumeSize = 0,
    this.extractionPolicy = ExtractionPolicy.fail,
    this.expectedDestinationVersion = '',
    this.format = 'zip',
    this.level = 5,
    this.outputLimit = 0,
    this.inputs = const [],
    this.indices = const [],
  });

  ArchiveRequest withPassword(
    String value, {
    FilenameNormalization? filenameNormalization,
  }) => ArchiveRequest(
    operation,
    archive,
    destination: destination,
    removeRedundantRoot: removeRedundantRoot,
    itemPath: itemPath,
    expectedVersion: expectedVersion,
    password: value,
    codePage: codePage,
    filenameNormalization: filenameNormalization ?? this.filenameNormalization,
    volumeSize: volumeSize,
    extractionPolicy: extractionPolicy,
    expectedDestinationVersion: expectedDestinationVersion,
    format: format,
    level: level,
    outputLimit: outputLimit,
    inputs: inputs,
    indices: indices,
  );

  final String operation;
  final String archive;
  final String destination;
  final bool removeRedundantRoot;
  final String itemPath;
  final String expectedVersion;
  final String password;
  final int codePage;
  final FilenameNormalization filenameNormalization;
  final int volumeSize;
  final ExtractionPolicy extractionPolicy;
  final String expectedDestinationVersion;
  final String format;
  final int level;
  final int outputLimit;
  final List<String> inputs;
  final List<int> indices;
}

class ArchiveFailure implements Exception {
  const ArchiveFailure(
    this.message, {
    this.cancelled = false,
    this.passwordRequired = false,
    this.volumeError = false,
    this.conflicts = const [],
    this.destinationVersion = '',
  });
  final String message;
  final bool cancelled;
  final bool passwordRequired;
  final bool volumeError;
  final List<String> conflicts;
  final String destinationVersion;
  @override
  String toString() => message;
}

class ArchiveEngine {
  ArchiveEngine() {
    final override = Platform.environment['F7ZIP_NATIVE_DIR'];
    directory =
        override ??
        p.normalize(
          p.join(
            p.dirname(Platform.resolvedExecutable),
            '..',
            'Frameworks',
            'F7Zip',
          ),
        );
    _library = DynamicLibrary.open(p.join(directory, 'libf7zip.dylib'));
    _create = _library.lookupFunction<_CreateNative, _Create>('f7_job_create');
    _destroy = _library.lookupFunction<_JobNative, _Job>('f7_job_destroy');
    _cancel = _library.lookupFunction<_JobNative, _Job>('f7_job_cancel');
    _progress = _library.lookupFunction<_ProgressNative, _Progress>(
      'f7_job_progress',
    );
    _free = _library.lookupFunction<_FreeNative, _Free>('f7_free');
  }

  late final String directory;
  late final DynamicLibrary _library;
  late final _Create _create;
  late final _Job _destroy;
  late final _Job _cancel;
  late final _Progress _progress;
  late final _Free _free;
  Pointer<Void>? _job;

  Future<Map<String, dynamic>> run(ArchiveRequest request) async {
    if (_job != null) throw const ArchiveFailure('已有任务正在运行');
    if (request.outputLimit < 0) throw const ArchiveFailure('输出资源上限无效');
    final job = _create();
    _job = job;
    final address = job.address;
    final nativeDirectory = directory;
    try {
      final response = await Isolate.run(
        () => _execute(nativeDirectory, address, request),
      );
      if (response['ok'] != true) {
        throw ArchiveFailure(
          response['error'] as String? ?? '操作失败',
          cancelled: response['cancelled'] == true,
          passwordRequired: response['passwordRequired'] == true,
          volumeError: response['volumeError'] == true,
          conflicts: (response['conflicts'] as List? ?? []).cast<String>(),
          destinationVersion: response['destinationVersion'] as String? ?? '',
        );
      }
      return response;
    } finally {
      _job = null;
      _destroy(job);
    }
  }

  Map<String, dynamic>? progress() {
    final job = _job;
    if (job == null) return null;
    final pointer = _progress(job);
    try {
      return jsonDecode(pointer.toDartString()) as Map<String, dynamic>;
    } finally {
      _free(pointer);
    }
  }

  void cancel() {
    final job = _job;
    if (job != null) _cancel(job);
  }
}

Map<String, dynamic> _execute(
  String directory,
  int address,
  ArchiveRequest request,
) {
  final library = DynamicLibrary.open(p.join(directory, 'libf7zip.dylib'));
  final run = library.lookupFunction<_RunNative, _Run>('f7_run');
  final free = library.lookupFunction<_FreeNative, _Free>('f7_free');
  return using((arena) {
    Pointer<Utf8> utf8(String value) => value.toNativeUtf8(allocator: arena);
    final inputs = arena<Pointer<Utf8>>(request.inputs.length + 1);
    for (var i = 0; i < request.inputs.length; i++) {
      inputs[i] = utf8(request.inputs[i]);
    }
    final indices = arena<Uint32>(request.indices.length + 1);
    for (var i = 0; i < request.indices.length; i++) {
      indices[i] = request.indices[i];
    }
    final job = Pointer<Void>.fromAddress(address);
    library.lookupFunction<_CodePageNative, _CodePage>(
      'f7_job_filename_normalization',
    )(job, request.filenameNormalization.index);
    library.lookupFunction<_CodePageNative, _CodePage>('f7_job_codepage')(
      job,
      request.codePage,
    );
    library.lookupFunction<_VolumeSizeNative, _VolumeSize>(
      'f7_job_volume_size',
    )(job, request.volumeSize);
    library.lookupFunction<_ExtractionOptionsNative, _ExtractionOptions>(
      'f7_job_extraction_options',
    )(
      job,
      request.extractionPolicy.index,
      utf8(request.expectedDestinationVersion),
    );
    library.lookupFunction<_VolumeSizeNative, _VolumeSize>(
      'f7_job_output_limit',
    )(job, request.outputLimit);
    if (request.operation == 'export') {
      library.lookupFunction<_ExportOptionsNative, _ExportOptions>(
        'f7_job_export_options',
      )(job, utf8(request.itemPath), utf8(request.expectedVersion));
    }
    final engine = utf8(p.join(directory, '7z.so'));
    Pointer<Utf8> response;
    if (request.operation == 'update') {
      final update = library.lookupFunction<_UpdateNative, _Update>(
        'f7_update',
      );
      response = update(
        job,
        engine,
        utf8(request.archive),
        utf8(request.itemPath),
        utf8(request.inputs.single),
        utf8(request.password),
        utf8(request.expectedVersion),
      );
    } else if (const {
      'add',
      'addReplace',
      'remove',
      'rename',
      'mkdir',
      'restore',
    }.contains(request.operation)) {
      final mutate = library.lookupFunction<_MutateNative, _Mutate>(
        'f7_mutate',
      );
      response = mutate(
        job,
        engine,
        utf8(request.archive),
        utf8(request.operation),
        utf8(request.itemPath),
        utf8(request.destination),
        utf8(request.password),
        utf8(request.expectedVersion),
        inputs,
        request.inputs.length,
      );
    } else {
      response = run(
        job,
        engine,
        utf8(
          request.removeRedundantRoot &&
                  const {
                    'extract',
                    'extractHere',
                    'extractSmart',
                  }.contains(request.operation)
              ? '${request.operation}Flat'
              : request.operation,
        ),
        utf8(request.archive),
        utf8(request.destination),
        utf8(request.password),
        utf8(request.format),
        request.level,
        inputs,
        request.inputs.length,
        indices,
        request.indices.length,
      );
    }
    try {
      return jsonDecode(response.toDartString()) as Map<String, dynamic>;
    } finally {
      free(response);
    }
  });
}
