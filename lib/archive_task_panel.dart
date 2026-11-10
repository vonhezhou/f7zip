import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'archive_task.dart';

class ArchiveTaskPanel extends StatelessWidget {
  const ArchiveTaskPanel({
    super.key,
    required this.tasks,
    required this.engineBusy,
    required this.onCancel,
    required this.onRetry,
    required this.onClear,
    required this.onClose,
    required this.onReveal,
    this.onBatchExtract,
    this.onBatchTest,
  });

  final List<ArchiveTask> tasks;
  final bool engineBusy;
  final ValueChanged<ArchiveTask> onCancel;
  final ValueChanged<ArchiveTask> onRetry;
  final ValueChanged<String> onReveal;
  final VoidCallback onClear;
  final VoidCallback onClose;
  final VoidCallback? onBatchExtract;
  final VoidCallback? onBatchTest;

  @override
  Widget build(BuildContext context) {
    final ordered = [
      ...tasks.where((task) => !task.finished),
      ...tasks.where((task) => task.finished).toList().reversed,
    ];
    final waiting = tasks
        .where((task) => task.state == ArchiveTaskState.queued)
        .length;
    return Container(
      key: const ValueKey('archiveTaskPanel'),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 36,
            child: Row(
              children: [
                const SizedBox(width: 14),
                Text(
                  '任务队列 · $waiting 项等待',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: onBatchExtract,
                  child: const Text('批量解压…'),
                ),
                TextButton(onPressed: onBatchTest, child: const Text('批量测试…')),
                IconButton(
                  tooltip: '清除已结束任务',
                  onPressed: tasks.any((task) => task.finished)
                      ? onClear
                      : null,
                  icon: const Icon(Icons.clear_all, size: 18),
                ),
                IconButton(
                  tooltip: '收起任务队列',
                  onPressed: onClose,
                  icon: const Icon(Icons.expand_more, size: 18),
                ),
              ],
            ),
          ),
          if (ordered.isEmpty)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('选择多个压缩包，按顺序解压或测试', style: TextStyle(fontSize: 12)),
            )
          else
            SizedBox(
              height: math.min(ordered.length, 3) * 56.0,
              child: ListView.builder(
                itemCount: ordered.length,
                itemExtent: 56,
                itemBuilder: (context, index) {
                  final task = ordered[index];
                  final running = task.state == ArchiveTaskState.running;
                  final subtitle =
                      task.error ??
                      (running && !engineBusy
                          ? '等待输入'
                          : running
                          ? '${task.phase}${task.file.isEmpty ? '' : ' · ${task.file}'}'
                          : task.output ?? task.paths.join(', '));
                  return Padding(
                    key: ValueKey('task:${task.id}'),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 70,
                          child: Text(
                            task.cancelRequested && running
                                ? '正在取消'
                                : task.state.label,
                            style: TextStyle(
                              fontSize: 11,
                              color: task.state == ArchiveTaskState.failed
                                  ? Theme.of(context).colorScheme.error
                                  : null,
                            ),
                          ),
                        ),
                        Expanded(
                          child: InkWell(
                            onTap: () => showDialog<void>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: Text(task.label),
                                content: SelectableText(
                                  '${task.state.label}\n${task.paths.join('\n')}\n${task.error ?? task.output ?? ''}',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(context),
                                    child: const Text('关闭'),
                                  ),
                                ],
                              ),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  task.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 12),
                                ),
                                Text(
                                  subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                                ),
                                if (running && engineBusy)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 3),
                                    child: LinearProgressIndicator(
                                      value: task.progress,
                                      minHeight: 2,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        if (!task.finished)
                          IconButton(
                            key: ValueKey('cancel-task:${task.id}'),
                            tooltip: '取消此任务',
                            onPressed: task.cancelRequested
                                ? null
                                : () => onCancel(task),
                            icon: const Icon(Icons.close, size: 17),
                          ),
                        if (task.state == ArchiveTaskState.failed ||
                            task.state == ArchiveTaskState.cancelled)
                          IconButton(
                            key: ValueKey('retry-task:${task.id}'),
                            tooltip: '重试此任务',
                            onPressed: () => onRetry(task),
                            icon: const Icon(Icons.refresh, size: 17),
                          ),
                        if (task.state == ArchiveTaskState.succeeded &&
                            task.output != null)
                          IconButton(
                            tooltip: '在 Finder 中显示任务结果',
                            onPressed: () => onReveal(task.output!),
                            icon: const Icon(
                              Icons.folder_open_outlined,
                              size: 17,
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
