import 'package:flutter/material.dart';

import '../src/theme.dart';
import 'screens.dart';
import 'watch_bridge.dart';
import 'widgets.dart';

class WearApp extends StatefulWidget {
  const WearApp({super.key, required this.bridge});

  final WatchBridge bridge;

  @override
  State<WearApp> createState() => _WearAppState();
}

class _WearAppState extends State<WearApp> {
  late final WatchModel _model = WatchModel(widget.bridge);

  /// Whether the app is on screen; running clocks stop ticking in the background.
  bool _visible = true;
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(
    onStateChange: (state) {
      final visible = state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
      if (visible != _visible) setState(() => _visible = visible);
    },
  );

  @override
  void initState() {
    super.initState();
    _lifecycle;
  }

  @override
  void dispose() {
    _lifecycle.dispose();
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
        // In ambient mode the regular UI stays mounted (keeping pages and scroll
        // positions) but hidden and paused behind the low-power view.
        builder: (context, child) => ListenableBuilder(
          listenable: _model,
          builder: (context, _) => Stack(
            children: [
              TickerMode(
                enabled: _visible && !_model.ambient,
                child: Offstage(offstage: _model.ambient, child: child),
              ),
              if (_model.ambient) Positioned.fill(child: AmbientView(state: _model.state)),
            ],
          ),
        ),
        home: const HomePager(),
      ),
    );
  }
}
