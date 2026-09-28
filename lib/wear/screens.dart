import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../src/format.dart';
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

/// The five sections, swiped left/right: Now, Favorites, Frequent, History, Sync.
class HomePager extends StatefulWidget {
  const HomePager({super.key});

  static const pageCount = 5;

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
    if (!model.state.configured) {
      return const RoundList(
        swipeBack: false,
        children: [
          SizedBox(height: 24),
          Icon(Icons.phone_android, size: 32),
          SizedBox(height: 8),
          Text('Open Track Watch on your phone and add your Toggl API token.', textAlign: TextAlign.center),
        ],
      );
    }
    final bottom = MediaQuery.sizeOf(context).height * 0.05;
    return Stack(
      children: [
        PageView(
          controller: controller,
          onPageChanged: (page) {
            setState(() => _page = page);
            model.savePage(page);
          },
          children: [
            NowPage(active: _page == 0),
            FavoritesPage(active: _page == 1),
            FrequentPage(active: _page == 2),
            HistoryPage(active: _page == 3),
            SyncPage(active: _page == 4),
          ],
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
    final last = state.entries.where((e) => !e.isRunning).firstOrNull;
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
              HapticFeedback.heavyImpact();
              model.bridge.stop(running.id);
            },
            onCancel: () async {
              if (!await confirm(context, 'Discard this timer?')) return;
              HapticFeedback.heavyImpact();
              await model.bridge.delete(running.id);
            },
            onTap: () => _push(context, EntryScreen(entry: running)),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('No timer running', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleSmall),
          ),
          if (last != null)
            WearChip(
              label: last.description.isEmpty ? '(no description)' : last.description,
              secondary: 'Continue · ${state.project(last.projectId)?.name ?? 'No project'}',
              icon: Icons.play_arrow,
              color: colorFromHex(state.project(last.projectId)?.color),
              onTap: () => startTimer(context, last.description, last.projectId),
            ),
        ],
        WearChip(
          label: 'New timer',
          icon: Icons.add,
          color: Theme.of(context).colorScheme.primary,
          onTap: () => _push(context, const EditScreen.create()),
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

/// Details and actions for one entry: stop, continue, edit, delete.
class EntryScreen extends StatelessWidget {
  const EntryScreen({super.key, required this.entry});

  /// The entry as it was when opened; live data is looked up by id (or by start
  /// time once an offline-created entry receives its Toggl id).
  final TimeEntry entry;

  TimeEntry? _live(ViewState state) {
    final byId = state.entry(entry.id);
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
              HapticFeedback.heavyImpact();
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
              HapticFeedback.heavyImpact();
              model.bridge.update(widget.entry!.id, _description, _projectId);
              Navigator.of(context).pop();
            }
          },
        ),
      ],
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
