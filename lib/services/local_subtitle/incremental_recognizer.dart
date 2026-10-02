import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/services/local_subtitle/local_subtitle_service.dart';
import 'package:PiliPlus/services/local_subtitle/subtitle_debug_log.dart';
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

  /// 顺序识别（不跟随播放）时每段的时长（秒）
  static const int chunkSeconds = 40;

  /// 跟随播放时，识别窗口覆盖播放位置前后各 20 秒
  static const int halfWindowSeconds = 20;

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

  /// 跟随播放模式下已识别到的最远秒数（增量追加，避免重复转写）
  double _recognizedEnd = 0;

  /// 音频流的 timescale（来自 mvhd），用于把 fragment 的解码时间换算为秒
  int _timescale = 0;

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
    SubtitleDebugLog.instance.log('开始识别 fromSeconds=$fromSeconds '
        'totalSeconds=$totalSeconds follow=$followPlayback '
        'model=${model?.modelName ?? 'null'}');
    running.value = true;
    status.value = '准备音频';
    _cancelled = false;
    final startPos = (fromSeconds ?? positionProvider?.call() ?? 0).clamp(
      0,
      totalSeconds,
    );
    _nextChunkStart = startPos;
    // 跟随播放：识别窗口回看当前位置前 20 秒（「前后二十秒」）
    _recognizedEnd = (startPos - halfWindowSeconds)
        .clamp(0, totalSeconds)
        .toDouble();
    _lastEnd = _recognizedEnd;
    _cancelToken = CancelToken();
    try {
      await _prepare();
      await _run();
    } catch (e) {
      if (!_cancelled) {
        status.value = '识别失败：$e';
        SubtitleDebugLog.instance.log('识别失败：$e');
      }
    } finally {
      running.value = false;
      if (!_cancelled && segments.isEmpty) {
        status.value = '未识别到语音内容';
        SubtitleDebugLog.instance.log('未识别到语音内容');
      } else if (!_cancelled) {
        status.value = '识别完成';
        SubtitleDebugLog.instance.log('识别完成，共 ${segments.length} 条');
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
        sendTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
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
    SubtitleDebugLog.instance.log(
      '探测: status=$statusCode range支持=$_rangeSupported '
      'totalBytes=$_totalBytes 收到=${probeRes.data?.length ?? 0}B',
    );
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
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
        ),
      );
      final bytes = Uint8List.fromList(res.data ?? const []);
      moof = _indexOf(bytes, const [0x6D, 0x6F, 0x6F, 0x66], 0);
      initLen = moof;
      if (initLen < 0) {
        initLen = bytes.length;
      }
      SubtitleDebugLog.instance.log(
        '扩大探测: 收到=${bytes.length}B moof=$moof',
      );
    }
    if (initLen > 0) {
      _initHeader = initLen <= probeBytes.length
          ? Uint8List.sublistView(probeBytes, 0, initLen)
          : Uint8List(0);
    }
    if (_initHeader == null || _initHeader!.isEmpty) {
      throw '无法解析音频流';
    }
    _parseTimescale(_initHeader!);
    SubtitleDebugLog.instance.log(
      'initHeader=${_initHeader!.length}B timescale=$_timescale',
    );
  }

  /// 解析 init segment（moov）中 mvhd 的 timescale。
  void _parseTimescale(Uint8List init) {
    final moov = _findBoxContent(init, 'moov');
    if (moov == null) {
      return;
    }
    final mvhd = _findBoxContent(init, 'mvhd', start: moov);
    if (mvhd == null || mvhd + 12 > init.length) {
      return;
    }
    // mvhd content: version+flags(4) creation(4) modification(4) timescale(4)
    _timescale = _readU32(init, mvhd + 12);
  }

  /// 最外层查找指定类型 box，返回其内容起始偏移。
  int? _findBoxContent(Uint8List data, String type, {int start = 0}) {
    var off = start;
    while (off + 8 <= data.length) {
      final size = _readU32(data, off);
      if (size < 8) {
        return null;
      }
      final t = String.fromCharCodes(data.sublist(off + 4, off + 8));
      if (t == type) {
        return off + 8;
      }
      off += size;
    }
    return null;
  }

  /// 解析 [moofOffset] 所在 moof 里 first traf 的 tfdt（baseMediaDecodeTime）。
  ///
  /// 返回媒体时间刻度值（需除以 [_timescale] 得到秒）；解析失败返回 null。
  int? _moofStartTime(Uint8List data, int moofOffset) {
    if (_timescale <= 0 || moofOffset < 0 || moofOffset + 16 > data.length) {
      return null;
    }
    final moofSize = _readU32(data, moofOffset);
    final moofEnd = moofSize == 0 ? data.length : moofOffset + moofSize;
    var off = moofOffset + 8;
    while (off + 8 <= data.length && off + 8 <= moofEnd) {
      final size = _readU32(data, off);
      if (size < 8) {
        return null;
      }
      final type = String.fromCharCodes(data.sublist(off + 4, off + 8));
      if (type == 'traf') {
        final t = _findTfdt(data, off, off + size);
        if (t != null) {
          return t;
        }
      }
      off += size;
    }
    return null;
  }

  int? _findTfdt(Uint8List data, int trafStart, int trafEnd) {
    var off = trafStart + 8;
    while (off + 8 <= data.length && off + 8 <= trafEnd) {
      final size = _readU32(data, off);
      if (size < 8) {
        return null;
      }
      final type = String.fromCharCodes(data.sublist(off + 4, off + 8));
      if (type == 'tfdt') {
        if (off + 16 > data.length) {
          return null;
        }
        final version = data[off + 8];
        if (version == 0) {
          return _readU32(data, off + 12);
        }
        if (off + 20 > data.length) {
          return null;
        }
        return _readU64(data, off + 12);
      }
      off += size;
    }
    return null;
  }

  static int _readU32(Uint8List data, int offset) {
    return (data[offset] << 24) |
        (data[offset + 1] << 16) |
        (data[offset + 2] << 8) |
        data[offset + 3];
  }

  static int _readU64(Uint8List data, int offset) {
    return _readU32(data, offset) * 4294967296 + _readU32(data, offset + 4);
  }

  Future<void> _run() async {
    if (followPlayback) {
      await _runFollow();
    } else {
      await _runSequential();
    }
  }

  /// 顺序识别整段：从起始位置按固定长度分段往后识别，直到末尾。
  Future<void> _runSequential() async {
    while (!_cancelled) {
      final chunkStart = _nextChunkStart;
      if (chunkStart >= totalSeconds) {
        break;
      }
      final chunkEnd = (chunkStart + chunkSeconds).clamp(0, totalSeconds);
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

  /// 跟随播放：以当前播放位置为中心，保持识别窗口覆盖到「当前位置 + 20 秒」。
  ///
  /// 播放前进后只追加识别新增区间（增量），已处理部分不再重复转写；
  /// 首次启动回看当前位置前 20 秒，形成「前后二十秒」窗口。
  Future<void> _runFollow() async {
    while (!_cancelled) {
      final pos = (positionProvider?.call() ?? _nextChunkStart).clamp(
        0,
        totalSeconds,
      );
      if (pos >= totalSeconds - 1) {
        break;
      }
      final winEnd = (pos + halfWindowSeconds).clamp(0, totalSeconds);
      if (winEnd <= _recognizedEnd) {
        // 播放未前进（暂停/缓冲）：给出明确状态，避免误以为卡死
        if (status.value != '等待播放进度…') {
          status.value = '等待播放进度…（当前位置 ${_fmt(pos)}）';
          SubtitleDebugLog.instance.log(
            '等待播放进度: pos=${_fmt(pos)} 已识别到=${_fmt(_recognizedEnd.floor())}',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 600));
        continue;
      }
      final winStart = _recognizedEnd.floor();
      status.value = '识别 ${_fmt(winStart)}~${_fmt(winEnd)}';
      final startedAt = DateTime.now();
      try {
        final added = await _processChunk(winStart, winEnd);
        final cost = DateTime.now().difference(startedAt).inMilliseconds;
        SubtitleDebugLog.instance.log(
          '段识别完成 ${_fmt(winStart)}~${_fmt(winEnd)} '
          '耗时${cost}ms 新增=${added ? '是' : '否'} '
          '累计${segments.length}条',
        );
        if (added) {
          segments.refresh();
        }
        _recognizedEnd = winEnd.toDouble();
        _nextChunkStart = winEnd;
      } catch (e) {
        if (_cancelled) {
          break;
        }
        status.value = '段 ${_fmt(winStart)} 失败：$e';
        SubtitleDebugLog.instance.log(
          '段失败 ${_fmt(winStart)}~${_fmt(winEnd)}：$e',
        );
        // 失败也推进起点，避免死循环反复识别同一段
        _recognizedEnd = winEnd.toDouble();
        _nextChunkStart = winEnd;
      }
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
        sendTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 60),
      ),
    );
    if (_cancelled) {
      return false;
    }
    var slice = Uint8List.fromList(res.data ?? const []);
    SubtitleDebugLog.instance.log(
      '分段请求 [$s0-$s1]s bytes=$b0-$rangeEnd '
      'status=${res.statusCode} 收到=${slice.length}B bps=${bps.toStringAsFixed(1)}',
    );
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
    // 优先用该 fragment 的 tfdt 解码时间得到精确起点秒数；
    // 解析失败（如非 fMP4 流）再回退到字节偏移估算。
    final tfdt = moof >= 0 ? _moofStartTime(slice, moof) : null;
    final t0 = tfdt != null
        ? tfdt / _timescale
        : (b0 + skip) / bps;
    if (tfdt == null && moof >= 0) {
      SubtitleDebugLog.instance.log('tfdt 解析失败，回退字节估算 t0');
    }
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
    final startedAt = DateTime.now();
    SubtitleDebugLog.instance.log(
      '转写开始 s0=$s0 t0=${t0.toStringAsFixed(2)} 音频${data.length}B '
      '模型=${model?.modelName ?? 'base'}',
    );
    final result = await LocalSubtitleService.transcribeWithModel(
      model: model ?? WhisperModel.base,
      audioPath: file.path,
      lang: 'fr',
      withSegments: true,
      noContext: true,
      suppressNonSpeechTokens: true,
      keepModelLoaded: true,
      onProgress: (p) {
        if (!_cancelled) {
          status.value = '识别 ${_fmt(s0)} $p%';
        }
      },
    );
    final cost = DateTime.now().difference(startedAt).inMilliseconds;
    final raw = result?.segments ?? [];
    SubtitleDebugLog.instance.log(
      '转写完成 s0=$s0 耗时${cost}ms 原始分段=${raw.length}',
    );
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
      final t0ms = DateTime.now().millisecondsSinceEpoch;
      final translated = await LocalSubtitleService.translateSegments(list);
      SubtitleDebugLog.instance.log(
        '翻译完成 s0=$s0 耗时'
        '${DateTime.now().millisecondsSinceEpoch - t0ms}ms '
        '${list.length}条',
      );
      return translated;
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
    SubtitleDebugLog.instance.log('手动停止识别，已识别 ${segments.length} 条');
    _cancelToken?.cancel('stopped');
  }

  /// 播放位置跳变（拖动进度条）时调用：跟随模式下从新位置继续
  void onSeek(int newPosition) {
    if (!followPlayback || _cancelled) {
      return;
    }
    SubtitleDebugLog.instance.log('检测到跳转 -> ${_fmt(newPosition)}');
    segments.removeWhere((s) => s.from >= newPosition - 2);
    final pos = newPosition.clamp(0, totalSeconds);
    _nextChunkStart = pos;
    _recognizedEnd = (pos - halfWindowSeconds)
        .clamp(0, totalSeconds)
        .toDouble();
    _lastEnd = _recognizedEnd - 1.5;
  }

  @override
  void onClose() {
    stop();
    super.onClose();
  }
}
