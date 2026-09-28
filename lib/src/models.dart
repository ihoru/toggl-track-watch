import 'dart:convert';

/// Mirrors the Kotlin `ViewState` (android/app/src/main/kotlin/.../shared/Models.kt).

class Project {
  const Project({required this.id, required this.name, required this.color});

  final int id;
  final String name;
  final String color;

  factory Project.fromJson(Map<String, dynamic> json) => Project(
    id: (json['id'] as num).toInt(),
    name: json['name'] as String? ?? '',
    color: json['color'] as String? ?? '#9e9e9e',
  );
}

class Favorite {
  const Favorite({required this.description, this.projectId});

  final String description;
  final int? projectId;

  factory Favorite.fromJson(Map<String, dynamic> json) =>
      Favorite(description: json['description'] as String? ?? '', projectId: (json['projectId'] as num?)?.toInt());

  Map<String, dynamic> toJson() => {'description': description, 'projectId': projectId};

  @override
  bool operator ==(Object other) =>
      other is Favorite && other.description == description && other.projectId == projectId;

  @override
  int get hashCode => Object.hash(description, projectId);
}

/// A (description, project) pair and how often it was tracked in the last 30 days.
class Frequent {
  const Frequent({required this.description, this.projectId, required this.count});

  final String description;
  final int? projectId;
  final int count;

  Favorite get asFavorite => Favorite(description: description, projectId: projectId);

  factory Frequent.fromJson(Map<String, dynamic> json) => Frequent(
    description: json['description'] as String? ?? '',
    projectId: (json['projectId'] as num?)?.toInt(),
    count: (json['count'] as num?)?.toInt() ?? 0,
  );
}

class TimeEntry {
  const TimeEntry({
    required this.id,
    required this.description,
    required this.projectId,
    required this.start,
    required this.stop,
    this.pending = false,
  });

  final String id;
  final String description;
  final int? projectId;
  final DateTime start;
  final DateTime? stop;
  final bool pending;

  bool get isRunning => stop == null;

  Duration duration([DateTime? now]) => (stop ?? now ?? DateTime.now()).difference(start);

  Favorite get asFavorite => Favorite(description: description, projectId: projectId);

  factory TimeEntry.fromJson(Map<String, dynamic> json) => TimeEntry(
    id: json['id'] as String,
    description: json['description'] as String? ?? '',
    projectId: (json['projectId'] as num?)?.toInt(),
    start: DateTime.fromMillisecondsSinceEpoch((json['start'] as num).toInt()),
    stop: json['stop'] == null ? null : DateTime.fromMillisecondsSinceEpoch((json['stop'] as num).toInt()),
    pending: json['pending'] as bool? ?? false,
  );
}

class DayGroup {
  const DayGroup(this.day, this.entries);

  final DateTime day;
  final List<TimeEntry> entries;

  Duration total([DateTime? now]) => entries.fold(Duration.zero, (sum, e) => sum + e.duration(now));
}

class ViewState {
  const ViewState({
    this.configured = false,
    this.entries = const [],
    this.projects = const [],
    this.favorites = const [],
    this.frequent = const [],
    this.pendingCount = 0,
    this.lastSync,
    this.error,
    this.rateLimitedUntil,
    this.quotaRemaining,
    this.quotaResetsAt,
    this.phoneReachable = true,
  });

  final bool configured;

  /// Newest first.
  final List<TimeEntry> entries;
  final List<Project> projects;
  final List<Favorite> favorites;

  /// Most-tracked timers of the last 30 days, most frequent first.
  final List<Frequent> frequent;
  final int pendingCount;
  final DateTime? lastSync;
  final String? error;
  final DateTime? rateLimitedUntil;

  /// Toggl API requests left in the current quota window, as last reported by Toggl.
  final int? quotaRemaining;
  final DateTime? quotaResetsAt;
  final bool phoneReachable;

  static const empty = ViewState();

  /// Requests left in the current quota window, or null when unknown or the window has already reset.
  int? quotaLeft([DateTime? now]) {
    final resetsAt = quotaResetsAt;
    if (quotaRemaining == null || resetsAt == null || !resetsAt.isAfter(now ?? DateTime.now())) return null;
    return quotaRemaining;
  }

  ViewState copyWith({List<Favorite>? favorites}) => ViewState(
    configured: configured,
    entries: entries,
    projects: projects,
    favorites: favorites ?? this.favorites,
    frequent: frequent,
    pendingCount: pendingCount,
    lastSync: lastSync,
    error: error,
    rateLimitedUntil: rateLimitedUntil,
    quotaRemaining: quotaRemaining,
    quotaResetsAt: quotaResetsAt,
    phoneReachable: phoneReachable,
  );

  TimeEntry? get running {
    for (final e in entries) {
      if (e.isRunning) return e;
    }
    return null;
  }

  Project? project(int? id) {
    if (id == null) return null;
    for (final p in projects) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Distinct (description, project) pairs, most recent first.
  List<Favorite> recents({int limit = 10}) {
    final seen = <Favorite>{};
    for (final e in entries) {
      if (e.description.isEmpty && e.projectId == null) continue;
      seen.add(e.asFavorite);
      if (seen.length >= limit) break;
    }
    return seen.toList();
  }

  /// Entries grouped by local day, newest day first.
  List<DayGroup> days() {
    final groups = <DateTime, List<TimeEntry>>{};
    for (final e in entries) {
      final day = DateTime(e.start.year, e.start.month, e.start.day);
      groups.putIfAbsent(day, () => []).add(e);
    }
    final keys = groups.keys.toList()..sort((a, b) => b.compareTo(a));
    return [for (final k in keys) DayGroup(k, groups[k]!)];
  }

  TimeEntry? entry(String id) {
    for (final e in entries) {
      if (e.id == id) return e;
    }
    return null;
  }

  factory ViewState.fromJson(Map<String, dynamic> json) {
    List<Map<String, dynamic>> list(String key) => ((json[key] as List?) ?? const []).cast<Map<String, dynamic>>();
    DateTime? time(String key) =>
        json[key] == null ? null : DateTime.fromMillisecondsSinceEpoch((json[key] as num).toInt());
    return ViewState(
      configured: json['configured'] as bool? ?? false,
      entries: list('entries').map(TimeEntry.fromJson).toList(),
      projects: list('projects').map(Project.fromJson).toList(),
      favorites: list('favorites').map(Favorite.fromJson).toList(),
      frequent: list('frequent').map(Frequent.fromJson).toList(),
      pendingCount: (json['pendingCount'] as num?)?.toInt() ?? 0,
      lastSync: time('lastSync'),
      error: json['error'] as String?,
      rateLimitedUntil: time('rateLimitedUntil'),
      quotaRemaining: (json['quotaRemaining'] as num?)?.toInt(),
      quotaResetsAt: time('quotaResetsAt'),
      phoneReachable: json['phoneReachable'] as bool? ?? true,
    );
  }

  factory ViewState.decode(String source) => ViewState.fromJson(jsonDecode(source) as Map<String, dynamic>);
}
