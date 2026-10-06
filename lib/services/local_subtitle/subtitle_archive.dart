import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'local_subtitle_service.dart';

/// 字幕样式快照：记录影响字幕外观的设置，用于随存档保存/恢复。
///
/// 恢复时仅覆盖当前播放会话的字段，不写入全局 Pref，避免影响其它视频。
class SubtitleStyleSnapshot {
  const SubtitleStyleSnapshot({
    required this.fontScale,
    required this.fontScaleFS,
    required this.paddingH,
    required this.paddingB,
    required this.bgOpacity,
    required this.strokeWidth,
    required this.fontWeight,
  });

  /// 竖屏/非全屏字体缩放
  final double fontScale;

  /// 横屏/全屏字体缩放
  final double fontScaleFS;

  /// 左右边距
  final int paddingH;

  /// 底部边距
  final int paddingB;

  /// 背景不透明度
  final double bgOpacity;

  /// 描边粗细
  final double strokeWidth;

  /// 字体粗细
  final int fontWeight;

  Map<String, dynamic> toJson() => {
    'fontScale': fontScale,
    'fontScaleFS': fontScaleFS,
    'paddingH': paddingH,
    'paddingB': paddingB,
    'bgOpacity': bgOpacity,
    'strokeWidth': strokeWidth,
    'fontWeight': fontWeight,
  };

  factory SubtitleStyleSnapshot.fromJson(Map<dynamic, dynamic> json) {
    double asDouble(dynamic v, double fallback) =>
        v is num ? v.toDouble() : fallback;
    int asInt(dynamic v, int fallback) => v is num ? v.toInt() : fallback;
    return SubtitleStyleSnapshot(
      fontScale: asDouble(json['fontScale'], 1.0),
      fontScaleFS: asDouble(json['fontScaleFS'], 1.0),
      paddingH: asInt(json['paddingH'], 24),
      paddingB: asInt(json['paddingB'], 24),
      bgOpacity: asDouble(json['bgOpacity'], 0.67),
      strokeWidth: asDouble(json['strokeWidth'], 2.0),
      fontWeight: asInt(json['fontWeight'], 5),
    );
  }
}

/// 单个视频的字幕存档：字幕内容 + 时间偏移 + 字幕样式 + 播放进度。
class SubtitleArchive {
  const SubtitleArchive({
    required this.bvid,
    required this.cid,
    required this.title,
    required this.activeSource,
    required this.offsetEnabled,
    required this.offsetSeconds,
    required this.progressMs,
    required this.style,
    required this.imported,
    required this.recognized,
  });

  static const int version = 1;

  /// 导入的字幕来源标识
  static const String sourceImported = 'imported';

  /// 模型识别出的字幕来源标识
  static const String sourceRecognized = 'recognized';

  final String bvid;
  final int cid;
  final String title;

  /// 打开时优先展示/生效的来源（[sourceImported] 或 [sourceRecognized]）。
  final String activeSource;

  /// 是否启用时间偏移。
  final bool offsetEnabled;

  /// 时间偏移（秒，带符号）。
  final double offsetSeconds;

  /// 播放进度（毫秒），0 表示未记录。
  final int progressMs;

  final SubtitleStyleSnapshot style;

  /// 导入的字幕。
  final List<LocalSubtitleSegment> imported;

  /// 模型识别出的字幕。
  final List<LocalSubtitleSegment> recognized;

  bool get isEmpty => imported.isEmpty && recognized.isEmpty;

  Map<String, dynamic> toJson() => {
    'version': version,
    'bvid': bvid,
    'cid': cid,
    'title': title,
    'activeSource': activeSource,
    'offsetEnabled': offsetEnabled,
    'offsetSeconds': offsetSeconds,
    'progressMs': progressMs,
    'style': style.toJson(),
    'imported': imported.map(_segmentToJson).toList(),
    'recognized': recognized.map(_segmentToJson).toList(),
  };

  factory SubtitleArchive.fromJson(Map<dynamic, dynamic> json) {
    return SubtitleArchive(
      bvid: json['bvid'] as String? ?? '',
      cid: json['cid'] is num ? (json['cid'] as num).toInt() : 0,
      title: json['title'] as String? ?? '',
      activeSource:
          json['activeSource'] as String? ?? SubtitleArchive.sourceImported,
      offsetEnabled: json['offsetEnabled'] as bool? ?? false,
      offsetSeconds: json['offsetSeconds'] is num
          ? (json['offsetSeconds'] as num).toDouble()
          : 0.0,
      progressMs: json['progressMs'] is num
          ? (json['progressMs'] as num).toInt()
          : 0,
      style: SubtitleStyleSnapshot.fromJson(
        json['style'] as Map<dynamic, dynamic>? ?? const {},
      ),
      imported: _segmentsFromJson(json['imported']),
      recognized: _segmentsFromJson(json['recognized']),
    );
  }

  static Map<String, dynamic> _segmentToJson(LocalSubtitleSegment s) => {
    'from': s.from,
    'to': s.to,
    'text': s.text,
    'translated': s.translated,
  };

  static List<LocalSubtitleSegment> _segmentsFromJson(dynamic raw) {
    if (raw is! List) {
      return const [];
    }
    final result = <LocalSubtitleSegment>[];
    for (final item in raw) {
      if (item is! Map) {
        continue;
      }
      final from = item['from'];
      final to = item['to'];
      final text = item['text'];
      if (from is! num || to is! num || text is! String) {
        continue;
      }
      final translated = item['translated'];
      result.add(
        LocalSubtitleSegment(
          from: from.toDouble(),
          to: to.toDouble(),
          text: text,
          translated: translated is String && translated.isNotEmpty
              ? translated
              : null,
        ),
      );
    }
    return result;
  }
}

/// 字幕存档的打包、解包与应用内缓存。
abstract final class SubtitleArchiveStore {
  static const String _dirName = 'subtitle_archives';
  static const String _metaName = 'meta.json';
  static const String _srtName = 'subtitles.srt';

  static Future<Directory> _cacheDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, _dirName));
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<File> _cacheFile(String bvid, int cid) async {
    final dir = await _cacheDir();
    return File(p.join(dir.path, '${bvid}_$cid.zip'));
  }

  /// 生成导出文件名：标题前五个字 + BV 号，例如「测试视频+BV1xx411c7mD.zip」。
  static String exportFileName(String title, String bvid) {
    final sanitized = _sanitize(title);
    final first5 = String.fromCharCodes(sanitized.runes.take(5)).trim();
    final prefix = first5.isEmpty ? '字幕存档' : first5;
    return '$prefix+$bvid.zip';
  }

  static String _sanitize(String raw) {
    return raw
        .replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// 打包为 zip 字节。内部包含 `meta.json` 与可读的 `subtitles.srt`。
  static Uint8List encode(SubtitleArchive archive) {
    final zip = Archive();
    zip.add(ArchiveFile.string(_metaName, jsonEncode(archive.toJson())));
    final readableSegments =
        archive.activeSource == SubtitleArchive.sourceRecognized
        ? archive.recognized
        : archive.imported;
    zip.add(
      ArchiveFile.string(
        _srtName,
        readableSegments.isEmpty
            ? ''
            : LocalSubtitleService.buildSrt(readableSegments),
      ),
    );
    return ZipEncoder().encodeBytes(zip);
  }

  /// 解析 zip 字节为存档；非本应用存档时返回 null。
  static SubtitleArchive? decode(List<int> bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      return null;
    }
    ArchiveFile? meta;
    for (final file in archive.files) {
      if (file.name == _metaName) {
        meta = file;
        break;
      }
    }
    if (meta == null) {
      return null;
    }
    try {
      final json = jsonDecode(utf8.decode(meta.content));
      if (json is! Map) {
        return null;
      }
      final result = SubtitleArchive.fromJson(json);
      if (result.isEmpty && result.bvid.isEmpty) {
        return null;
      }
      return result;
    } catch (_) {
      return null;
    }
  }

  /// 写入应用内缓存（按 bvid+cid 覆盖）。
  static Future<void> saveToCache(SubtitleArchive archive) async {
    if (archive.bvid.isEmpty || archive.cid <= 0) {
      return;
    }
    final file = await _cacheFile(archive.bvid, archive.cid);
    await file.writeAsBytes(encode(archive), flush: true);
  }

  /// 读取应用内缓存；不存在或损坏时返回 null。
  static Future<SubtitleArchive?> loadFromCache(String bvid, int cid) async {
    if (bvid.isEmpty || cid <= 0) {
      return null;
    }
    try {
      final file = await _cacheFile(bvid, cid);
      if (!file.existsSync()) {
        return null;
      }
      return decode(await file.readAsBytes());
    } catch (_) {
      return null;
    }
  }

  /// 删除应用内缓存。
  static Future<void> removeFromCache(String bvid, int cid) async {
    if (bvid.isEmpty || cid <= 0) {
      return;
    }
    try {
      final file = await _cacheFile(bvid, cid);
      if (file.existsSync()) {
        await file.delete();
      }
    } catch (_) {}
  }
}
