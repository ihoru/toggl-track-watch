import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../src/format.dart';
import '../src/models.dart';
import 'watch_bridge.dart';

/// A scrolling list sized for a round screen, scrollable with the rotary crown.
/// Swiping right goes back (the system swipe-to-dismiss is disabled so that it
/// works per screen instead of closing the app).
class RoundList extends StatefulWidget {
  const RoundList({super.key, required this.children, this.onSwipeBack});

  final List<Widget> children;

  /// Defaults to popping the current route, or leaving the app on the first screen.
  final VoidCallback? onSwipeBack;

  @override
  State<RoundList> createState() => _RoundListState();
}

class _RoundListState extends State<RoundList> {
  final _controller = ScrollController();
  StreamSubscription<double>? _rotary;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _rotary?.cancel();
    _rotary = WatchScope.read(context).bridge.rotary.listen(_onRotary);
  }

  void _onRotary(double delta) {
    if (!_controller.hasClients || !(ModalRoute.of(context)?.isCurrent ?? true)) return;
    final position = _controller.position;
    final target = (position.pixels + delta).clamp(position.minScrollExtent, position.maxScrollExtent);
    _controller.jumpTo(target);
  }

  @override
  void dispose() {
    _rotary?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _back() {
    if (widget.onSwipeBack != null) return widget.onSwipeBack!();
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    } else {
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Scaffold(
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) > 300) _back();
        },
        child: ListView(
          controller: _controller,
          padding: EdgeInsets.symmetric(horizontal: size.width * 0.1, vertical: size.height * 0.16),
          children: widget.children,
        ),
      ),
    );
  }
}

class WearHeader extends StatelessWidget {
  const WearHeader(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Colors.white70),
    ),
  );
}

/// A pill-shaped button, the basic building block of the watch UI.
class WearChip extends StatelessWidget {
  const WearChip({
    super.key,
    required this.label,
    this.secondary,
    this.color,
    this.icon,
    this.onTap,
    this.background,
    this.trailing,
  });

  final String label;
  final String? secondary;
  final Color? color;
  final IconData? icon;
  final VoidCallback? onTap;
  final Color? background;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: background ?? const Color(0xFF202124),
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                if (icon != null)
                  Icon(icon, size: 20, color: color)
                else if (color != null)
                  Icon(Icons.circle, size: 12, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
                      if (secondary != null)
                        Text(
                          secondary!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(color: Colors.white60),
                        ),
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Rebuilds every second, for running timers.
class Ticking extends StatefulWidget {
  const Ticking({super.key, required this.builder});

  final WidgetBuilder builder;

  @override
  State<Ticking> createState() => _TickingState();
}

class _TickingState extends State<Ticking> {
  late final Timer _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

/// The currently running entry with elapsed time and a Stop button.
class RunningCard extends StatelessWidget {
  const RunningCard({super.key, required this.entry, required this.state, required this.onStop, this.onTap});

  final TimeEntry entry;
  final ViewState state;
  final VoidCallback onStop;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final project = state.project(entry.projectId);
    final color = colorFromHex(project?.color);
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Ticking(
            builder: (context) => Text(
              formatClock(entry.duration()),
              style: theme.textTheme.headlineMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  entry.description.isEmpty ? '(no description)' : entry.description,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge,
                ),
              ),
              if (entry.pending) const PendingIcon(),
            ],
          ),
          Text(
            project?.name ?? 'No project',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
          const SizedBox(height: 6),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE57373), foregroundColor: Colors.black),
            onPressed: onStop,
            icon: const Icon(Icons.stop),
            label: const Text('Stop'),
          ),
        ],
      ),
    );
  }
}

class PendingIcon extends StatelessWidget {
  const PendingIcon({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.only(left: 4),
    child: Tooltip(
      message: 'Not synced yet',
      child: Icon(Icons.sync, size: 14, color: Colors.white54),
    ),
  );
}

/// Phone reachability, queue and error line shown at the top of the home screen.
class StatusLine extends StatelessWidget {
  const StatusLine({super.key, required this.state});

  final ViewState state;

  @override
  Widget build(BuildContext context) {
    final String? text;
    if (!state.phoneReachable) {
      text = state.pendingCount > 0 ? 'Phone offline · ${state.pendingCount} queued' : 'Phone offline';
    } else if (state.rateLimitedUntil != null) {
      text = 'Toggl limit · ${state.pendingCount} queued';
    } else if (state.error != null) {
      text = state.error;
    } else if (state.pendingCount > 0) {
      text = 'Syncing ${state.pendingCount}…';
    } else {
      text = null;
    }
    if (text == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.amberAccent),
      ),
    );
  }
}

/// Full-screen yes/no confirmation.
Future<bool> confirm(BuildContext context, String question) async {
  final result = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (context) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(question, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton.filledTonal(
                      tooltip: 'Cancel',
                      onPressed: () => Navigator.pop(context, false),
                      icon: const Icon(Icons.close),
                    ),
                    IconButton.filled(
                      tooltip: 'Confirm',
                      style: IconButton.styleFrom(backgroundColor: const Color(0xFFE57373)),
                      onPressed: () => Navigator.pop(context, true),
                      icon: const Icon(Icons.check),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  return result ?? false;
}
