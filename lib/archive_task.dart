import 'package:path/path.dart' as p;

enum ArchiveTaskState {
  queued('等待中'),
  running('执行中'),
  succeeded('已完成'),
  failed('失败'),
  cancelled('已取消');

  const ArchiveTaskState(this.label);
  final String label;
}

class ArchiveTaskDestination {
  bool chosen = false;
  String? path;
}

class ArchiveTask {
  ArchiveTask({
    required this.id,
    required this.action,
    required this.paths,
    required this.fromFinder,
    required this.destination,
  });

  final int id;
  final String action;
  final List<String> paths;
  final bool fromFinder;
  final ArchiveTaskDestination destination;
  ArchiveTaskState state = ArchiveTaskState.queued;
  bool cancelRequested = false;
  String? error;
  String? output;
  double? progress;
  String phase = '';
  String file = '';

  bool get finished =>
      state != ArchiveTaskState.queued && state != ArchiveTaskState.running;

  String get label {
    final operation = switch (action) {
      'compress' || 'compressZip' => '压缩',
      'open' => '打开',
      'test' => '测试',
      _ => '解压',
    };
    final name = paths.isEmpty ? '选择目标目录' : p.basename(paths.first);
    return '$operation · $name${paths.length > 1 ? ' 等 ${paths.length} 项' : ''}';
  }
}
