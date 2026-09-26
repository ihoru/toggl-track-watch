import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../src/format.dart';
import '../src/models.dart';
import 'watch_bridge.dart';
import 'widgets.dart';

Future<T?> _push<T>(BuildContext context, Widget screen) =>
    Navigator.of(context).push<T>(MaterialPageRoute(builder: (_) => screen));

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final model = WatchScope.of(context);
    final state = model.state;
    final bridge = model.bridge;

    if (!model.loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!state.configured) {
      return const RoundList(
        children: [
          SizedBox(height: 24),
          Icon(Icons.phone_android, size: 32),
          SizedBox(height: 8),
          Text('Open Track Watch on your phone and add your Toggl API token.', textAlign: TextAlign.center),
        ],
      );
    }

    final running = state.running;
    final favorites = state.favorites;
    final recents = state.recents().where((r) => !favorites.contains(r)).take(6).toList();

    Future<void> start(Favorite f) async {
      HapticFeedback.heavyImpact();
      await bridge.start(f.description, f.projectId);
    }

    return RoundList(
      children: [
        StatusLine(state: state),
        if (running != null)
          RunningCard(
            entry: running,
            state: state,
            onStop: () {
              HapticFeedback.heavyImpact();
              bridge.stop(running.id);
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
        if (favorites.isNotEmpty) const WearHeader('Favorites'),
        for (final f in favorites) _FavoriteChip(favorite: f, state: state, icon: Icons.star, onTap: () => start(f)),
        if (recents.isNotEmpty) const WearHeader('Recent'),
        for (final f in recents) _FavoriteChip(favorite: f, state: state, onTap: () => start(f)),
        const WearHeader(''),
        WearChip(label: 'History', icon: Icons.history, onTap: () => _push(context, const HistoryScreen())),
        WearChip(
          label: 'Refresh',
          icon: Icons.refresh,
          secondary: state.lastSync == null ? null : 'Synced ${relativeAgo(state.lastSync!)}',
          onTap: bridge.refresh,
        ),
      ],
    );
  }
}

class _FavoriteChip extends StatelessWidget {
  const _FavoriteChip({required this.favorite, required this.state, required this.onTap, this.icon});

  final Favorite favorite;
  final ViewState state;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final project = state.project(favorite.projectId);
    return WearChip(
      label: favorite.description.isEmpty ? (project?.name ?? '(no description)') : favorite.description,
      secondary: project?.name ?? 'No project',
      color: colorFromHex(project?.color),
      icon: icon,
      onTap: onTap,
      trailing: const Icon(Icons.play_arrow, size: 18),
    );
  }
}

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = WatchScope.of(context).state;
    final days = state.days();
    return RoundList(
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
            onTap: () {
              HapticFeedback.heavyImpact();
              bridge.start(e.description, e.projectId);
              Navigator.of(context).popUntil((r) => r.isFirst);
            },
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
            HapticFeedback.heavyImpact();
            if (creating) {
              model.bridge.start(_description, _projectId);
              Navigator.of(context).popUntil((r) => r.isFirst);
            } else {
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
