import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'archive_engine.dart';
import 'app_theme.dart';

class ArchiveTreeNode {
  ArchiveTreeNode(this.path, {required this.directory});

  final String path;
  bool directory;
  final List<ArchiveTreeNode> children = [];
}

ArchiveTreeNode buildArchiveTree(Iterable<ArchiveEntry> entries) {
  final root = ArchiveTreeNode('', directory: true);
  final nodes = <String, ArchiveTreeNode>{'': root};
  for (final entry in entries) {
    if (entry.normalizedPath.isEmpty) continue;
    final parts = entry.normalizedPath.split('/');
    var parent = root;
    var path = '';
    for (var index = 0; index < parts.length; index++) {
      if (parts[index].isEmpty) continue;
      path = path.isEmpty ? parts[index] : '$path/${parts[index]}';
      final directory = index < parts.length - 1 || entry.directory;
      final node = nodes.putIfAbsent(path, () {
        final created = ArchiveTreeNode(path, directory: directory);
        parent.children.add(created);
        return created;
      });
      node.directory = node.directory || directory;
      parent = node;
    }
  }
  for (final node in nodes.values) {
    node.children.sort((a, b) {
      if (a.directory != b.directory) return a.directory ? -1 : 1;
      final order = a.path.toLowerCase().compareTo(b.path.toLowerCase());
      return order == 0 ? a.path.compareTo(b.path) : order;
    });
  }
  return root;
}

class ArchiveTreeView extends StatefulWidget {
  const ArchiveTreeView({
    super.key,
    required this.root,
    required this.folder,
    required this.selected,
    required this.enabled,
    required this.onNavigate,
    required this.onSelectFile,
  });

  final ArchiveTreeNode root;
  final String folder;
  final Set<String> selected;
  final bool enabled;
  final ValueChanged<String> onNavigate;
  final ValueChanged<String> onSelectFile;

  @override
  State<ArchiveTreeView> createState() => _ArchiveTreeViewState();
}

class _ArchiveTreeViewState extends State<ArchiveTreeView> {
  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    _expandAncestors();
  }

  @override
  void didUpdateWidget(covariant ArchiveTreeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.root != widget.root) _expanded.clear();
    _expandAncestors();
  }

  void _expandAncestors() {
    var path = widget.folder;
    while (path.isNotEmpty && path != '.') {
      _expanded.add(path);
      path = p.posix.dirname(path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = <({ArchiveTreeNode node, int depth})>[];
    final pending = widget.root.children.reversed
        .map((node) => (node: node, depth: 0))
        .toList();
    while (pending.isNotEmpty) {
      final row = pending.removeLast();
      rows.add(row);
      if (_expanded.contains(row.node.path)) {
        pending.addAll(
          row.node.children.reversed.map(
            (node) => (node: node, depth: row.depth + 1),
          ),
        );
      }
    }
    if (rows.isEmpty) {
      return Padding(
        padding: EdgeInsets.all(12),
        child: Text(
          '压缩包为空',
          style: TextStyle(
            fontSize: 12,
            color: AppColors.of(context).secondary,
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: rows.length,
      itemExtent: 28,
      itemBuilder: (context, index) {
        final row = rows[index];
        final node = row.node;
        final expanded = _expanded.contains(node.path);
        final selected = node.directory
            ? widget.folder == node.path
            : widget.selected.contains(node.path);
        return Tooltip(
          message: node.path,
          child: Material(
            color: selected ? AppColors.of(context).tint : Colors.transparent,
            borderRadius: BorderRadius.circular(5),
            child: InkWell(
              key: ValueKey('tree:${node.path}'),
              onTap: !widget.enabled
                  ? null
                  : () {
                      if (node.directory) {
                        setState(() => _expanded.add(node.path));
                        widget.onNavigate(node.path);
                      } else {
                        widget.onSelectFile(node.path);
                      }
                    },
              child: Padding(
                padding: EdgeInsets.only(
                  left: (row.depth * 14.0).clamp(0, 126),
                  right: 6,
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 24,
                      height: 28,
                      child: node.directory && node.children.isNotEmpty
                          ? IconButton(
                              key: ValueKey('expand:${node.path}'),
                              padding: EdgeInsets.zero,
                              iconSize: 16,
                              tooltip: expanded ? '折叠' : '展开',
                              onPressed: !widget.enabled
                                  ? null
                                  : () => setState(() {
                                      if (!_expanded.add(node.path)) {
                                        _expanded.remove(node.path);
                                      }
                                    }),
                              icon: Icon(
                                expanded
                                    ? Icons.keyboard_arrow_down
                                    : Icons.keyboard_arrow_right,
                              ),
                            )
                          : null,
                    ),
                    Icon(
                      node.directory
                          ? (expanded
                                ? Icons.folder_open_rounded
                                : Icons.folder_rounded)
                          : Icons.insert_drive_file_outlined,
                      size: 16,
                      color: selected
                          ? AppColors.of(context).onTint
                          : node.directory
                          ? AppColors.of(context).folder
                          : AppColors.of(context).secondary,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        p.posix.basename(node.path),
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
      },
    );
  }
}
