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
    // Keeps "last sync … ago" fresh.
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) => setState(() {}));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final snapshot = await _bridge.getState();
    final connected = await _bridge.watchConnected();
    if (!mounted) return;
    setState(() {
      _snapshot = snapshot;
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

  @override
  Widget build(BuildContext context) {
    final state = _snapshot.state;
    return Scaffold(
      appBar: AppBar(title: const Text('Track Watch')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : !state.configured
          ? TokenSetup(bridge: _bridge, onDone: (s) => setState(() => _snapshot = s))
          : ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                _AccountCard(account: _snapshot.account, onSignOut: _signOut),
                _StatusCard(state: state, watchConnected: _watchConnected, onSync: _bridge.syncNow),
                FavoritesSection(state: state, onChanged: _saveFavorites),
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

class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.account, required this.onSignOut});

  final Account? account;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: ListTile(
        leading: const Icon(Icons.account_circle),
        title: Text(account?.name.isNotEmpty == true ? account!.name : (account?.email ?? 'Toggl account')),
        subtitle: Text('Workspace: ${account?.workspace ?? '—'}'),
        trailing: TextButton(onPressed: onSignOut, child: const Text('Change token')),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.state, required this.watchConnected, required this.onSync});

  final ViewState state;
  final bool? watchConnected;
  final Future<void> Function() onSync;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rateLimited = state.rateLimitedUntil;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Sync', style: theme.textTheme.titleMedium),
                const Spacer(),
                FilledButton.tonalIcon(onPressed: onSync, icon: const Icon(Icons.sync), label: const Text('Sync now')),
              ],
            ),
            const SizedBox(height: 8),
            _line(Icons.watch, switch (watchConnected) {
              true => 'Watch connected',
              false => 'Watch not connected',
              null => 'Checking watch…',
            }),
            _line(
              Icons.cloud_upload_outlined,
              state.pendingCount == 0 ? 'Nothing waiting to sync' : '${state.pendingCount} change(s) waiting to sync',
            ),
            _line(Icons.history, state.lastSync == null ? 'Never synced' : 'Last sync ${relativeAgo(state.lastSync!)}'),
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
  const FavoritesSection({super.key, required this.state, required this.onChanged});

  final ViewState state;
  final ValueChanged<List<Favorite>> onChanged;

  @override
  Widget build(BuildContext context) {
    final favorites = state.favorites;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
          child: Row(
            children: [
              Text('Favorites', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _addFromRecent(context),
                icon: const Icon(Icons.history),
                label: const Text('From recent'),
              ),
              IconButton(tooltip: 'Add favorite', onPressed: () => _edit(context, null), icon: const Icon(Icons.add)),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text('Shown on the watch and the tile in this order. Drag to reorder, swipe to delete.'),
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
            return Dismissible(
              key: ValueKey('fav-$index-${favorite.description}-${favorite.projectId}'),
              direction: DismissDirection.endToStart,
              background: Container(
                color: Theme.of(context).colorScheme.errorContainer,
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 24),
                child: const Icon(Icons.delete),
              ),
              onDismissed: (_) => onChanged([...favorites]..removeAt(index)),
              child: ListTile(
                leading: Icon(Icons.circle, color: colorFromHex(project?.color), size: 14),
                title: Text(favorite.description.isEmpty ? '(no description)' : favorite.description),
                subtitle: Text(project?.name ?? 'No project'),
                onTap: () => _edit(context, index),
              ),
            );
          },
        ),
      ],
    );
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
