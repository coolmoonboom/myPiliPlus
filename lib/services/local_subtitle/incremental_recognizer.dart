import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/services/local_subtitle/local_subtitle_service.dart';
import 'package:PiliPlus/services/local_subtitle/model_manager.dart';
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

  /// 跟随播放时，识别窗口向后回看当前位置前的秒数（覆盖前文给全字幕）。
  ///
  /// 回看越多首段越长、首条字幕出得越慢，权衡后取 10 秒。
  static const int halfWindowSeconds = 10;

  /// 跟随播放时，每次新识别窗口向前覆盖的秒数。
  ///
  /// 前向少取一些，每段音频更短，识别更快跟上播放位置（避免长时间看不到字幕）。
  static const int followLookaheadSeconds = 8;

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

  /// 连续转写失败次数，达到阈值直接报错退出，避免无限「识别中」
  int _consecutiveFailures = 0;

  /// 后台翻译串行队列：翻译不再阻塞识别循环，识别先出原文、中文后台补齐
  Future<void> _backgroundTranslations = Future<void>.value();

  /// 跟随播放模式下已识别到的最远秒数（增量追加，避免重复转写）
  double _recognizedEnd = 0;

  /// 音频流的媒体 timescale（来自 mdhd/mvhd），用于把 tfdt 解码时间换算为秒
  int _timescale = 0;

  double get _bytesPerSecond {
    final total = _totalBytes;
    if (total == null || total <= 0 || totalSeconds <= 0) {
      return 0;
    }
    return total / totalSeconds;
  }

  /// 当前活跃的识别器：只有它能在结束时释放原生模型，
  /// 避免「停止后立刻重新开始」时旧会话的 releaseModel 把新会话刚加载的
  /// 模型释放掉，导致新转写调用永久挂起（现象：进度卡在 0% 不动）。
  static IncrementalRecognizer? _active;
  final Completer<void> _doneCompleter = Completer<void>();

  /// 识别流程完全结束（含资源释放）后完成，供会话串行化重启。
  Future<void> get done => _doneCompleter.future;

  /// 开始识别；[fromSeconds] 起始位置（默认当前播放位置）
  Future<void> start({int? fromSeconds}) async {
    if (running.value) {
      return;
    }
    _active = this;
    SubtitleDebugLog.instance.log(
      '开始识别 fromSeconds=$fromSeconds '
      'totalSeconds=$totalSeconds follow=$followPlayback '
      'model=${model?.modelName ?? 'null'}',
    );
    running.value = true;
    status.value = '准备音频';
    _cancelled = false;
    final startPos = (fromSeconds ?? positionProvider?.call() ?? 0).clamp(
      0,
      totalSeconds,
    );
    _nextChunkStart = startPos;
    // 跟随播放：识别窗口回看当前位置前若干秒，尽快出首条字幕
    _recognizedEnd = (startPos - halfWindowSeconds)
        .clamp(0, totalSeconds)
        .toDouble();
    _lastEnd = _recognizedEnd;
    _cancelToken = CancelToken();
    try {
      final m = model;
      if (m != null) {
        final v = await ModelManager.instance.validate(m);
        if (v.exists && !v.valid) {
          SubtitleDebugLog.instance.log(
            '启动前检测：模型无效 size=${v.size}B 魔数=${v.magic ?? '无'}',
          );
          throw Exception('模型文件损坏，请在设置中删除并重新下载识别模型');
        }
      }
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
      // 仅当自己仍是当前活跃识别器时才释放原生模型，避免竞态释放新会话模型
      if (identical(_active, this)) {
        _active = null;
        await WhisperController().releaseModel();
      } else {
        SubtitleDebugLog.instance.log('跳过 releaseModel：已有新的识别会话');
      }
      _cancelToken = null;
      if (!_doneCompleter.isCompleted) {
        _doneCompleter.complete();
      }
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
    var src = probeBytes;
    var moofType = _findMoofType(src, 0);
    var initLen = moofType >= 4 ? moofType - 4 : moofType;
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
      src = Uint8List.fromList(res.data ?? const []);
      moofType = _findMoofType(src, 0);
      initLen = moofType >= 4 ? moofType - 4 : moofType;
      if (initLen < 0) {
        initLen = src.length;
      }
      SubtitleDebugLog.instance.log('扩大探测: 收到=${src.length}B moof=$moofType');
    }
    _initHeader = initLen > 0
        ? Uint8List.sublistView(src, 0, initLen)
        : Uint8List(0);
    if (_initHeader == null || _initHeader!.isEmpty) {
      throw '无法解析音频流';
    }
    _parseTimescale(_initHeader!);
    SubtitleDebugLog.instance.log(
      'initHeader=${_initHeader!.length}B timescale=$_timescale',
    );
  }

  /// 解析 init segment（moov）的媒体 timescale。
  ///
  /// 优先取音轨的 [mdhd]（trak→mdia→mdhd），音频通常是 48000，tfdt 的
  /// baseMediaDecodeTime 用的就是它；取不到再退回 mvhd（movie timescale）。
  void _parseTimescale(Uint8List init) {
    final moov = _findBoxContent(init, 'moov');
    if (moov == null) {
      return;
    }
    final mdhd = _findBoxContentRecursive(init, moov, init.length, 'mdhd');
    if (mdhd != null && mdhd + 12 <= init.length) {
      // mdhd content: version+flags(4) creation(4) modification(4) timescale(4)
      _timescale = _readU32(init, mdhd + 12);
      return;
    }
    final mvhd = _findBoxContent(init, 'mvhd', start: moov);
    if (mvhd == null || mvhd + 12 > init.length) {
      return;
    }
    _timescale = _readU32(init, mvhd + 12);
  }

  /// 在 [start, end) 内递归查找 type 为 [type] 的 box，返回其内容起始偏移。
  int? _findBoxContentRecursive(
    Uint8List data,
    int start,
    int end,
    String type,
  ) {
    const containers = {
      'moov',
      'trak',
      'mdia',
      'minf',
      'stbl',
      'dinf',
      'edts',
      'udta',
    };
    var off = start;
    while (off + 8 <= end && off + 8 <= data.length) {
      final size = _readU32(data, off);
      if (size < 8) {
        return null;
      }
      final boxEnd = off + size;
      if (boxEnd > data.length) {
        return null;
      }
      final t = String.fromCharCodes(data.sublist(off + 4, off + 8));
      if (t == type) {
        return off + 8;
      }
      if (containers.contains(t)) {
        final sub = _findBoxContentRecursive(data, off + 8, boxEnd, type);
        if (sub != null) {
          return sub;
        }
      }
      off += size;
    }
    return null;
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

  /// 解析 [moofTypeOffset]（'moof' 类型标识偏移）所在 moof 里 first traf 的
  /// tfdt（baseMediaDecodeTime）。
  ///
  /// box 起始偏移 = 类型标识偏移 - 4（前面是 32 位 size 字段）。
  /// 返回媒体时间刻度值（需除以 [_timescale] 得到秒）；解析失败返回 null。
  int? _moofStartTime(Uint8List data, int moofTypeOffset) {
    if (_timescale <= 0 || moofTypeOffset < 4) {
      return null;
    }
    final boxStart = moofTypeOffset - 4;
    if (boxStart + 16 > data.length) {
      return null;
    }
    final moofSize = _readU32(data, boxStart);
    final moofEnd = moofSize == 0 ? data.length : boxStart + moofSize;
    // moof children（mfhd/traf…）从 box 内容起始开始
    var off = boxStart + 8;
    while (off + 8 <= data.length && off + 8 <= moofEnd) {
      final size = _readU32(data, off);
      if (size < 8) {
        return null;
      }
      final type = String.fromCharCodes(data.sublist(off + 4, off + 8));
      if (type == 'traf') {
        final trafEnd = (off + size).clamp(0, data.length);
        final t = _findTfdt(data, off, trafEnd);
        if (t != null) {
          return t;
        }
      }
      off += size;
    }
    return null;
  }

  int? _findTfdt(Uint8List data, int trafBoxStart, int trafEnd) {
    var off = trafBoxStart + 8;
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

  /// 跟随播放：以当前播放位置为中心，保持识别窗口覆盖到「当前位置 + 8 秒」。
  ///
  /// 播放前进后只追加识别新增区间（增量），已处理部分不再重复转写；
  /// 首次启动回看当前位置前 halfWindowSeconds 秒，形成「前后窗口」。
  Future<void> _runFollow() async {
    while (!_cancelled) {
      final pos = (positionProvider?.call() ?? _nextChunkStart).clamp(
        0,
        totalSeconds,
      );
      if (pos >= totalSeconds - 1) {
        break;
      }
      final winEnd = (pos + followLookaheadSeconds).clamp(0, totalSeconds);
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
    // 对齐到段内第一个 moof box：跳过 moof 之前半截 fragment，
    // 保留从 box 起始（含 4 字节 size 字段）开始的完整 fragment。
    final moofType = _findMoofType(slice, 0);
    final boxStart = moofType >= 4 ? moofType - 4 : 0;
    final skip = boxStart;
    final header = _initHeader!;
    final data = Uint8List(header.length + slice.length - skip);
    data.setRange(0, header.length, header);
    data.setRange(header.length, data.length, slice.sublist(skip));
    // 优先用该 fragment 的 tfdt 解码时间得到精确起点秒数；
    // 解析失败（如非 fMP4 流）再回退到字节偏移估算。
    final tfdt = moofType >= 4 ? _moofStartTime(slice, moofType) : null;
    final t0 = tfdt != null ? tfdt / _timescale : (b0 + skip) / bps;
    if (tfdt == null && moofType >= 4) {
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
    // 心跳：转写进度回调粒度很粗（首尾才更新），期间显示已耗时秒数，
    // 让用户看到识别在进行中，而不是误以为卡在 0%
    var pct = -1;
    final ticker = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_cancelled) {
        return;
      }
      final sec = DateTime.now().difference(startedAt).inSeconds;
      status.value = pct >= 0
          ? '识别 ${_fmt(s0)} ${pct}% 已用${sec}s'
          : '识别 ${_fmt(s0)} 已用${sec}s 出结果稍候';
    });
    late final WhisperTranscribeResponse? result;
    try {
      // 看门狗：单段转写超过 4 分钟视为挂起，按失败跳过，绝不永久卡住
      result = await LocalSubtitleService.transcribeWithModel(
        model: model ?? WhisperModel.base,
        audioPath: file.path,
        lang: 'fr',
        withSegments: true,
        noContext: true,
        suppressNonSpeechTokens: true,
        keepModelLoaded: true,
        onProgress: (p) {
          pct = p;
        },
      ).timeout(const Duration(seconds: 240));
    } on TimeoutException {
      result = null;
      LocalSubtitleService.lastTranscribeError = 'timeout';
      SubtitleDebugLog.instance.log('转写超时 s0=$s0（>240s），跳过该段');
    } finally {
      ticker.cancel();
    }
    final cost = DateTime.now().difference(startedAt).inMilliseconds;
    if (result == null) {
      _consecutiveFailures++;
      final err = LocalSubtitleService.lastTranscribeError ?? '';
      final isModelIssue = err.contains('failed to load model');
      SubtitleDebugLog.instance.log(
        '转写失败 s0=$s0 连续=$_consecutiveFailures 模型问题=$isModelIssue',
      );
      if (_consecutiveFailures >= 3) {
        throw Exception(
          isModelIssue ? '模型加载失败，请在设置中删除并重新下载识别模型' : '连续转写失败，请查看调试日志',
        );
      }
      status.value = isModelIssue ? '模型加载失败，见调试日志' : '转写失败，见调试日志';
      return const [];
    }
    _consecutiveFailures = 0;
    final raw = result.segments ?? [];
    SubtitleDebugLog.instance.log('转写完成 s0=$s0 耗时${cost}ms 原始分段=${raw.length}');
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
      _translateInBackground(list);
    }
    return list;
  }

  /// 后台翻译一段识别结果，不阻塞识别循环。
  ///
  /// 翻译完成后把 [translated] 的中文写回已追加的 [segments]，上次注入的字幕
  /// 由调用方定时/增量刷新覆盖为双语。失败时保留原文，不影响字幕显示。
  void _translateInBackground(List<LocalSubtitleSegment> chunkSegments) {
    final snapshot = List<LocalSubtitleSegment>.of(chunkSegments);
    _backgroundTranslations = _backgroundTranslations.then((_) async {
      if (_cancelled) {
        return;
      }
      final t0ms = DateTime.now().millisecondsSinceEpoch;
      final translated = await LocalSubtitleService.translateSegments(snapshot);
      if (_cancelled) {
        return;
      }
      SubtitleDebugLog.instance.log(
        '后台翻译完成 耗时${DateTime.now().millisecondsSinceEpoch - t0ms}ms '
        '${translated.length}条',
      );
      final expected = snapshot.length;
      final applied = <int>[];
      for (final seg in translated) {
        if (seg.translated == null || seg.translated!.isEmpty) {
          continue;
        }
        for (var i = 0; i < segments.length; i++) {
          final s = segments[i];
          if (s.from == seg.from &&
              s.to == seg.to &&
              s.text == seg.text &&
              s.translated == null) {
            segments[i] = seg;
            applied.add(i);
            break;
          }
        }
      }
      if (applied.isNotEmpty) {
        segments.refresh();
        SubtitleDebugLog.instance.log(
          '后台翻译写回 $expected 条，实际 ${applied.length} 条',
        );
      }
    });
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

  /// 在 [data] 中从 [start] 起定位第一个结构合法的 moof box 类型偏移。
  ///
  /// 仅当 'moof' 前 4 字节是合理的 box size（>=8 且不越界）才视为真实 box，
  /// 避免音频载荷里偶然出现的字节组合被误当成 box 头。
  static int _findMoofType(Uint8List data, int start) {
    for (var i = start; i + 8 <= data.length; i++) {
      final t = _readU32(data, i);
      if (t == 0x6D6F6F66) {
        final boxStart = i - 4;
        if (boxStart >= 0) {
          final size = _readU32(data, boxStart);
          if (size >= 8 && boxStart + size <= data.length) {
            return i;
          }
        }
      }
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
