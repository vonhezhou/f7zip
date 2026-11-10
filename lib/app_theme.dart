import 'package:flutter/material.dart';

enum AppColorTheme {
  purple('经典紫', Color(0xFF6750A4)),
  green('森林绿', Color(0xFF386A20)),
  teal('青绿色', Color(0xFF006A6A)),
  rose('玫瑰粉', Color(0xFF984061)),
  orange('暖橙色', Color(0xFF8B5000)),
  blue('海洋蓝', Color(0xFF0061A4));

  const AppColorTheme(this.label, this.seedColor);
  final String label;
  final Color seedColor;
}

// 页面区域只映射 Material 3 语义色，随种子色和明暗模式统一变化。
class AppColors {
  const AppColors(this.scheme);
  final ColorScheme scheme;
  static AppColors of(BuildContext context) =>
      AppColors(Theme.of(context).colorScheme);

  Color get canvas => scheme.surface;
  Color get sidebar => scheme.surfaceContainerLow;
  Color get panel => scheme.surfaceContainer;
  Color get field => scheme.surfaceContainerLow;
  Color get alternate => scheme.surfaceContainerLow;
  Color get border => scheme.outlineVariant;
  Color get text => scheme.onSurface;
  Color get secondary => scheme.onSurfaceVariant;
  Color get accent => scheme.primary;
  Color get tint => scheme.primaryContainer;
  Color get onTint => scheme.onPrimaryContainer;
  Color get warning => scheme.errorContainer;
  Color get onWarning => scheme.onErrorContainer;
  Color get selection => scheme.secondaryContainer;
  Color get onSelection => scheme.onSecondaryContainer;
  Color get folder => scheme.tertiary;
}

ThemeData buildAppTheme(
  Brightness brightness, {
  AppColorTheme colorTheme = AppColorTheme.purple,
}) {
  final scheme = ColorScheme.fromSeed(
    seedColor: colorTheme.seedColor,
    brightness: brightness,
  );
  final colors = AppColors(scheme);
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(8));
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: colors.canvas,
    fontFamily: '.AppleSystemUIFont',
    fontFamilyFallback: const ['PingFang SC', 'Heiti SC'],
    visualDensity: VisualDensity.compact,
    textTheme: TextTheme(
      bodyMedium: TextStyle(fontSize: 13, height: 1.35, color: colors.text),
      bodySmall: TextStyle(fontSize: 12, color: colors.secondary),
      titleLarge: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: colors.text,
      ),
      labelLarge: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
    ),
    dividerColor: colors.border,
    iconTheme: IconThemeData(size: 19, color: colors.secondary),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        shape: shape,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: colors.text,
        side: BorderSide(color: colors.border),
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        shape: shape,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: shape),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(shape: shape),
    ),
    listTileTheme: ListTileThemeData(
      dense: true,
      minVerticalPadding: 4,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      titleTextStyle: TextStyle(
        fontFamily: '.AppleSystemUIFont',
        fontFamilyFallback: const ['PingFang SC', 'Heiti SC'],
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: colors.text,
      ),
      subtitleTextStyle: TextStyle(
        fontFamily: '.AppleSystemUIFont',
        fontFamilyFallback: const ['PingFang SC', 'Heiti SC'],
        fontSize: 12,
        height: 1.35,
        color: colors.secondary,
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      side: BorderSide(
        color: colors.secondary.withValues(alpha: 0.6),
        width: 1.3,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colors.border),
      ),
      titleTextStyle: TextStyle(
        fontFamily: '.AppleSystemUIFont',
        fontFamilyFallback: const ['PingFang SC', 'Heiti SC'],
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: colors.text,
      ),
      actionsPadding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: colors.border),
      ),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: colors.accent,
      unselectedLabelColor: colors.secondary,
      dividerColor: colors.border,
      indicatorSize: TabBarIndicatorSize.label,
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: colors.field,
      hintStyle: TextStyle(fontSize: 12, color: colors.secondary),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: colors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: colors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: colors.accent, width: 1.5),
      ),
    ),
  );
}
