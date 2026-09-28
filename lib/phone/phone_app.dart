import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../src/format.dart';
import '../src/models.dart';
import '../src/theme.dart';
import 'phone_bridge.dart';

class PhoneApp extends StatelessWidget {
  const PhoneApp({super.key, required this.bridge});

  final PhoneBridge bridge;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Track Watch',
      theme: darkTheme(),
      debugShowCheckedModeBanner: false,
      home: SettingsPage(bridge: bridge),
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.bridge});

  final PhoneBridge bridge;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> with WidgetsBindingObserver {
  PhoneSnapshot _snapshot = PhoneSnapshot.empty;
  bool _loaded = false;
  bool _compact = false;
  bool? _watchConnected;
  StreamSubscription<PhoneSnapshot>? _sub;
  Timer? _ticker;

  PhoneBridge get _bridge => widget.bridge;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sub = _bridge.updates.listen((s) => setState(() => _snapshot = s));
    _load();
    // Keeps "synced … ago" fresh.
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) => setState(() {}));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final snapshot = await _bridge.getState();
    final compact = await _bridge.getCompact();
    final connected = await _bridge.watchConnected();
    if (!mounted) return;
    setState(() {
      _snapshot = snapshot;
      _compact = compact;
      _watchConnected = connected;
      _loaded = true;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _saveFavorites(List<Favorite> favorites) async {
    setState(() => _snapshot = PhoneSnapshot(_snapshot.state.copyWith(favorites: favorites), _snapshot.account));
    await _bridge.setFavorites(favorites);
  }

  void _setCompact(bool compact) {
    setState(() => _compact = compact);
    _bridge.setCompact(compact);
  }

  Future<void> _start(Favorite favorite) async {
    final messenger = ScaffoldMessenger.of(context);
    final label = favorite.description.isEmpty
        ? (_snapshot.state.project(favorite.projectId)?.name ?? '(no description)')
        : favorite.description;
    final result = await _bridge.startTimer(favorite);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            result == StartResult.togglApp ? 'Opening Toggl to start "$label"' : 'Started "$label" via Track Watch',
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final state = _snapshot.state;
    final configured = _loaded && state.configured;
    return Scaffold(
      appBar: AppBar(
        title: _HeaderTitle(account: configured ? _snapshot.account : null),
        actions: [
          if (configured) IconButton(tooltip: 'Change token', icon: const Icon(Icons.key), onPressed: _signOut),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : !state.configured
          ? TokenSetup(bridge: _bridge, onDone: (s) => setState(() => _snapshot = s))
          : ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                SyncRow(state: state, watchConnected: _watchConnected, onSync: _bridge.syncNow),
                FavoritesSection(
                  state: state,
                  compact: _compact,
                  onCompactChanged: _setCompact,
                  onChanged: _saveFavorites,
                  onStart: _start,
                ),
              ],
            ),
    );
  }

  Future<void> _signOut() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove token?'),
        content: const Text('Unsynced changes from the watch will be lost. Favorites are kept.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    await _bridge.signOut();
    await _load();
  }
}

/// "Track Watch" with the account name and workspace underneath.
class _HeaderTitle extends StatelessWidget {
  const _HeaderTitle({required this.account});

  final Account? account;

  @override
  Widget build(BuildContext context) {
    final account = this.account;
    if (account == null) return const Text('Track Watch');
    final theme = Theme.of(context);
    final who = account.name.isNotEmpty ? account.name : account.email;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Track Watch'),
        Text(
          [who, account.workspace].where((s) => s.isNotEmpty).join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class TokenSetup extends StatefulWidget {
  const TokenSetup({super.key, required this.bridge, required this.onDone});

  final PhoneBridge bridge;
  final ValueChanged<PhoneSnapshot> onDone;

  @override
  State<TokenSetup> createState() => _TokenSetupState();
}

class _TokenSetupState extends State<TokenSetup> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final token = _controller.text.trim();
    if (token.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      widget.onDone(await widget.bridge.setToken(token));
    } on PlatformException catch (e) {
      setState(() => _error = e.message ?? 'Could not verify the token');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Connect Toggl Track', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 12),
        const Text(
          'Paste your API token. You can find it at the bottom of your Toggl Track '
          'profile page (track.toggl.com/profile). It is stored encrypted on this phone '
          'and never sent to the watch.',
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _controller,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(labelText: 'API token', border: const OutlineInputBorder(), errorText: _error),
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }
}

/// One-line sync summary that expands to the details and a Sync now button.
class SyncRow extends StatefulWidget {
  const SyncRow({super.key, required this.state, required this.watchConnected, required this.onSync});

  final ViewState state;
  final bool? watchConnected;
  final Future<void> Function() onSync;

  @override
  State<SyncRow> createState() => _SyncRowState();
}

class _SyncRowState extends State<SyncRow> {
  late bool _expanded = widget.state.error != null;

  @override
  void didUpdateWidget(SyncRow old) {
    super.didUpdateWidget(old);
    if (old.state.error == null && widget.state.error != null) _expanded = true;
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final theme = Theme.of(context);
    final rateLimited = state.rateLimitedUntil;

    final (IconData icon, Color color, String? problem) = switch (state) {
      _ when state.error != null => (Icons.error_outline, theme.colorScheme.error, 'error'),
      _ when rateLimited != null => (
        Icons.hourglass_top,
        theme.colorScheme.tertiary,
        'API limit until ${formatTime(context, rateLimited)}',
      ),
      _ when state.pendingCount > 0 => (
        Icons.cloud_upload_outlined,
        theme.colorScheme.tertiary,
        '${state.pendingCount} queued',
      ),
      _ => (Icons.cloud_done_outlined, theme.colorScheme.primary, null),
    };
    final summary = [
      switch (widget.watchConnected) {
        true => 'Watch ✓',
        false => 'Watch ✗',
        null => 'Watch …',
      },
      ?problem,
      state.lastSync == null ? 'never synced' : 'synced ${relativeAgo(state.lastSync!)}',
      if (state.quotaLeft() case final left?) '$left API left',
    ].join(' · ');

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: color),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  IconButton(tooltip: 'Sync now', onPressed: widget.onSync, icon: const Icon(Icons.sync)),
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                  const SizedBox(width: 8),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Column(
                children: [
                  _line(Icons.watch, switch (widget.watchConnected) {
                    true => 'Watch connected',
                    false => 'Watch not connected',
                    null => 'Checking watch…',
                  }),
                  _line(
                    Icons.cloud_upload_outlined,
                    state.pendingCount == 0
                        ? 'Nothing waiting to sync'
                        : '${state.pendingCount} change(s) waiting to sync',
                  ),
                  _line(
                    Icons.history,
                    state.lastSync == null ? 'Never synced' : 'Last sync ${relativeAgo(state.lastSync!)}',
                  ),
                  if (quotaText(context, state) case final text?) _line(Icons.speed, text),
                  if (rateLimited != null)
                    _line(
                      Icons.hourglass_top,
                      'Toggl API limit reached, retrying at ${formatTime(context, rateLimited)}',
                      color: theme.colorScheme.tertiary,
                    ),
                  if (state.error != null) _line(Icons.error_outline, state.error!, color: theme.colorScheme.error),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _line(IconData icon, String text, {Color? color}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 12),
        Expanded(
          child: Text(text, style: TextStyle(color: color)),
        ),
      ],
    ),
  );
}

class FavoritesSection extends StatelessWidget {
  const FavoritesSection({
    super.key,
    required this.state,
    required this.onChanged,
    required this.onStart,
    this.compact = false,
    this.onCompactChanged,
  });

  final ViewState state;
  final ValueChanged<List<Favorite>> onChanged;
  final ValueChanged<Favorite> onStart;
  final bool compact;
  final ValueChanged<bool>? onCompactChanged;

  @override
  Widget build(BuildContext context) {
    final favorites = state.favorites;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
          child: Row(
            children: [
              Text('Favorites', style: theme.textTheme.titleMedium),
              const Spacer(),
              if (onCompactChanged != null)
                IconButton(
                  tooltip: compact ? 'Comfortable view' : 'Compact view',
                  onPressed: () => onCompactChanged!(!compact),
                  icon: Icon(compact ? Icons.view_agenda_outlined : Icons.view_list),
                ),
              IconButton(
                tooltip: 'Add from recent',
                onPressed: () => _addFromRecent(context),
                icon: const Icon(Icons.history),
              ),
              IconButton(tooltip: 'Add favorite', onPressed: () => _edit(context, null), icon: const Icon(Icons.add)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            'Swipe right to start, left to delete. Hold and drag to reorder.',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
        if (favorites.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('No favorites yet')),
          ),
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: favorites.length,
          onReorderItem: (from, to) {
            final list = [...favorites];
            list.insert(to, list.removeAt(from));
            onChanged(list);
          },
          itemBuilder: (context, index) {
            final favorite = favorites[index];
            final project = state.project(favorite.projectId);
            final description = favorite.description.isEmpty ? '(no description)' : favorite.description;
            final projectName = project?.name ?? 'No project';
            return Dismissible(
              key: ValueKey('fav-$index-${favorite.description}-${favorite.projectId}'),
              dismissThresholds: const {DismissDirection.startToEnd: 0.5, DismissDirection.endToStart: 0.5},
              background: _swipeBackground(
                color: Colors.green.shade700,
                icon: Icons.play_arrow,
                label: 'Start',
                alignment: Alignment.centerLeft,
              ),
              secondaryBackground: _swipeBackground(
                color: theme.colorScheme.errorContainer,
                icon: Icons.delete,
                label: 'Delete',
                alignment: Alignment.centerRight,
              ),
              confirmDismiss: (direction) async {
                if (direction == DismissDirection.startToEnd) {
                  onStart(favorite);
                  return false;
                }
                return _confirmDelete(context, description);
              },
              onDismissed: (_) => onChanged([...favorites]..removeAt(index)),
              child: compact
                  ? ListTile(
                      dense: true,
                      visualDensity: const VisualDensity(vertical: -4),
                      minLeadingWidth: 10,
                      leading: Icon(Icons.circle, color: colorFromHex(project?.color), size: 10),
                      title: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: description),
                            TextSpan(
                              text: '  ·  $projectName',
                              style: TextStyle(color: muted),
                            ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => _edit(context, index),
                    )
                  : ListTile(
                      leading: Icon(Icons.circle, color: colorFromHex(project?.color), size: 14),
                      title: Text(description),
                      subtitle: Text(projectName),
                      onTap: () => _edit(context, index),
                    ),
            );
          },
        ),
      ],
    );
  }

  Widget _swipeBackground({
    required Color color,
    required IconData icon,
    required String label,
    required Alignment alignment,
  }) => Container(
    color: color,
    alignment: alignment,
    padding: const EdgeInsets.symmetric(horizontal: 24),
    child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon), const SizedBox(width: 8), Text(label)]),
  );

  Future<bool> _confirmDelete(BuildContext context, String description) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete favorite?'),
        content: Text('"$description" will be removed from the phone and the watch.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _edit(BuildContext context, int? index) async {
    final result = await showDialog<Favorite>(
      context: context,
      builder: (context) =>
          FavoriteDialog(projects: state.projects, initial: index == null ? null : state.favorites[index]),
    );
    if (result == null) return;
    final list = [...state.favorites];
    if (index == null) {
      list.add(result);
    } else {
      list[index] = result;
    }
    onChanged(list);
  }

  Future<void> _addFromRecent(BuildContext context) async {
    final recents = state.recents(limit: 30).where((r) => !state.favorites.contains(r)).toList();
    final picked = await showModalBottomSheet<Favorite>(
      context: context,
      builder: (context) => recents.isEmpty
          ? const SizedBox(height: 120, child: Center(child: Text('No recent entries')))
          : ListView(
              children: [
                for (final r in recents)
                  ListTile(
                    leading: Icon(Icons.circle, color: colorFromHex(state.project(r.projectId)?.color), size: 14),
                    title: Text(r.description.isEmpty ? '(no description)' : r.description),
                    subtitle: Text(state.project(r.projectId)?.name ?? 'No project'),
                    onTap: () => Navigator.pop(context, r),
                  ),
              ],
            ),
    );
    if (picked != null) onChanged([...state.favorites, picked]);
  }
}

class FavoriteDialog extends StatefulWidget {
  const FavoriteDialog({super.key, required this.projects, this.initial});

  final List<Project> projects;
  final Favorite? initial;

  @override
  State<FavoriteDialog> createState() => _FavoriteDialogState();
}

class _FavoriteDialogState extends State<FavoriteDialog> {
  late final _description = TextEditingController(text: widget.initial?.description ?? '');
  late int? _projectId = widget.initial?.projectId;

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final known = widget.projects.any((p) => p.id == _projectId);
    return AlertDialog(
      title: Text(widget.initial == null ? 'New favorite' : 'Edit favorite'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _description,
            autofocus: widget.initial == null,
            decoration: const InputDecoration(labelText: 'Description'),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<int?>(
            initialValue: known ? _projectId : null,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Project'),
            items: [
              const DropdownMenuItem<int?>(value: null, child: Text('No project')),
              for (final p in widget.projects)
                DropdownMenuItem<int?>(
                  value: p.id,
                  child: Row(
                    children: [
                      Icon(Icons.circle, size: 12, color: colorFromHex(p.color)),
                      const SizedBox(width: 8),
                      Expanded(child: Text(p.name, overflow: TextOverflow.ellipsis)),
                    ],
                  ),
                ),
            ],
            onChanged: (v) => setState(() => _projectId = v),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, Favorite(description: _description.text.trim(), projectId: _projectId)),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
