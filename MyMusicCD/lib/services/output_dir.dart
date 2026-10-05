import 'dart:io';
import 'package:path/path.dart' as p;

/// 自动输出目录。
///
/// 中间 WAV 与 cd.cue 固定写入 `~/.config/mkcd/tmp`，无需手动指定：
/// * 程序启动时创建并清空（清理上次异常退出留下的文件）；
/// * 程序退出时清空。
///
/// Linux 原生窗口层（`linux/runner/my_application.cc`）使用相同的路径，
/// 在窗口关闭时兜底清空，因此这里的方法需要保持路径计算方式一致。
class OutputDir {
  OutputDir._();

  /// `~/.config/mkcd/tmp` 的绝对路径。
  static String get path {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      // 极端情况下没有 HOME，退回到系统临时目录，保证仍然可用。
      return p.join(Directory.systemTemp.path, 'mkcd', 'tmp');
    }
    return p.join(home, '.config', 'mkcd', 'tmp');
  }

  /// 程序启动时调用：创建临时目录并清空历史残留文件。
  static Future<void> prepare() async {
    final dir = Directory(path);
    await dir.create(recursive: true);
    await clear();
  }

  /// 清空临时目录中的所有内容（保留目录本身）。
  static Future<void> clear() async {
    final dir = Directory(path);
    if (!await dir.exists()) return;
    await for (final entity in dir.list(followLinks: false)) {
      try {
        if (entity is Directory) {
          await entity.delete(recursive: true);
        } else {
          await entity.delete();
        }
      } catch (_) {
        // 单个条目删除失败不影响启动与退出流程。
      }
    }
  }
}
