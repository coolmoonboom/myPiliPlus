import 'package:PiliPlus/models/common/enum_with_label.dart';
import 'package:collection/collection.dart' show IterableExtension;

enum SubtitleFormat implements EnumWithLabel {
  json('JSON'),
  vtt('WEBVTT'),
  srt('SRT');

  @override
  final String label;
  const SubtitleFormat(this.label);
}

abstract final class SubtitleUtils {
  /// 将「时:分:秒.毫秒 / 分:秒.毫秒」时间码转换为秒，解析失败返回 null。
  static double? parseTimecode(String raw) {
    final text = raw.trim().replaceAll(',', '.');
    if (text.isEmpty) {
      return null;
    }
    final parts = text.split(':');
    double? value;
    if (parts.length >= 3) {
      value =
          (int.tryParse(parts[0]) ?? 0) * 3600 +
          (int.tryParse(parts[1]) ?? 0) * 60 +
          (double.tryParse(parts[2]) ?? 0);
    } else if (parts.length == 2) {
      value =
          (int.tryParse(parts[0]) ?? 0) * 60 +
          (double.tryParse(parts[1]) ?? 0);
    } else if (parts.length == 1) {
      value = double.tryParse(parts[0]);
    }
    return value;
  }

  /// 解析 SRT / WebVTT 文本为 `{from, to, content}` 列表（单位为秒）。
  ///
  /// 自动跳过 WEBVTT 头、NOTE/STYLE 块与没有时间行的内容，并清理
  /// HTML/VTT/ASS 内联标签，便于逐句展示。
  static List<Map<String, dynamic>> parseCues(String content) {
    final normalized = content
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    final cues = <Map<String, dynamic>>[];
    for (final block in normalized.split(RegExp(r'\n{2,}'))) {
      final lines = block.split('\n');
      var timingIndex = -1;
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains('-->')) {
          timingIndex = i;
          break;
        }
      }
      if (timingIndex < 0) {
        continue;
      }
      final timing = lines[timingIndex];
      final arrow = timing.indexOf('-->');
      final from = parseTimecode(timing.substring(0, arrow));
      var endPart = timing.substring(arrow + 3).trim();
      // WebVTT 行尾可能带 cue 设置（如 align:start），只取时间部分。
      final spaceIndex = endPart.indexOf(RegExp(r'\s'));
      if (spaceIndex >= 0) {
        endPart = endPart.substring(0, spaceIndex);
      }
      final to = parseTimecode(endPart);
      if (from == null || to == null) {
        continue;
      }
      var text = lines.sublist(timingIndex + 1).join('\n').trim();
      if (text.isEmpty) {
        continue;
      }
      text = text
          .replaceAll(RegExp(r'<[^>]*>'), '')
          .replaceAll(RegExp(r'\{\\[^}]*\}'), '')
          .trim();
      if (text.isEmpty) {
        continue;
      }
      cues.add({'from': from, 'to': to, 'content': text});
    }
    return cues;
  }

  static String _vttTimecode(num seconds) {
    final h = (seconds ~/ 3600).toString().padLeft(2, '0');
    seconds %= 3600;
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    seconds %= 60;
    final sms = seconds.toStringAsFixed(3).padLeft(6, '0');
    return "$h:$m:$sms";
  }

  static String json2Vtt(List list) {
    final sb = StringBuffer('WEBVTT\n\n')
      ..writeAll(
        list.map(
          (item) =>
              '${_vttTimecode(item['from'])} --> ${_vttTimecode(item['to'])}\n${item['content'].trim()}',
        ),
        '\n\n',
      );
    return sb.toString();
  }

  static String _srtTimecode(num seconds) {
    final h = (seconds ~/ 3600).toString().padLeft(2, '0');
    seconds %= 3600;
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    seconds %= 60;
    final s = seconds.toInt();
    final ms = ((seconds - s) * 1000).round().toString().padLeft(3, '0');
    return '$h:$m:${s.toString().padLeft(2, '0')},$ms';
  }

  static String json2Srt(List list) {
    final sb = StringBuffer()
      ..writeAll(
        list.mapIndexed(
          (i, e) =>
              '${i + 1}\n${_srtTimecode(e['from'])} --> ${_srtTimecode(e['to'])}\n${e['content'].trim()}',
        ),
        '\n\n',
      );
    return sb.toString();
  }
}
