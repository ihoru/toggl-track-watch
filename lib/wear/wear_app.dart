import 'package:flutter/material.dart';

import '../src/theme.dart';
import 'screens.dart';
import 'watch_bridge.dart';

class WearApp extends StatefulWidget {
  const WearApp({super.key, required this.bridge});

  final WatchBridge bridge;

  @override
  State<WearApp> createState() => _WearAppState();
}

class _WearAppState extends State<WearApp> {
  late final WatchModel _model = WatchModel(widget.bridge);

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WatchScope(
      model: _model,
      child: MaterialApp(
        title: 'Track Watch',
        theme: darkTheme(watch: true),
        debugShowCheckedModeBanner: false,
        home: const HomeScreen(),
      ),
    );
  }
}
