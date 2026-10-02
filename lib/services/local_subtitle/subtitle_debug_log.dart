import 'package:get/get.dart';

/// AI 字幕调试日志：环形缓冲，记录模型/音频探测/分段下载/转写/翻译全链路信息，
/// 供字幕面板「调试」入口查看，用于定位「一直识别中」等问题的根因。
class SubtitleDebugLog {
  SubtitleDebugLog._();

  /// 全局单例
  static final SubtitleDebugLog instance = SubtitleDebugLog._();

  static const int _maxEntries = 1000;

  final RxList<String> entries = <String>[].obs;

  void log(String message) {
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
