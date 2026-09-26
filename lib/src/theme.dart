import 'package:flutter/material.dart';

const togglPink = Color(0xFFE57CD8);

ThemeData darkTheme({bool watch = false}) {
  final scheme = ColorScheme.fromSeed(
    seedColor: togglPink,
    brightness: Brightness.dark,
  ).copyWith(surface: watch ? Colors.black : const Color(0xFF121212));
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    visualDensity: watch ? VisualDensity.compact : VisualDensity.standard,
    useMaterial3: true,
  );
}
