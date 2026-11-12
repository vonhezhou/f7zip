import 'package:flutter/widgets.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

class DesktopArchiveDrag extends StatefulWidget {
  const DesktopArchiveDrag({
    super.key,
    required this.prepare,
    required this.onError,
    required this.child,
  });
  final Future<List<String>> Function() prepare;
  final void Function(Object error) onError;
  final Widget child;
  @override
  State<DesktopArchiveDrag> createState() => _DesktopArchiveDragState();
}

class _DesktopArchiveDragState extends State<DesktopArchiveDrag> {
  List<String> _paths = [];
  DragItem _item(String path) =>
      DragItem()..add(Formats.fileUri(Uri.file(path)));
  @override
  Widget build(BuildContext context) => DragItemWidget(
    allowedOperations: () => [DropOperation.copy],
    dragItemProvider: (request) async {
      try {
        _paths = await widget.prepare();
        if (_paths.isEmpty) return null;
        return _item(_paths.first);
      } catch (error) {
        widget.onError(error);
        return null;
      }
    },
    child: DraggableWidget(
      onDragConfiguration: (configuration, session) {
        final first = configuration.items.first;
        return DragConfiguration(
          allowedOperations: [DropOperation.copy],
          items: [
            first,
            for (final path in _paths.skip(1))
              DragConfigurationItem(
                item: _item(path),
                image: first.image.retain(),
              ),
          ],
        );
      },
      child: widget.child,
    ),
  );
}
