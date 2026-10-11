import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:get/get.dart';

/// AI 字幕调试日志：环形缓冲，记录模型/音频探测/分段下载/转写/翻译全链路信息，
/// 供「AI 字幕设置 → 调试日志」入口查看，用于定位「一直识别中」等问题的根因。
///
/// 默认开启记录；可在 AI 字幕设置中关闭（[enabled]），关闭后 [log] 直接跳过。
class SubtitleDebugLog {
  SubtitleDebugLog._();

  /// 全局单例
  static final SubtitleDebugLog instance = SubtitleDebugLog._();

  static const int _maxEntries = 1000;

  final RxList<String> entries = <String>[].obs;

  /// 是否记录日志（设置面板可关）。默认打开。
  bool get enabled =>
      GStorage.setting.get(SettingBoxKey.subtitleDebugLog, defaultValue: true);

  void log(String message) {
    if (!enabled) {
      return;
    }
    final line = '[${_ts()}] $message';
    if (entries.length >= _maxEntries) {
      entries.removeAt(0);
    }
    entries.add(line);
  }

  void clear() => entries.clear();

  String get dump => entries.join('\n');

  static String _ts() {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.'
        '${(t.millisecond ~/ 10).toString().padLeft(2, '0')}';
  }
}
