import 'dart:convert';

class ProjectTrack {
  final String path;
  final String name;
  final int durationSec;
  int index;

  ProjectTrack({
    required this.path,
    required this.name,
    required this.durationSec,
    this.index = 0,
  });

  Map<String, dynamic> toMap() {
    return {
      'path': path,
      'name': name,
      'durationSec': durationSec,
      'index': index,
    };
  }

  factory ProjectTrack.fromMap(Map<String, dynamic> map) {
    return ProjectTrack(
      path: map['path'] as String,
      name: map['name'] as String,
      durationSec: map['durationSec'] as int,
      index: map['index'] as int? ?? 0,
    );
  }

  @override
  String toString() => 'ProjectTrack(path: $path, name: $name, dur: $durationSec, idx: $index)';

  ProjectTrack copyWith({int? index}) {
    return ProjectTrack(
      path: path,
      name: name,
      durationSec: durationSec,
      index: index ?? this.index,
    );
  }
}

class CdProject {
  final String name;
  final DateTime created;
  final List<ProjectTrack> tracks;

  CdProject({
    required this.name,
    DateTime? created,
    List<ProjectTrack>? tracks,
  })  : created = created ?? DateTime.now(),
        tracks = tracks ?? [];

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'created': created.toIso8601String(),
      'tracks': tracks.map((t) => t.toMap()).toList(),
    };
  }

  factory CdProject.fromMap(Map<String, dynamic> map) {
    final tracks = (map['tracks'] as List?)
        ?.map((t) => ProjectTrack.fromMap(t as Map<String, dynamic>))
        .toList() ?? [];
    return CdProject(
      name: map['name'] as String,
      created: DateTime.parse(map['created'] as String),
      tracks: tracks,
    );
  }

  String toJson() => jsonEncode(toMap());

  factory CdProject.fromJson(String source) {
    final map = jsonDecode(source) as Map<String, dynamic>;
    return CdProject.fromMap(map);
  }

  CdProject copyWith({String? name, DateTime? created, List<ProjectTrack>? tracks}) {
    return CdProject(
      name: name ?? this.name,
      created: created ?? this.created,
      tracks: tracks ?? this.tracks,
    );
  }
}