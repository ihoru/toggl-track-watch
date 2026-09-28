import 'dart:async';

import 'package:flutter/material.dart';

import '../src/format.dart';
import '../src/models.dart';
import 'watch_bridge.dart';

/// A scrolling list sized for a round screen, scrollable with the rotary crown.
///
/// On pushed screens, swiping right goes back (the system swipe-to-dismiss is
/// disabled so that it works per screen instead of closing the app). Pager
/// pages set [swipeBack] to false so the pager gets horizontal swipes.
class RoundList extends StatefulWidget {
  const RoundList({super.key, required this.children, this.storageKey, this.active = true, this.swipeBack = true});

  final List<Widget> children;

  /// When set, the scroll position is remembered across app launches under this key.
  final String? storageKey;

  /// Only the active list follows the rotary crown (pager pages that are off screen are inactive).
  final bool active;
  final bool swipeBack;

  @override
  State<RoundList> createState() => _RoundListState();
}

class _RoundListState extends State<RoundList> {
  ScrollController? _controller;
  StreamSubscription<double>? _rotary;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final model = WatchScope.read(context);
    final key = widget.storageKey;
    _controller ??= ScrollController(initialScrollOffset: key == null ? 0 : model.savedOffset(key));
    _rotary?.cancel();
    _rotary = model.bridge.rotary.listen(_onRotary);
  }

  void _onRotary(double delta) {
    final controller = _controller!;
    if (!widget.active || !controller.hasClients || !(ModalRoute.of(context)?.isCurrent ?? true)) return;
    final position = controller.position;
    final target = (position.pixels + delta).clamp(position.minScrollExtent, position.maxScrollExtent);
    controller.jumpTo(target);
    _remember();
  }

  void _remember() {
    final key = widget.storageKey;
    final controller = _controller!;
    if (key != null && controller.hasClients) WatchScope.read(context).saveOffset(key, controller.offset);
  }

  @override
  void dispose() {
    _rotary?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    Widget list = NotificationListener<ScrollEndNotification>(
      onNotification: (_) {
        _remember();
        return false;
      },
      child: ListView(
        controller: _controller,
        padding: EdgeInsets.symmetric(horizontal: size.width * 0.1, vertical: size.height * 0.16),
        children: widget.children,
      ),
    );
    if (widget.swipeBack) {
      list = GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) > 300) Navigator.of(context).maybePop();
        },
        child: list,
      );
    }
    return Scaffold(body: list);
  }
}

/// Small position dots for the pager, placed at the bottom of the round screen.
class PageDots extends StatelessWidget {
  const PageDots({super.key, required this.count, required this.index});

  final int count;
  final int index;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var i = 0; i < count; i++)
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(horizontal: 2.5),
          width: i == index ? 8 : 5,
          height: 5,
          decoration: BoxDecoration(
            color: i == index ? Colors.white : Colors.white38,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
    ],
  );
}

/// The dimmed, low-power screen shown while the watch is in ambient mode:
/// black background, thin white text, updated about once a minute.
class AmbientView extends StatelessWidget {
  const AmbientView({super.key, required this.state});

  final ViewState state;

  @override
  Widget build(BuildContext context) {
    final running = state.running;
    final theme = Theme.of(context);
    final elapsed = running?.duration();
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                elapsed == null ? '—' : '${elapsed.inHours}:${(elapsed.inMinutes % 60).toString().padLeft(2, '0')}',
                style: theme.textTheme.displaySmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w200),
              ),
              Text(
                running == null
                    ? 'No timer running'
                    : (running.description.isEmpty ? '(no description)' : running.description),
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white70),
              ),
            ],
          ),
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
  bool _enabled = true;

  // Paused while tickers are disabled (e.g. behind the ambient screen) to save power.
  late final Timer _timer = Timer.periodic(const Duration(seconds: 1), (_) {
    if (_enabled) setState(() {});
  });

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _enabled = TickerMode.valuesOf(context).enabled;
    _timer; // Start the timer.
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

/// The currently running entry with elapsed time, Stop and Cancel buttons.
class RunningCard extends StatelessWidget {
  const RunningCard({
    super.key,
    required this.entry,
    required this.state,
    required this.onStop,
    this.onCancel,
    this.onTap,
  });

  final TimeEntry entry;
  final ViewState state;
  final VoidCallback onStop;

  /// Discards the running entry (the caller asks for confirmation).
  final VoidCallback? onCancel;
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
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 6,
            runSpacing: 4,
            children: [
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFE57373),
                  foregroundColor: Colors.black,
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: onStop,
                icon: const Icon(Icons.stop),
                label: const Text('Stop'),
              ),
              if (onCancel != null)
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFE57373),
                    side: const BorderSide(color: Color(0xFFE57373)),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: onCancel,
                  child: const Text('Cancel'),
                ),
            ],
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

/// Phone reachability, queue and error line shown on the current-timer page.
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
                      tooltip: 'No',
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
