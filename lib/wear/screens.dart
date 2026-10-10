import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../src/format.dart';
import '../src/links.dart';
import '../src/models.dart';
import 'watch_bridge.dart';
import 'widgets.dart';

Future<T?> _push<T>(BuildContext context, Widget screen) =>
    Navigator.of(context).push<T>(MaterialPageRoute(builder: (_) => screen));

/// Starts a timer, closes any open sub-screens and shows the current-timer page.
void startTimer(BuildContext context, String description, int? projectId) {
  WatchScope.read(context).start(description, projectId);
  Navigator.of(context).popUntil((r) => r.isFirst);
}

/// The six sections, swiped left/right: Now, Favorites, History, Recent, Frequent, Sync.
class HomePager extends StatefulWidget {
  const HomePager({super.key});

  static const pageCount = 6;

  @override
  State<HomePager> createState() => _HomePagerState();
}

class _HomePagerState extends State<HomePager> {
  PageController? _controller;
  int _page = 0;
  WatchModel? _model;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final model = WatchScope.of(context);
    if (_model != model) {
      _model?.startSignal.removeListener(_showNow);
      model.startSignal.addListener(_showNow);
      _model = model;
    }
    if (_controller == null && model.loaded) {
      _page = model.savedPage.clamp(0, HomePager.pageCount - 1);
      _controller = PageController(initialPage: _page);
    }
  }

  /// How far the user has dragged past the first page; far enough closes the app.
  double _pull = 0;

  /// Swiping right on the first page closes the app, like the system swipe-to-dismiss
  /// (which is turned off so that swipes work inside the app).
  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0 || n.metrics.axis != Axis.horizontal) return false;
    if (n is OverscrollNotification && _page == 0 && n.overscroll < 0) {
      _pull -= n.overscroll;
      if (_pull > MediaQuery.sizeOf(context).width * 0.2) {
        _pull = 0;
        SystemNavigator.pop();
      }
    } else if (n is ScrollEndNotification) {
      _pull = 0;
    }
    return false;
  }

  void _showNow() {
    final controller = _controller;
    if (controller == null || !controller.hasClients) return;
    // Behind a detail screen animations are paused, so jump instead of animating.
    if (ModalRoute.of(context)?.isCurrent ?? true) {
      controller.animateToPage(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    } else {
      controller.jumpToPage(0);
    }
  }

  @override
  void dispose() {
    _model?.startSignal.removeListener(_showNow);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = WatchScope.of(context);
    final controller = _controller;
    if (!model.loaded || controller == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!model.state.configured) return const SetupScreen();
    final bottom = MediaQuery.sizeOf(context).height * 0.05;
    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: PageView(
            controller: controller,
            onPageChanged: (page) {
              setState(() => _page = page);
              model.savePage(page);
            },
            children: [
              NowPage(active: _page == 0),
              FavoritesPage(active: _page == 1),
              HistoryPage(active: _page == 2),
              RecentPage(active: _page == 3),
              FrequentPage(active: _page == 4),
              SyncPage(active: _page == 5),
            ],
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: bottom,
          child: IgnorePointer(
            child: Center(
              child: PageDots(count: HomePager.pageCount, index: _page),
            ),
          ),
        ),
      ],
    );
  }
}

class NowPage extends StatelessWidget {
  const NowPage({super.key, this.active = true});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final model = WatchScope.of(context);
    final state = model.state;
    final running = state.running;
    final recent = state.recentTimers(limit: 3);
    return RoundList(
      storageKey: 'now',
      active: active,
      swipeBack: false,
      children: [
        StatusLine(state: state),
        if (running != null)
          RunningCard(
            entry: running,
            state: state,
            onStop: () {
              WatchScope.read(context).haptic();
              model.bridge.stop(running.id);
            },
            onCancel: () async {
              if (!await confirm(context, 'Discard this timer?')) return;
              model.haptic();
              await model.bridge.delete(running.id);
            },
            onTap: () => _push(context, EntryScreen(entry: running)),
          )
        else
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('No timer running', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleSmall),
          ),
        WearChip(
          label: 'New timer',
          icon: Icons.add,
          color: Theme.of(context).colorScheme.primary,
          onTap: () => _push(context, const EditScreen.create()),
        ),
        for (final r in recent)
          WearChip(
            label: r.description.isEmpty ? (state.project(r.projectId)?.name ?? '(no description)') : r.description,
            secondary: 'Continue · ${state.project(r.projectId)?.name ?? 'No project'}',
            icon: Icons.play_arrow,
            color: colorFromHex(state.project(r.projectId)?.color),
            onTap: () => startTimer(context, r.description, r.projectId),
          ),
      ],
    );
  }
}

class FavoritesPage extends StatelessWidget {
  const FavoritesPage({super.key, this.active = true});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final state = WatchScope.of(context).state;
    return RoundList(
      storageKey: 'favorites',
      active: active,
      swipeBack: false,
      children: [
        const WearHeader('Favorites'),
        if (state.favorites.isEmpty)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Add favorites in the phone app.', textAlign: TextAlign.center),
          ),
        for (final f in state.favorites)
          _TimerChip(
            description: f.description,
            projectId: f.projectId,
            state: state,
            onTap: () => startTimer(context, f.description, f.projectId),
          ),
      ],
    );
  }
}

class RecentPage extends StatelessWidget {
  const RecentPage({super.key, this.active = true});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final state = WatchScope.of(context).state;
    final recent = state.recentTimers();
    return RoundList(
      storageKey: 'recent',
      active: active,
      swipeBack: false,
      children: [
        const WearHeader('Recent'),
        if (recent.isEmpty)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Nothing tracked in the last 30 days yet.', textAlign: TextAlign.center),
          ),
        for (final r in recent)
          _TimerChip(
            description: r.description,
            projectId: r.projectId,
            state: state,
            onTap: () => startTimer(context, r.description, r.projectId),
          ),
      ],
    );
  }
}

class FrequentPage extends StatelessWidget {
  const FrequentPage({super.key, this.active = true});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final state = WatchScope.of(context).state;
    return RoundList(
      storageKey: 'frequent',
      active: active,
      swipeBack: false,
      children: [
        const WearHeader('Frequent · 30 days'),
        if (state.frequent.isEmpty)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Nothing tracked in the last 30 days yet.', textAlign: TextAlign.center),
          ),
        for (final f in state.frequent)
          _TimerChip(
            description: f.description,
            projectId: f.projectId,
            state: state,
            count: f.count,
            onTap: () => startTimer(context, f.description, f.projectId),
          ),
      ],
    );
  }
}

class _TimerChip extends StatelessWidget {
  const _TimerChip({
    required this.description,
    required this.projectId,
    required this.state,
    required this.onTap,
    this.count,
  });

  final String description;
  final int? projectId;
  final ViewState state;
  final VoidCallback onTap;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final project = state.project(projectId);
    final projectName = project?.name ?? 'No project';
    return WearChip(
      label: description.isEmpty ? (project?.name ?? '(no description)') : description,
      secondary: count == null ? projectName : '$projectName · ×$count',
      color: colorFromHex(project?.color),
      onTap: onTap,
      trailing: const Icon(Icons.play_arrow, size: 18),
    );
  }
}

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key, this.active = true});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final state = WatchScope.of(context).state;
    final days = state.days();
    return RoundList(
      storageKey: 'history',
      active: active,
      swipeBack: false,
      children: [
        const WearHeader('History'),
        if (days.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No entries in the last 7 days', textAlign: TextAlign.center),
          ),
        for (final day in days) ...[
          Ticking(builder: (context) => WearHeader('${formatDay(context, day.day)} · ${formatTotal(day.total())}')),
          for (final e in day.entries) _EntryChip(entry: e, state: state),
        ],
      ],
    );
  }
}

class _EntryChip extends StatelessWidget {
  const _EntryChip({required this.entry, required this.state});

  final TimeEntry entry;
  final ViewState state;

  @override
  Widget build(BuildContext context) {
    final project = state.project(entry.projectId);
    final range = entry.isRunning
        ? '${formatTime(context, entry.start)} – now'
        : '${formatTime(context, entry.start)} – ${formatTime(context, entry.stop!)}';
    return WearChip(
      label: entry.description.isEmpty ? '(no description)' : entry.description,
      secondary: '$range · ${formatTotal(entry.duration())}',
      color: colorFromHex(project?.color),
      trailing: entry.pending ? const PendingIcon() : null,
      onTap: () => _push(context, EntryScreen(entry: entry)),
    );
  }
}

/// Sync status, Refresh and Open on phone.
class SyncPage extends StatefulWidget {
  const SyncPage({super.key, this.active = true});

  final bool active;

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  String? _message;

  @override
  Widget build(BuildContext context) {
    final model = WatchScope.of(context);
    final state = model.state;
    final lines = [
      state.phoneReachable ? 'Phone connected' : 'Phone offline',
      if (state.pendingCount > 0) '${state.pendingCount} change(s) queued',
      state.lastSync == null ? 'Never synced' : 'Synced ${relativeAgo(state.lastSync!)}',
      if (state.quotaLeft() case final left?) '$left Toggl API requests left',
      if (state.rateLimitedUntil case final until?) 'API limit until ${formatTime(context, until)}',
      ?state.error,
    ];
    return RoundList(
      storageKey: 'sync',
      active: widget.active,
      swipeBack: false,
      children: [
        const WearHeader('Sync'),
        for (final line in lines) Text(line, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        WearChip(
          label: 'Refresh',
          icon: Icons.refresh,
          onTap: () {
            model.bridge.refresh();
            setState(() => _message = 'Refresh requested');
          },
        ),
        WearChip(
          label: 'Open on phone',
          icon: Icons.phone_android,
          onTap: () async {
            final ok = await model.bridge.openOnPhone();
            if (mounted) setState(() => _message = ok ? 'Opened on phone' : 'Phone not reachable');
          },
        ),
        WearChip(label: 'Settings', icon: Icons.settings, onTap: () => _push(context, const SettingsScreen())),
        if (model.version.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Track Watch ${model.version}',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.white54),
            ),
          ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(_message!, textAlign: TextAlign.center, style: Theme.of(context).textTheme.labelSmall),
          ),
      ],
    );
  }
}

/// Shown until the phone app is set up: the watch needs the phone app for everything.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  String? _message;

  Future<void> _open(Future<bool> Function() open, String done) async {
    final ok = await open();
    if (mounted) setState(() => _message = ok ? done : 'Phone not reachable');
  }

  @override
  Widget build(BuildContext context) {
    final bridge = WatchScope.of(context).bridge;
    return RoundList(
      swipeBack: false,
      children: [
        const Icon(Icons.phone_android, size: 32),
        const SizedBox(height: 8),
        const Text(
          'Track Watch works together with its phone app. Install it on your phone and add your Toggl API token there.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        WearChip(
          label: 'Install on phone',
          icon: Icons.download,
          onTap: () => _open(() => bridge.openUrlOnPhone(installUrl), 'Opened on phone'),
        ),
        WearChip(
          label: 'Open on phone',
          icon: Icons.open_in_new,
          secondary: 'If already installed',
          onTap: () => _open(bridge.openOnPhone, 'Opened on phone'),
        ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(_message!, textAlign: TextAlign.center, style: Theme.of(context).textTheme.labelSmall),
          ),
      ],
    );
  }
}

/// Watch settings and About.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String? _message;

  Future<void> _openLink(String url) async {
    final ok = await WatchScope.read(context).bridge.openUrlOnPhone(url);
    if (mounted) setState(() => _message = ok ? 'Opened on phone' : 'Phone not reachable');
  }

  @override
  Widget build(BuildContext context) {
    final model = WatchScope.of(context);
    Widget toggle(String label, String secondary, bool value, ValueChanged<bool> onChanged) => WearChip(
      label: label,
      secondary: secondary,
      onTap: () => onChanged(!value),
      trailing: Switch(value: value, onChanged: onChanged),
    );
    return RoundList(
      children: [
        const WearHeader('Settings'),
        toggle(
          'Timer notification',
          'Icon on watch face while running',
          model.showOngoing,
          (v) => model.setSetting('ongoing', v),
        ),
        toggle('Vibration', 'On start, stop and save', model.haptics, (v) => model.setSetting('haptics', v)),
        WearChip(
          label: 'Crown step: ${model.crownStep} min',
          secondary: 'Editing start/end time · tap to change',
          icon: Icons.av_timer,
          onTap: () => model.setSetting('crownStep', model.crownStep == 1 ? 5 : 1),
        ),
        const WearHeader('About'),
        if (model.version.isNotEmpty)
          Text(
            'Track Watch ${model.version}',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        WearChip(label: 'Privacy policy', icon: Icons.privacy_tip_outlined, onTap: () => _openLink(privacyUrl)),
        WearChip(label: 'Source code', icon: Icons.code, onTap: () => _openLink(sourceUrl)),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(_message!, textAlign: TextAlign.center, style: Theme.of(context).textTheme.labelSmall),
          ),
      ],
    );
  }
}

/// Details and actions for one entry: stop, continue, edit, edit start/end time, delete.
class EntryScreen extends StatelessWidget {
  const EntryScreen({super.key, required this.entry});

  /// The entry as it was when opened; live data is looked up by id (also once an
  /// offline-created entry receives its Toggl id), or else by start time.
  final TimeEntry entry;

  TimeEntry? _live(ViewState state) {
    final byId = state.entry(entry.id) ?? state.entry(state.idMap[entry.id] ?? entry.id);
    if (byId != null) return byId;
    for (final e in state.entries) {
      if (e.start == entry.start) return e;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final model = WatchScope.of(context);
    final state = model.state;
    final bridge = model.bridge;
    final e = _live(state);
    if (e == null) {
      return const RoundList(
        children: [
          SizedBox(height: 40),
          Text('Entry deleted', textAlign: TextAlign.center),
        ],
      );
    }
    final project = state.project(e.projectId);
    final theme = Theme.of(context);
    return RoundList(
      children: [
        Text(
          e.description.isEmpty ? '(no description)' : e.description,
          textAlign: TextAlign.center,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium,
        ),
        Text(
          project?.name ?? 'No project',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(color: colorFromHex(project?.color)),
        ),
        const SizedBox(height: 4),
        Ticking(
          builder: (context) => Text(
            '${formatTime(context, e.start)} – ${e.isRunning ? 'now' : formatTime(context, e.stop!)}\n'
            '${formatClock(e.duration())}${e.pending ? ' · not synced' : ''}',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 8),
        if (e.isRunning)
          WearChip(
            label: 'Stop',
            icon: Icons.stop,
            color: const Color(0xFFE57373),
            onTap: () {
              WatchScope.read(context).haptic();
              bridge.stop(e.id);
            },
          )
        else
          WearChip(
            label: 'Continue',
            icon: Icons.play_arrow,
            color: Colors.lightGreenAccent,
            onTap: () => startTimer(context, e.description, e.projectId),
          ),
        WearChip(
          label: 'Edit start time',
          icon: Icons.schedule,
          onTap: () => _push(context, TimeScreen(entry: e)),
        ),
        if (!e.isRunning)
          WearChip(
            label: 'Edit end time',
            icon: Icons.update,
            onTap: () => _push(context, TimeScreen(entry: e, end: true)),
          ),
        WearChip(
          label: 'Edit',
          icon: Icons.edit,
          onTap: () => _push(context, EditScreen.edit(entry: e)),
        ),
        WearChip(
          label: 'Delete',
          icon: Icons.delete_outline,
          color: const Color(0xFFE57373),
          onTap: () async {
            if (!await confirm(context, 'Delete this entry?')) return;
            await bridge.delete(e.id);
            if (context.mounted) Navigator.of(context).pop();
          },
        ),
      ],
    );
  }
}

/// Edits description and project; used both to start a new timer and to edit an entry.
class EditScreen extends StatefulWidget {
  const EditScreen.create({super.key}) : entry = null;

  const EditScreen.edit({super.key, required TimeEntry this.entry});

  final TimeEntry? entry;

  @override
  State<EditScreen> createState() => _EditScreenState();
}

class _EditScreenState extends State<EditScreen> {
  late String _description = widget.entry?.description ?? '';
  late int? _projectId = widget.entry?.projectId;

  @override
  Widget build(BuildContext context) {
    final model = WatchScope.of(context);
    final state = model.state;
    final project = state.project(_projectId);
    final creating = widget.entry == null;
    return RoundList(
      children: [
        WearHeader(creating ? 'New timer' : 'Edit entry'),
        WearChip(
          label: _description.isEmpty ? 'Add description' : _description,
          secondary: 'Description',
          icon: Icons.keyboard_voice,
          onTap: () async {
            final text = await model.bridge.textInput('Description');
            if (text != null) setState(() => _description = text.trim());
          },
        ),
        WearChip(
          label: project?.name ?? 'No project',
          secondary: 'Project',
          color: colorFromHex(project?.color),
          onTap: () async {
            final choice = await _push<ProjectChoice>(context, ProjectPicker(selected: _projectId));
            if (choice != null) setState(() => _projectId = choice.id);
          },
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          icon: Icon(creating ? Icons.play_arrow : Icons.check),
          label: Text(creating ? 'Start' : 'Save'),
          onPressed: () {
            if (creating) {
              startTimer(context, _description, _projectId);
            } else {
              WatchScope.read(context).haptic();
              model.bridge.update(widget.entry!.id, _description, _projectId);
              Navigator.of(context).pop();
            }
          },
        ),
      ],
    );
  }
}

/// Moves the start (or, with [end], the end) time of an entry: turn the crown (one minute
/// per step) or tap ±5 / ±15. Times stay between the entry's other end and now.
class TimeScreen extends StatefulWidget {
  const TimeScreen({super.key, required this.entry, this.end = false});

  final TimeEntry entry;

  /// Edits the end time of a stopped entry instead of the start time.
  final bool end;

  @override
  State<TimeScreen> createState() => _TimeScreenState();
}

class _TimeScreenState extends State<TimeScreen> {
  /// Crown scroll distance (logical pixels) per step (1 or 5 minutes, see Settings).
  static const _pixelsPerMinute = 18.0;

  late DateTime _time = widget.end ? widget.entry.stop! : widget.entry.start;
  double _crown = 0;
  StreamSubscription<double>? _rotary;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _rotary?.cancel();
    _rotary = WatchScope.read(context).bridge.rotary.listen(_onRotary);
  }

  void _onRotary(double delta) {
    _crown += delta;
    final steps = (_crown / _pixelsPerMinute).truncate();
    if (steps == 0) return;
    _crown -= steps * _pixelsPerMinute;
    _move(steps * WatchScope.read(context).crownStep);
  }

  void _move(int minutes) {
    final entry = widget.entry;
    final now = DateTime.now();
    var next = _time.add(Duration(minutes: minutes));
    final latest = !widget.end && entry.stop != null && entry.stop!.isBefore(now) ? entry.stop! : now;
    if (next.isAfter(latest)) next = latest;
    if (widget.end && next.isBefore(entry.start)) next = entry.start;
    if (next == _time) return;
    WatchScope.read(context).haptic(light: true);
    setState(() => _time = next);
  }

  @override
  void dispose() {
    _rotary?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    Widget step(String label, int minutes) => TextButton(
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        minimumSize: const Size(32, 32),
        padding: const EdgeInsets.symmetric(horizontal: 4),
      ),
      onPressed: () => _move(minutes),
      child: Text(label),
    );
    return Scaffold(
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) > 300) Navigator.of(context).maybePop();
        },
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(horizontal: size.width * 0.1, vertical: size.height * 0.1),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.end ? 'End time' : 'Start time',
                  style: theme.textTheme.labelMedium?.copyWith(color: Colors.white70),
                ),
                Text(
                  formatDay(context, DateTime(_time.year, _time.month, _time.day)),
                  style: theme.textTheme.bodySmall,
                ),
                Text(
                  formatTime(context, _time),
                  style: theme.textTheme.displaySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                ),
                Ticking(
                  builder: (context) => Text(switch ((widget.end, widget.entry.stop)) {
                    (true, _) => 'duration ${formatClock(_time.difference(widget.entry.start))}',
                    (false, final stop?) => 'duration ${formatClock(stop.difference(_time))}',
                    (false, null) => 'running ${formatClock(DateTime.now().difference(_time))}',
                  }, style: theme.textTheme.bodySmall?.copyWith(color: Colors.white60)),
                ),
                const SizedBox(height: 4),
                // Scales down on narrow screens instead of overflowing.
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [step('−15', -15), step('−5', -5), step('+5', 5), step('+15', 15)],
                  ),
                ),
                const SizedBox(height: 4),
                FilledButton.icon(
                  icon: const Icon(Icons.check),
                  label: const Text('Save'),
                  onPressed: () {
                    WatchScope.read(context).haptic();
                    final bridge = WatchScope.read(context).bridge;
                    if (widget.end) {
                      bridge.setStop(widget.entry.id, _time);
                    } else {
                      bridge.setStart(widget.entry.id, _time);
                    }
                    Navigator.of(context).pop();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Result of [ProjectPicker]; `id == null` means "no project".
class ProjectChoice {
  const ProjectChoice(this.id);

  final int? id;
}

class ProjectPicker extends StatelessWidget {
  const ProjectPicker({super.key, this.selected});

  final int? selected;

  @override
  Widget build(BuildContext context) {
    final projects = WatchScope.of(context).state.projects;
    Widget item(int? id, String name, Color color) => WearChip(
      label: name,
      color: color,
      trailing: id == selected ? const Icon(Icons.check, size: 18) : null,
      onTap: () => Navigator.of(context).pop(ProjectChoice(id)),
    );
    return RoundList(
      children: [
        const WearHeader('Project'),
        item(null, 'No project', Colors.white38),
        for (final p in projects) item(p.id, p.name, colorFromHex(p.color)),
      ],
    );
  }
}
