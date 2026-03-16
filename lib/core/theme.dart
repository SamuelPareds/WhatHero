import 'package:flutter/material.dart';

// Colors - Dark Mode with Aqua Accent (Apple-style)
const Color primaryAqua = Color(0xFF06B6D4); // Cyan/Verde Agua moderno
const Color darkBg = Color(0xFF0F172A); // Fondo muy oscuro (navy)
const Color surfaceDark = Color(0xFF1F2937); // Elementos oscuros (gris oscuro)
const Color white = Color(0xFFF3F4F6); // Texto blanco (no puro)
const Color lightText = Color(0xFFD1D5DB); // Gris claro secundario
const Color accentAqua = Color(0xFF10B981); // Verde más saturado para detalles

/// Build the WhatHero dark theme with aqua accent
ThemeData buildWhatHeroTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(
      seedColor: primaryAqua,
      brightness: Brightness.dark,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: surfaceDark,
      foregroundColor: white,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
    ),
    scaffoldBackgroundColor: darkBg,
  );
}
