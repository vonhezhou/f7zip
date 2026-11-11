import 'package:flutter/material.dart';

import 'app_theme.dart';

class WelcomePanel extends StatelessWidget {
  const WelcomePanel({super.key, this.onOpen, this.onCreate});

  final VoidCallback? onOpen;
  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxHeight < 560;
      return Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: constraints.maxWidth < 700 ? 24 : 32,
            vertical: compact ? 16 : 24,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: compact ? 48 : 56,
                  height: compact ? 48 : 56,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        AppColors.of(context).tint,
                        AppColors.of(context).panel,
                      ],
                    ),
                    border: Border.all(color: AppColors.of(context).border),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(
                    Icons.folder_zip_outlined,
                    size: 28,
                    color: AppColors.of(context).accent,
                  ),
                ),
                SizedBox(height: compact ? 14 : 20),
                Text(
                  '文件打包，从容有序',
                  style: TextStyle(
                    fontSize: constraints.maxWidth < 700 ? 24 : 28,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -1,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '浏览、解压与加密压缩，一处轻松完成。',
                  style: TextStyle(
                    color: AppColors.of(context).secondary,
                    fontSize: 13,
                  ),
                ),
                SizedBox(height: compact ? 14 : 20),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 36),
                        visualDensity: VisualDensity.standard,
                      ),
                      onPressed: onOpen,
                      icon: const Icon(Icons.folder_open_rounded, size: 19),
                      label: const Text('打开压缩包'),
                    ),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 36),
                        visualDensity: VisualDensity.standard,
                      ),
                      onPressed: onCreate,
                      icon: const Icon(Icons.add_rounded, size: 19),
                      label: const Text('新建压缩包'),
                    ),
                  ],
                ),
                SizedBox(height: compact ? 16 : 24),
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(compact ? 12 : 16),
                  decoration: BoxDecoration(
                    color: AppColors.of(context).field,
                    border: Border.all(color: AppColors.of(context).border),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.file_download_outlined,
                        size: 24,
                        color: AppColors.of(context).accent,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '将文件拖到这里',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '拖入压缩包直接浏览，拖入文件或文件夹开始打包',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppColors.of(context).secondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: compact ? 12 : 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final format in [
                      'ZIP',
                      '7Z',
                      'RAR',
                      'TAR',
                      'GZ',
                      'XZ',
                    ])
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: AppColors.of(context).border,
                          ),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          format,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: AppColors.of(context).secondary,
                          ),
                        ),
                      ),
                  ],
                ),
                SizedBox(height: compact ? 8 : 12),
                Text(
                  '本地处理文件 · 支持加密压缩 · 开源桌面工具',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.of(context).secondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
