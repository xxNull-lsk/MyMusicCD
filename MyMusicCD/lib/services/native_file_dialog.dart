import 'dart:io';

import 'package:file_picker/file_picker.dart';

/// Linux 原生文件对话框。
///
/// `file_picker` 包在 Linux 上通过 zenity/qarma 弹窗，但
/// `FileType.custom` 的过滤器名称被固定显示为 "Custom Files"，
/// 无法自定义。这里直接调用 zenity/qarma/kdialog（与
/// `file_picker` 相同的实现路径），让过滤器显示为中文名称，
/// 例如「我的音乐CD项目文件」。
///
/// 非 Linux 平台或找不到对话框工具时，回退到 `file_picker`。
class NativeFileDialog {
  NativeFileDialog._();

  /// 可用的对话框工具，优先级与 file_picker 一致：
  /// qarma → kdialog → zenity；找不到时返回 null。
  static Future<String?> _findExecutable() async {
    for (final name in ['qarma', 'kdialog', 'zenity']) {
      try {
        final r = await Process.run('which', [name]);
        if (r.exitCode == 0 && (r.stdout ?? '').toString().trim().isNotEmpty) {
          return name;
        }
      } catch (_) {}
    }
    return null;
  }

  /// 把 glob 模式转为不区分大小写的形式：`*.mp3` → `*.[mM][pP]3`。
  static String _toCaseInsensitive(String pattern) {
    return pattern.split('').map((e) {
      final c = e.codeUnitAt(0);
      final isAlpha =
          (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
      return isAlpha ? '[${e.toLowerCase()}${e.toUpperCase()}]' : e;
    }).join();
  }

  /// zenity/qarma 的过滤器格式：`名称 | 模式1 模式2 …`
  static String _buildFilter(String filterName, List<String> extensions) {
    final patterns =
        extensions.map((e) => _toCaseInsensitive('*.$e')).join(' ');
    return '$filterName | $patterns';
  }

  /// 当前环境能否使用原生对话框。
  static Future<String?> _nativeExecutable() async {
    if (!Platform.isLinux) return null;
    return _findExecutable();
  }

  /// 打开文件选择对话框，返回选中的路径（用户取消时返回空列表）。
  static Future<List<String>> pickFiles({
    required String title,
    required String filterName,
    required List<String> extensions,
    bool multiple = false,
  }) async {
    final executable = await _nativeExecutable();
    if (executable == null) {
      // 非 Linux 平台或没有可用的对话框工具，回退到 file_picker
      final result = await FilePicker.platform.pickFiles(
        dialogTitle: title,
        type: FileType.custom,
        allowedExtensions: extensions,
        allowMultiple: multiple,
      );
      if (result == null) return [];
      return result.files
          .where((f) => f.path != null)
          .map((f) => f.path!)
          .toList();
    }

    final args = <String>[
      '--file-selection',
      '--title', title,
      '--file-filter', _buildFilter(filterName, extensions),
    ];
    if (multiple) {
      args.add('--multiple');
    }

    final result = await Process.run(executable, args);
    if (result.exitCode != 0) {
      // 用户取消或对话框未能显示
      return [];
    }
    final out = result.stdout?.toString() ?? '';
    return out
        .split('|')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .map((s) => s.startsWith('/') ? s : '/$s')
        .toList();
  }

  /// 打开目录选择对话框，返回选中的目录路径（用户取消时返回 null）。
  static Future<String?> getDirectoryPath({
    required String title,
  }) async {
    final executable = await _nativeExecutable();
    if (executable == null) {
      return FilePicker.platform.getDirectoryPath(dialogTitle: title);
    }

    final result = await Process.run(executable, [
      '--file-selection',
      '--title', title,
      '--directory',
    ]);
    if (result.exitCode != 0) {
      return null;
    }
    final path = result.stdout?.toString().trim() ?? '';
    if (path.isEmpty) return null;
    return path.startsWith('/') ? path : '/$path';
  }

  /// 打开保存文件对话框，返回目标路径（用户取消时返回 null）。
  static Future<String?> saveFile({
    required String title,
    required String fileName,
    required String filterName,
    required List<String> extensions,
  }) async {
    final executable = await _nativeExecutable();
    if (executable == null) {
      return FilePicker.platform.saveFile(
        dialogTitle: title,
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: extensions,
      );
    }

    final args = <String>[
      '--file-selection',
      '--save',
      '--confirm-overwrite',
      '--title', title,
      '--filename', fileName,
      '--file-filter', _buildFilter(filterName, extensions),
    ];

    final result = await Process.run(executable, args);
    if (result.exitCode != 0) {
      return null;
    }
    final path = result.stdout?.toString().trim() ?? '';
    if (path.isEmpty) return null;
    return path.startsWith('/') ? path : '/$path';
  }
}
