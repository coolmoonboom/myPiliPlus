import 'dart:io';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models_new/video/video_play_info/subtitle.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/services/local_subtitle/model_manager.dart';
import 'package:PiliPlus/services/local_subtitle/subtitle_debug_log.dart';
import 'package:PiliPlus/services/local_subtitle/subtitle_translator.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/subtitle_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

class LocalSubtitleSegment {
  const LocalSubtitleSegment({
    required this.from,
    required this.to,
    required this.text,
    this.translated,
  });

  /// 起点，单位秒
  final double from;

  /// 终点，单位秒
  final double to;

  /// 识别出的法文原文
  final String text;

  /// 中文翻译（可选）
  final String? translated;

  LocalSubtitleSegment copyWith({String? translated}) => LocalSubtitleSegment(
    from: from,
    to: to,
    text: text,
    translated: translated ?? this.translated,
  );
}

/// 本地法语语音识别（whisper.cpp 端内推理）+ 双语字幕生成。
///
/// 流程：获取音频 -> 端内 Whisper 识别（法语）->（可选）翻译为中文 -> 生成 VTT。
abstract final class LocalSubtitleService {
  static const WhisperModel defaultModel = WhisperModel.base;

  static const List<({WhisperModel model, String label})> modelOptions = [
    (model: WhisperModel.tiny, label: 'tiny (最快, 约75MB)'),
    (model: WhisperModel.base, label: 'base (推荐, 约140MB)'),
    (model: WhisperModel.small, label: 'small (更准, 约460MB)'),
    (model: WhisperModel.medium, label: 'medium (高准, 约1.5GB)'),
    (model: WhisperModel.large, label: 'large-v3 (最佳, 约3GB)'),
  ];

  static String modelLabel(WhisperModel model) =>
      modelOptions.firstWhere((e) => e.model == model).label;

  /// 当前使用的识别模型（实时与离线识别共用）。
  static WhisperModel get currentModel {
    final box = GStorage.setting;
    final index = box.get(SettingBoxKey.whisperModel, defaultValue: 1);
    return modelOptions[index.clamp(0, modelOptions.length - 1)].model;
  }

  /// 设置当前识别模型。
  static void setCurrentModel(WhisperModel model) {
    final index = modelOptions.indexWhere((e) => e.model == model);
    if (index >= 0) {
      GStorage.setting.put(SettingBoxKey.whisperModel, index);
    }
  }

  /// 解析可用于识别的音频文件。
  ///
  /// 返回 (文件路径, 是否为临时下载文件)。网络视频需要先把音频流下载到临时目录，
  /// Android/iOS/macOS 上 whisper_ggml 内置 FFmpeg 会自动转成模型需要的格式。
  static Future<LoadingState<(String, bool)>> resolveAudio(DataSource ds) async {
    final String? source;
    if (ds is FileSource) {
      source = ds.audioSource ?? ds.videoSource;
      final file = File(source!);
      if (!file.existsSync()) {
        return const Error('本地音频文件不存在');
      }
      return Success((source, false));
    }
    if (ds is NetworkSource) {
      source = ds.audioSource ?? ds.videoSource;
    } else {
      return const Error('不支持的视频来源');
    }
    final url = source!;
    if (url.isEmpty) {
      return const Error('无法获取音频地址');
    }
    final tempDir = await getTemporaryDirectory();
    final savePath = path.join(
      tempDir.path,
      'asr_${DateTime.now().millisecondsSinceEpoch}.m4s',
    );
    final res = await Request().downloadFile(url, savePath);
    if (res.statusCode != 200 || !File(savePath).existsSync()) {
      return Error('音频下载失败: ${res.data?['message'] ?? res.statusCode}');
    }
    return Success((savePath, true));
  }

  /// 下载 whisper 模型（如已缓存则直接返回路径）。
  static Future<void> ensureModel(WhisperModel model) {
    return ModelManager.instance.ensure(model);
  }

  /// 用指定模型文件路径执行转写。
  ///
  /// 与 WhisperController.transcribe 等价，但模型路径取自
  /// [ModelManager.pathOf]（Android 上位于 Download，用户可导出/导入）。
  static Future<WhisperTranscribeResponse?> transcribeWithModel({
    required WhisperModel model,
    required String audioPath,
    String lang = 'fr',
    String? initialPrompt,
    bool noContext = false,
    bool suppressNonSpeechTokens = false,
    bool withSegments = false,
    bool splitOnWord = false,
    bool keepModelLoaded = false,
    void Function(int percent)? onProgress,
  }) async {
    final modelPath = await ModelManager.instance.pathOf(model);
    SubtitleDebugLog.instance.log(
      'transcribe modelPath=$modelPath 存在='
      '${await File(modelPath).exists()}',
    );
    try {
      return await Whisper(model: model).transcribe(
        transcribeRequest: TranscribeRequest(
          audio: audioPath,
          language: lang,
          isTranslate: false,
          isNoTimestamps: !withSegments,
          splitOnWord: splitOnWord,
          isRealtime: true,
          diarize: false,
          initialPrompt: initialPrompt,
          noContext: noContext,
          suppressNonSpeechTokens: suppressNonSpeechTokens,
          keepModelLoaded: keepModelLoaded,
        ),
        modelPath: modelPath,
        onProgress: onProgress,
      );
    } catch (e) {
      debugPrint('whisper transcribe error: $e');
      SubtitleDebugLog.instance.log('whisper transcribe 失败：$e');
      return null;
    }
  }

  /// 执行识别并生成字幕分段。
  static Future<LoadingState<List<LocalSubtitleSegment>>> recognize({
    required DataSource dataSource,
    WhisperModel model = defaultModel,
    bool bilingual = true,
    void Function(String stage)? onStage,
    void Function(int percent)? onProgress,
  }) async {
    if (!Platform.isAndroid &&
        !Platform.isIOS &&
        !Platform.isMacOS &&
        !Platform.isWindows &&
        !Platform.isLinux) {
      return const Error('当前平台不支持本地识别');
    }

    onStage?.call('准备音频');
    final audioState = await resolveAudio(dataSource);
    if (audioState case Error(:final errMsg)) {
      return Error(errMsg);
    }
    if (audioState is Loading) {
      return const Error('音频准备失败');
    }
    final (audioPath, _) = (audioState as Success<(String, bool)>).response;

    onStage?.call('下载/加载模型');
    try {
      await ensureModel(model);
    } catch (e) {
      return Error('模型下载失败: $e');
    }

    onStage?.call('识别中');
    final result = await transcribeWithModel(
      model: model,
      audioPath: audioPath,
      lang: 'fr',
      withSegments: true,
      noContext: true,
      suppressNonSpeechTokens: true,
      onProgress: onProgress,
    );
    if (result == null) {
      return const Error('识别失败');
    }
    final rawSegments = result.segments ?? [];
    if (rawSegments.isEmpty) {
      return const Error('未识别到语音内容');
    }

    var segments = rawSegments
        .map(
          (s) => LocalSubtitleSegment(
            from: s.fromTs.inMilliseconds / 1000.0,
            to: s.toTs.inMilliseconds / 1000.0,
            text: s.text.trim(),
          ),
        )
        .where((s) => s.text.isNotEmpty)
        .toList();

    if (segments.isEmpty) {
      return const Error('未识别到有效文本');
    }

    if (bilingual) {
      onStage?.call('翻译中');
      segments = await translateSegments(segments);
    }

    return Success(segments);
  }

  /// 为分段列表生成中文翻译（逐段并发），供增量识别复用。
  ///
  /// 每批并发 6、整批最多等 [batchTimeout]；翻译卡住/失败时保留原文，
  /// 避免拖住识别进度造成「一直识别中」。
  static Future<List<LocalSubtitleSegment>> translateSegments(
    List<LocalSubtitleSegment> segments, {
    Duration batchTimeout = const Duration(seconds: 12),
  }) async {
    final translator = TranslationService.create();
    const concurrency = 6;
    final results = List<String?>.filled(segments.length, null);
    for (var start = 0; start < segments.length; start += concurrency) {
      final end = (start + concurrency).clamp(0, segments.length);
      final batch = segments.sublist(start, end);
      final translations = await Future.wait<String>(
        batch.map((seg) async {
          try {
            return await translator.translate(seg.text);
          } catch (_) {
            return '';
          }
        }),
      ).timeout(
        batchTimeout,
        onTimeout: () => List<String>.filled(batch.length, ''),
      );
      for (var i = 0; i < translations.length; i++) {
        if (translations[i].isNotEmpty) {
          results[start + i] = translations[i];
        }
      }
    }
    return [
      for (var i = 0; i < segments.length; i++)
        segments[i].copyWith(translated: results[i]),
    ];
  }

  /// 将分段构建为双语 VTT 字幕文本，可直接注入播放器字幕轨道。
  static String buildVtt(List<LocalSubtitleSegment> segments) {
    final list = segments
        .map(
          (s) => {
            'from': s.from,
            'to': s.to,
            'content': s.translated == null || s.translated!.isEmpty
                ? s.text
                : '${s.text}\n${s.translated}',
          },
        )
        .toList();
    return SubtitleUtils.json2Vtt(list);
  }

  /// 生成一条可加入字幕列表的 [Subtitle] 记录。
  static Subtitle buildSubtitleEntry({bool bilingual = true}) => Subtitle(
    lan: 'fr',
    lanDoc: bilingual ? '法语字幕（本地·双语）' : '法语字幕（本地）',
    isAi: true,
  );

  /// 将分段构建为标准 SRT 文本，用于导出/分享字幕文件。
  static String buildSrt(List<LocalSubtitleSegment> segments) {
    final buffer = StringBuffer();
    for (var i = 0; i < segments.length; i++) {
      final s = segments[i];
      buffer
        ..writeln(i + 1)
        ..writeln(_fmtSrt(s.from, s.to))
        ..writeln(
          s.translated == null || s.translated!.isEmpty
              ? s.text
              : '${s.text}\n${s.translated}',
        )
        ..writeln();
    }
    return buffer.toString();
  }

  static String _fmtSrt(double from, double to) {
    String ts(double t) {
      final ms = (t * 1000).round();
      final h = ms ~/ 3600000;
      final m = (ms % 3600000) ~/ 60000;
      final s = (ms % 60000) ~/ 1000;
      final ml = ms % 1000;
      return '${h.toString().padLeft(2, '0')}:'
          '${m.toString().padLeft(2, '0')}:'
          '${s.toString().padLeft(2, '0')},'
          '${ml.toString().padLeft(3, '0')}';
    }

    return '${ts(from)} --> ${ts(to)}';
  }
}
