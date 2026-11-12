import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pdfrx/pdfrx.dart';

class DesktopPreview {
  DesktopPreview(this.child, this.dispose);
  final Widget child;
  final Future<void> Function() dispose;
}

Future<DesktopPreview> prepareDesktopPreview(
  Map<String, String> arguments,
) async {
  final file = File(arguments['path']!);
  final status = await FileSystemEntity.type(file.path, followLinks: false);
  final kind = arguments['kind'];
  if (status != FileSystemEntityType.file ||
      await file.length() > (kind == 'text' ? 4 : 256) * 1024 * 1024) {
    throw const FormatException('文件无效或超过预览资源上限');
  }
  switch (kind) {
    case 'text':
      final bytes = await file.readAsBytes();
      final text = utf8.decode(bytes, allowMalformed: true);
      return DesktopPreview(
        SingleChildScrollView(child: SelectableText(text)),
        () async {},
      );
    case 'image':
      final buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
      ui.ImageDescriptor? descriptor;
      ui.Codec? codec;
      try {
        descriptor = await ui.ImageDescriptor.encoded(buffer);
        if (descriptor.width > 16384 ||
            descriptor.height > 16384 ||
            descriptor.width * descriptor.height > 40000000) {
          throw const FormatException('图片超过预览资源上限');
        }
        codec = await descriptor.instantiateCodec();
        if (codec.frameCount > 512 ||
            descriptor.width * descriptor.height * codec.frameCount >
                80000000) {
          throw const FormatException('动画超过预览资源上限');
        }
      } finally {
        codec?.dispose();
        descriptor?.dispose();
        buffer.dispose();
      }
      return DesktopPreview(
        InteractiveViewer(child: Image.file(file)),
        () async {
          await FileImage(file).evict();
        },
      );
    case 'pdf':
      final document = await PdfDocument.openFile(file.path);
      if (document.pages.length > 1000) {
        await document.dispose();
        throw const FormatException('PDF 超过 1000 页');
      }
      return DesktopPreview(
        PdfViewer(PdfDocumentRefDirect(document, autoDispose: false)),
        document.dispose,
      );
    case 'audio':
    case 'video':
      MediaKit.ensureInitialized();
      final player = Player();
      try {
        final controller = VideoController(player);
        await player.open(Media(file.uri.toString()));
        return DesktopPreview(Video(controller: controller), player.dispose);
      } catch (_) {
        await player.dispose();
        rethrow;
      }
    default:
      throw const FormatException('无法预览此类型');
  }
}

class DesktopPreviewDialog extends StatelessWidget {
  const DesktopPreviewDialog({
    super.key,
    required this.preview,
    required this.title,
  });
  final DesktopPreview preview;
  final String title;
  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 960,
      height: 680,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(child: Text(title, overflow: TextOverflow.ellipsis)),
                IconButton(
                  tooltip: '关闭预览',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(child: preview.child),
          ],
        ),
      ),
    ),
  );
}
