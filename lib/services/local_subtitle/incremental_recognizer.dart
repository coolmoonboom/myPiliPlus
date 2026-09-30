import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/services/local_subtitle/local_subtitle_service.dart';
import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

/// 分段增量识别器。
///
/// 不再整段下载音频后一次性识别，而是把音频流按字节范围分段下载
/// （每段约 60 秒），一段段边播边识别：
///   - 只下载音频流的字节区间，流量远小于整段下载 + 整段视频
///   - 识别进度跟随播放进度（可选），实现"边播边出字幕"
///   - 支持播放进度跳变（拖动）后从新位置继续识别
///   - 支持中途停止
class IncrementalRecognizer extends GetxController {
  IncrementalRecognizer({required this.audioUrl, required this.totalSeconds});

  /// 音频流地址（无音频时退化为视频流地址）
  final String audioUrl;

  /// 视频总时长（秒）
  final int totalSeconds;

  /// 每个识别分段的时长（秒）
  static const int chunkSeconds = 60;

  /// 跟随播放时，剩余多少秒进入下一段预取
  static const int prefetchSeconds = 15;

  final RxList<LocalSubtitleSegment> segments = <LocalSubtitleSegment>[].obs;
  final RxString status = ''.obs;
  final RxBool running = false.obs;

  WhisperModel? model;
  bool bilingual = true;

  /// 跟随播放进度（false = 从头到尾顺序识别全部）
  bool followPlayback = false;

  /// 提供当前播放位置（秒）
  int Function()? positionProvider;

  CancelToken? _cancelToken;
  bool _cancelled = false;
  int _nextChunkStart = 0;
  int? _totalBytes;
  Uint8List? _initHeader;
  bool _rangeSupported = false;
  double _lastEnd = 0;

  double get _bytesPerSecond {
    final total = _totalBytes;
    if (total == null || total <= 0 || totalSeconds <= 0) {
      return 0;
    }
    return total / totalSeconds;
  }

  /// 开始识别；[fromSeconds] 起始位置（默认当前播放位置）
  Future<void> start({int? fromSeconds}) async {
    if (running.value) {
      return;
    }
    running.value = true;
    status.value = '准备音频';
    _cancelled = false;
    _nextChunkStart = (fromSeconds ?? positionProvider?.call() ?? 0).clamp(
      0,
      totalSeconds,
    );
    _lastEnd = _nextChunkStart.toDouble();
    _cancelToken = CancelToken();
    try {
      await _prepare();
      await _run();
    } catch (e) {
      if (!_cancelled) {
        status.value = '识别失败：$e';
      }
    } finally {
      running.value = false;
      if (!_cancelled && segments.isEmpty) {
        status.value = '未识别到语音内容';
      } else if (!_cancelled) {
        status.value = '识别完成';
      }
      await WhisperController().releaseModel();
      _cancelToken = null;
    }
  }

  Future<void> _prepare() async {
    // 探测 Range 支持与 init segment 边界（第一个 moof 出现的位置）
    const probe = 65536;
    final probeRes = await Request.dio.get<List<int>>(
      audioUrl,
      options: Options(
        responseType: ResponseType.bytes,
        headers: {'Range': 'bytes=0-${probe - 1}'},
        validateStatus: (s) => s == 206 || s == 200,
      ),
    );
    final statusCode = probeRes.statusCode ?? -1;
    _rangeSupported = statusCode == 206;
    final contentRange = probeRes.headers.value('content-range') ?? '';
    if (contentRange.isNotEmpty) {
      final total = int.tryParse(contentRange.split('/').last);
      if (total != null) {
        _totalBytes = total;
      }
    } else if (!_rangeSupported) {
      _totalBytes = probeRes.data?.length;
    }
    final probeBytes = Uint8List.fromList(probeRes.data ?? const []);
    var moof = _indexOf(probeBytes, const [0x6D, 0x6F, 0x6F, 0x66], 0);
    var initLen = moof;
    if (initLen < 0) {
      // moov 可能超出探针范围，扩大探测
      final res = await Request.dio.get<List<int>>(
        audioUrl,
        options: Options(
          responseType: ResponseType.bytes,
          headers: {'Range': 'bytes=0-524287'},
          validateStatus: (s) => s == 206 || s == 200,
        ),
      );
      final bytes = Uint8List.fromList(res.data ?? const []);
      moof = _indexOf(bytes, const [0x6D, 0x6F, 0x6F, 0x66], 0);
      initLen = moof;
      if (initLen < 0) {
        initLen = bytes.length;
      }
    }
    if (initLen > 0) {
      _initHeader = initLen <= probeBytes.length
          ? Uint8List.sublistView(probeBytes, 0, initLen)
          : Uint8List(0);
    }
    if (_initHeader == null || _initHeader!.isEmpty) {
      throw '无法解析音频流';
    }
  }

  Future<void> _run() async {
    while (!_cancelled) {
      final chunkStart = _nextChunkStart;
      if (chunkStart >= totalSeconds) {
        break;
      }
      final chunkEnd = (chunkStart + chunkSeconds).clamp(0, totalSeconds);
      if (followPlayback) {
        // 等待播放进度到达本段起点（或接近段末）
        while (!_cancelled) {
          final pos = positionProvider?.call() ?? chunkStart;
          if (pos >= chunkStart - 1 || pos >= chunkEnd - prefetchSeconds) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 800));
        }
        if (_cancelled) {
          break;
        }
        if ((positionProvider?.call() ?? 0) > chunkEnd) {
          _nextChunkStart = chunkEnd;
          continue;
        }
      }
      status.value = '识别 ${_fmt(chunkStart)}~${_fmt(chunkEnd)}';
      try {
        final added = await _processChunk(chunkStart, chunkEnd);
        if (added) {
          segments.refresh();
        }
      } catch (e) {
        if (_cancelled) {
          break;
        }
        // 单段失败不中断整体，跳过该段继续
        status.value = '段 ${_fmt(chunkStart)} 失败：$e';
      }
      _nextChunkStart = chunkEnd;
    }
  }

  Future<bool> _processChunk(int s0, int s1) async {
    final bps = _bytesPerSecond;
    if (bps <= 0) {
      throw '音频流信息不完整';
    }
    // 尾部多取约 5 秒，保证最后一段 fragment 完整
    final tailExtra = (bps * 5).round();
    final b0 = (s0 * bps).round();
    final b1 = (s1 * bps).round();
    final rangeEnd = b1 + tailExtra;
    final res = await Request.dio.get<List<int>>(
      audioUrl,
      cancelToken: _cancelToken,
      options: Options(
        responseType: ResponseType.bytes,
        headers: {'Range': 'bytes=$b0-$rangeEnd'},
        validateStatus: (s) => s == 206 || s == 200,
      ),
    );
    if (_cancelled) {
      return false;
    }
    var slice = Uint8List.fromList(res.data ?? const []);
    if (slice.isEmpty) {
      throw '音频分段下载失败';
    }
    if (!_rangeSupported) {
      // 服务器不支持 Range，退化为整段（此次返回的是完整文件）
      final initLen = _initHeader?.length ?? 0;
      if (slice.length > initLen) {
        slice = Uint8List.sublistView(slice, initLen);
      }
      final abs = await _transcribeChunk(
        s0,
        Uint8List.fromList(slice),
        s0.toDouble(),
      );
      return _append(segments, abs);
    }
    // 对齐到段内第一个 moof，丢弃 moof 之前的半截 fragment
    final moof = _indexOf(slice, const [0x6D, 0x6F, 0x6F, 0x66], 0);
    final skip = moof > 0 ? moof : 0;
    final header = _initHeader!;
    final data = Uint8List(header.length + slice.length - skip);
    data.setRange(0, header.length, header);
    data.setRange(header.length, data.length, slice.sublist(skip));
    final t0 = (b0 + skip) / bps;
    final abs = await _transcribeChunk(s0, data, t0);
    return _append(segments, abs);
  }

  /// 转写一段音频文件，返回绝对时间的分段列表
  Future<List<LocalSubtitleSegment>> _transcribeChunk(
    int s0,
    Uint8List data,
    double t0,
  ) async {
    final tempDir = await getTemporaryDirectory();
    final filePath = path.join(tempDir.path, 'asr_chunk.m4a');
    final file = await File(filePath).writeAsBytes(data);
    final result = await WhisperController().transcribe(
      model: model ?? WhisperModel.base,
      audioPath: file.path,
      lang: 'fr',
      withSegments: true,
      noContext: true,
      suppressNonSpeechTokens: true,
      keepModelLoaded: true,
    );
    final raw = result?.transcription.segments ?? [];
    final list = <LocalSubtitleSegment>[];
    for (final seg in raw) {
      final text = seg.text.trim();
      if (text.isEmpty) {
        continue;
      }
      final from = t0 + seg.fromTs.inMilliseconds / 1000.0;
      final to = t0 + seg.toTs.inMilliseconds / 1000.0;
      if (to <= s0 + 1) {
        continue;
      }
      list.add(LocalSubtitleSegment(from: from, to: to, text: text));
    }
    if (bilingual && list.isNotEmpty) {
      return LocalSubtitleService.translateSegments(list);
    }
    return list;
  }

  bool _append(
    RxList<LocalSubtitleSegment> target,
    List<LocalSubtitleSegment> list,
  ) {
    if (list.isEmpty) {
      return false;
    }
    var changed = false;
    for (final seg in list) {
      if (seg.from < _lastEnd - 1.5) {
        continue;
      }
      target.add(seg);
      if (seg.to > _lastEnd) {
        _lastEnd = seg.to;
      }
      changed = true;
    }
    return changed;
  }

  static int _indexOf(Uint8List haystack, List<int> needle, int start) {
    outer:
    for (var i = start; i <= haystack.length - needle.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) {
          continue outer;
        }
      }
      return i;
    }
    return -1;
  }

  static String _fmt(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// 停止识别
  void stop() {
    _cancelled = true;
    _cancelToken?.cancel('stopped');
  }

  /// 播放位置跳变（拖动进度条）时调用：跟随模式下从新位置继续
  void onSeek(int newPosition) {
    if (!followPlayback || _cancelled) {
      return;
    }
    segments.removeWhere((s) => s.from >= newPosition - 2);
    _nextChunkStart = newPosition.clamp(0, totalSeconds);
    _lastEnd = _nextChunkStart.toDouble();
  }

  @override
  void onClose() {
    stop();
    super.onClose();
  }
}
