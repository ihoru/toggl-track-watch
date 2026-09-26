import 'package:flutter/material.dart';

String _two(int n) => n.toString().padLeft(2, '0');

/// `1:04:05` for timers.
String formatClock(Duration d) {
  if (d.isNegative) d = Duration.zero;
  return '${d.inHours}:${_two(d.inMinutes % 60)}:${_two(d.inSeconds % 60)}';
}

/// `1h 04m` / `12m` for totals.
String formatTotal(Duration d) {
  if (d.isNegative) d = Duration.zero;
  if (d.inHours == 0) return '${d.inMinutes}m';
  return '${d.inHours}h ${_two(d.inMinutes % 60)}m';
}

String formatTime(BuildContext context, DateTime t) =>
    MaterialLocalizations.of(context)
        .formatTimeOfDay(TimeOfDay.fromDateTime(t), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context));

String formatDay(BuildContext context, DateTime day, [DateTime? now]) {
  now ??= DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  return MaterialLocalizations.of(context).formatShortMonthDay(day);
}

Color colorFromHex(String? hex, {Color fallback = const Color(0xFF9E9E9E)}) {
  if (hex == null) return fallback;
  final value = int.tryParse(hex.replaceFirst('#', ''), radix: 16);
  if (value == null) return fallback;
  return Color(hex.length <= 7 ? 0xFF000000 | value : value);
}

String relativeAgo(DateTime t, [DateTime? now]) {
  final d = (now ?? DateTime.now()).difference(t);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}
