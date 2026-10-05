class Track {
  final String path;
  final String name;
  final int durationSec;
  final int index;

  Track({
    required this.path,
    required this.name,
    required this.durationSec,
    required this.index,
  });

  String get durationFormatted {
    final m = durationSec ~/ 60;
    final s = durationSec % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Track copyWith({int? index}) {
    return Track(
      path: path,
      name: name,
      durationSec: durationSec,
      index: index ?? this.index,
    );
  }
}

class CdCapacity {
  final int minutes;
  static const int bytesPerSec = 176400;

  const CdCapacity(this.minutes);

  int get totalBytes => minutes * 60 * bytesPerSec;
  int get totalMb => totalBytes ~/ 1024 ~/ 1024;

  static const List<int> supportedMinutes = [74, 80];
}
