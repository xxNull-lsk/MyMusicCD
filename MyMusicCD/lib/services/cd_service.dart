import 'dart:io';
import 'package:path/path.dart' as p;
import '../models/track.dart';
import '../models/project.dart';

class ScanResult {
  final List<Track> tracks;
  final int totalDurationSec;
  final bool fits;
  final int remainingMb;
  final int overMb;

  ScanResult({
    required this.tracks,
    required this.totalDurationSec,
    required this.fits,
    required this.remainingMb,
    required this.overMb,
  });
}

class ConversionResult {
  final List<String> wavPaths;
  final String cuePath;
  final List<String> failed;

  ConversionResult({
    required this.wavPaths,
    required this.cuePath,
    required this.failed,
  });
}

/// 光驱/刻录机设备。
class BurnDevice {
  final String path;
  final String description;

  BurnDevice({required this.path, required this.description});
}

class CdService {
  static const Set<String> audioExtensions = {
    'mp3', 'flac', 'ogg', 'oga', 'm4a', 'aac', 'wma', 'opus', 'ape', 'wv', 'aiff', 'aif', 'wav'
  };

  Future<List<File>> scanDirectory(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) {
      throw Exception('目录不存在: $dirPath');
    }

    final files = <File>[];
    await for (final entity in dir.list()) {
      if (entity is File) {
        final ext = p.extension(entity.path).toLowerCase().replaceFirst('.', '');
        if (audioExtensions.contains(ext)) {
          files.add(entity);
        }
      }
    }
    return files;
  }

  Future<int> getDuration(String filePath) async {
    try {
      final result = await Process.run('ffprobe', [
        '-v', 'error',
        '-show_entries', 'format=duration',
        '-of', 'default=noprint_wrappers=1:nokey=1',
        filePath,
      ]);
      if (result.exitCode == 0) {
        final dur = double.tryParse((result.stdout as String).trim());
        if (dur != null) return dur.floor();
      }
    } catch (_) {}
    return 0;
  }

  Future<bool> isCdDaWav(String filePath) async {
    try {
      final results = await Future.wait([
        Process.run('ffprobe', [
          '-v', 'error', '-select_streams', 'a:0',
          '-show_entries', 'stream=sample_rate',
          '-of', 'csv=p=0', filePath,
        ]),
        Process.run('ffprobe', [
          '-v', 'error', '-select_streams', 'a:0',
          '-show_entries', 'stream=bits_per_sample',
          '-of', 'csv=p=0', filePath,
        ]),
        Process.run('ffprobe', [
          '-v', 'error', '-select_streams', 'a:0',
          '-show_entries', 'stream=channels',
          '-of', 'csv=p=0', filePath,
        ]),
      ]);
      if (results.every((r) => r.exitCode == 0)) {
        final sr = (results[0].stdout as String).trim();
        final br = (results[1].stdout as String).trim();
        final ch = (results[2].stdout as String).trim();
        return sr == '44100' && br == '16' && ch == '2';
      }
    } catch (_) {}
    return false;
  }

  Future<ScanResult> evaluate(List<Track> tracks, CdCapacity capacity) async {
    int totalSec = 0;
    for (final t in tracks) {
      totalSec += t.durationSec;
    }
    final totalBytes = totalSec * CdCapacity.bytesPerSec;
    final capBytes = capacity.totalBytes;
    final fits = totalBytes <= capBytes;
    final remainingMb = fits ? (capBytes - totalBytes) ~/ 1024 ~/ 1024 : 0;
    final overMb = fits ? 0 : (totalBytes - capBytes) ~/ 1024 ~/ 1024;

    return ScanResult(
      tracks: tracks,
      totalDurationSec: totalSec,
      fits: fits,
      remainingMb: remainingMb,
      overMb: overMb,
    );
  }

  Future<ConversionResult> convert(
    List<Track> tracks,
    String outDir, {
    void Function(int current, int total, String name)? onProgress,
  }) async {
    final dir = Directory(outDir);
    await dir.create(recursive: true);

    final wavPaths = <String>[];
    final failed = <String>[];
    final total = tracks.length;

    for (int i = 0; i < tracks.length; i++) {
      final t = tracks[i];
      onProgress?.call(i + 1, total, t.name);

      final base = p.basename(t.path);
      final name = p.withoutExtension(base);
      final out = p.join(outDir, '${t.index.toString().padLeft(2, '0')} - $name.wav');

      final isWav = p.extension(t.path).toLowerCase() == '.wav';
      if (isWav && await isCdDaWav(t.path)) {
        await File(t.path).copy(out);
        wavPaths.add(out);
        continue;
      }

      try {
        final result = await Process.run('ffmpeg', [
          '-hide_banner', '-loglevel', 'error', '-y',
          '-i', t.path,
          '-vn', '-acodec', 'pcm_s16le', '-ar', '44100', '-ac', '2',
          out,
        ]);
        if (result.exitCode == 0 && await File(out).exists()) {
          wavPaths.add(out);
        } else {
          failed.add(t.name);
          try { await File(out).delete(); } catch (_) {}
        }
      } catch (e) {
        failed.add(t.name);
      }
    }

    final cuePath = p.join(outDir, 'cd.cue');
    final cueContent = StringBuffer()
      ..writeln('REM GENRE Mixed')
      ..writeln('REM DATE ${DateTime.now().year}')
      ..writeln('PERFORMER "Various"')
      ..writeln('TITLE "Music CD"');

    for (int i = 0; i < wavPaths.length; i++) {
      cueContent
        ..writeln('FILE "${p.basename(wavPaths[i])}" WAVE')
        ..writeln('  TRACK ${(i + 1).toString().padLeft(2, '0')} AUDIO')
        ..writeln('    INDEX 01 00:00:00');
    }

    await File(cuePath).writeAsString(cueContent.toString());

    return ConversionResult(wavPaths: wavPaths, cuePath: cuePath, failed: failed);
  }

  /// 扫描系统中的光驱设备（Linux 的 /dev/sr* 节点），附带型号信息。
  Future<List<BurnDevice>> listBurnDevices() async {
    final names = <String>[];
    final devDir = Directory('/dev');
    if (await devDir.exists()) {
      await for (final entity in devDir.list()) {
        final name = p.basename(entity.path);
        if (RegExp(r'^sr\d+$').hasMatch(name)) {
          names.add(name);
        }
      }
    }
    names.sort((a, b) {
      final na = int.tryParse(a.substring(2)) ?? 0;
      final nb = int.tryParse(b.substring(2)) ?? 0;
      return na.compareTo(nb);
    });

    return Future.wait(names.map((name) async {
      final model = await _readDriveModel(name);
      return BurnDevice(path: '/dev/$name', description: model);
    }));
  }

  /// 从 sysfs 读取光驱型号，读不到时回退为设备路径。
  Future<String> _readDriveModel(String devName) async {
    try {
      final model = await File('/sys/class/block/$devName/device/model')
          .readAsString();
      final trimmed = model.trim();
      if (trimmed.isNotEmpty) return '$trimmed (/dev/$devName)';
    } catch (_) {}
    return '/dev/$devName';
  }

  Future<Process> burn({
    required String device,
    required List<String> wavPaths,
    bool blank = false,
  }) async {
    if (blank) {
      await Process.run('cdrecord', ['-v', 'dev=$device', 'blank=fast']);
    }

    final args = ['-audio', '-dao', '-v', '-pad', 'dev=$device', ...wavPaths];
    return Process.start('cdrecord', args);
  }

  Future<void> blankCdRw(String device) async {
    await Process.run('cdrecord', ['-v', 'dev=$device', 'blank=fast']);
  }

  /// 查找可用的 ISO 制作工具：genisoimage / mkisofs / xorriso。
  Future<String?> _findIsoTool() async {
    for (final tool in ['genisoimage', 'mkisofs', 'xorriso']) {
      try {
        final r = await Process.run(tool, ['--version']);
        if (r.exitCode == 0) return tool;
      } catch (_) {}
    }
    return null;
  }

  /// 把转换后的 WAV 音轨和 CUE 文件打包成标准 ISO 镜像文件。
  ///
  /// 返回已启动的进程，调用方通过 exitCode 判断结果。
  Future<Process> createIso({
    required List<String> wavPaths,
    required String cuePath,
    required String isoPath,
    String volumeLabel = '我的音乐CD',
  }) async {
    final tool = await _findIsoTool();
    if (tool == null) {
      throw Exception('未找到 genisoimage / mkisofs / xorriso，请先安装');
    }

    final label = volumeLabel.length > 32
        ? volumeLabel.substring(0, 32)
        : volumeLabel;
    final files = <String>[
      ...wavPaths.map(p.basename),
      p.basename(cuePath),
    ];

    final args = <String>[
      if (tool == 'xorriso') ...['-as', 'mkisofs'],
      '-o', isoPath,
      '-J', '-r',
      '-V', label,
      ...files,
    ];

    // 在音轨所在目录中运行，ISO 内只保留文件名（不含绝对路径）
    return Process.start(tool, args, workingDirectory: p.dirname(wavPaths.first));
  }

  Future<CdProject> loadProject(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('项目文件不存在: $filePath');
    }
    final contents = await file.readAsString();
    return CdProject.fromJson(contents);
  }

  Future<void> saveProject(CdProject project, String filePath) async {
    final file = File(filePath);
    await file.create(recursive: true);
    await file.writeAsString(project.toJson());
  }

  CdProject addTrackToProject(CdProject project, Track track, {int? index}) {
    final pt = ProjectTrack(
      path: track.path,
      name: track.name,
      durationSec: track.durationSec,
      index: index ?? project.tracks.length + 1,
    );
    final updatedTracks = List<ProjectTrack>.from(project.tracks)..add(pt);
    return project.copyWith(tracks: updatedTracks);
  }

  CdProject removeTrackFromProject(CdProject project, int index) {
    final updatedTracks = project.tracks.where((t) => t.index != index).toList();
    // Re-index remaining tracks
    for (int i = 0; i < updatedTracks.length; i++) {
      updatedTracks[i] = updatedTracks[i].copyWith(index: i + 1);
    }
    return project.copyWith(tracks: updatedTracks);
  }

  CdProject reorderTracksInProject(CdProject project, int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return project;
    final tracks = List<ProjectTrack>.from(project.tracks);
    if (oldIndex >= 1 && oldIndex <= tracks.length && newIndex >= 1 && newIndex <= tracks.length) {
      final item = tracks.removeAt(oldIndex - 1);
      tracks.insert(newIndex - 1, item);
      // Re-index all tracks
      for (int i = 0; i < tracks.length; i++) {
        tracks[i] = tracks[i].copyWith(index: i + 1);
      }
    }
    return project.copyWith(tracks: tracks);
  }
}
