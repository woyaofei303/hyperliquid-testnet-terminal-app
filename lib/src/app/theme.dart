// 全局深色配色、输入框和导航样式。统一在这里调整基础视觉，避免页面各自覆盖。

import 'package:flutter/material.dart';

/// 背景、正文、涨跌色的唯一基础定义，组件引用这些语义颜色。
abstract final class AppColors {
  static const canvas = Color(0xFF0B1316);
  static const panel = Color(0xFF131F23);
  static const surface = Color(0xFF213035);
  static const border = Color(0xFF2B3A3F);
  static const text = Color(0xFFE1ECEC);
  static const muted = Color(0xFFA0B2B6);
  static const accent = Color(0xFF50D2C1);
  static const positive = Color(0xFF00B996);
  static const negative = Color(0xFFF25668);
}

// 生成 Material 主题，输入框采用内部浮动标签以避免标签压在边框上。
ThemeData buildTerminalTheme() {
  const scheme = ColorScheme.dark(
    primary: AppColors.accent,
    secondary: AppColors.accent,
    surface: AppColors.panel,
    error: AppColors.negative,
    onPrimary: AppColors.panel,
    onSecondary: AppColors.panel,
    onSurface: AppColors.text,
  );

  return ThemeData(
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.canvas,
    cardColor: AppColors.panel,
    dividerColor: AppColors.border,
    useMaterial3: true,
    dividerTheme: const DividerThemeData(
      color: AppColors.border,
      thickness: .7,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.panel,
      surfaceTintColor: Colors.transparent,
      dragHandleColor: AppColors.muted,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.canvas,
      foregroundColor: AppColors.text,
      elevation: 0,
      centerTitle: false,
      toolbarHeight: 48,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: AppColors.panel,
      height: 62,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 22,
          color: states.contains(WidgetState.selected)
              ? AppColors.accent
              : AppColors.muted,
        ),
      ),
      indicatorColor: AppColors.accent.withValues(alpha: 0.16),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          color: states.contains(WidgetState.selected)
              ? AppColors.accent
              : AppColors.muted,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      hintStyle: const TextStyle(color: AppColors.muted),
      floatingLabelStyle: const TextStyle(color: AppColors.muted),
      border: const UnderlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
        borderSide: BorderSide.none,
      ),
      enabledBorder: const UnderlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
        borderSide: BorderSide.none,
      ),
      focusedBorder: const UnderlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
        borderSide: BorderSide(color: AppColors.accent),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    ),
  );
}
