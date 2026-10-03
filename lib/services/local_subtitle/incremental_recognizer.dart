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
  IncrementalRecognizer({
    required this.totalSeconds,
    this.audioUrl = '',
    this.audioFile,
    RxList<LocalSubtitleSegment>? segments,
  }) : segments = segments ?? <LocalSubtitleSegment>[].obs;

  /// 音频流地址（在线模式；无音频时退化为视频流地址）
  final String audioUrl;

  /// 本地音频文件路径（离线模式，audio.m4s）；非空时优先于网络下载
  final String? audioFile;

  bool get _isFileMode => audioFile != null;

  RandomAccessFile? _raf;

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

  /// 识别结果列表；会话会注入共享实例，保证 UI 订阅的对象稳定
  final RxList<LocalSubtitleSegment> segments;
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
  int? _totalBytes;
  Uint8List? _initHeader;
  bool _rangeSupported = false;

  /// 每个识别块的时长（秒）。整片按此长度切块，块优先级队列调度。
  /// 30 秒：手机上 base 模型一段约 40~75 秒可出结果，兼顾「拖到哪里都快出字幕」
  /// 与转写固定开销。
  static const int blockSeconds = 30;

  /// 单块最多尝试次数，超过则跳过该块（避免无限重试卡住队列）
  static const int _maxTriesPerBlock = 3;

  /// 已完成/已跳过的块号
  final Set<int> _settledBlocks = {};

  /// 每块已尝试次数
  final Map<int, int> _blockTries = {};

  /// 连续转写失败次数，达到阈值直接报错退出，避免无限「识别中」
  int _consecutiveFailures = 0;

  /// 后台翻译串行队列：翻译不再阻塞识别循环，识别先出原文、中文后台补齐
  Future<void> _backgroundTranslations = Future<void>.value();

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

  /// 转写进行中收到「重新开始」：旧循环退出后自动再启一轮，
  /// 原生转写无法中断，用户无需等待它跑完再点开始。
  bool _pendingRestart = false;

  /// 停止后是否释放原生模型。会话内 stop→start 复用模型置 false（秒重启）；
  /// 页面关闭时由会话置 true 走正常释放。
  bool releaseModelOnExit = true;

  /// 识别流程完全结束（含资源释放）后完成，供会话收尾。
  Future<void> get done => _doneCompleter.future;

  /// 开始识别；[fromSeconds] 起始位置（默认当前播放位置）
  Future<void> start({int? fromSeconds}) async {
    if (running.value) {
      // 上一轮还在跑（原生转写中无法中断）：排队自动重启，别让用户干等
      _pendingRestart = true;
      _cancelled = true;
      _cancelToken?.cancel('restart requested');
      status.value = '正在切换到新的识别队列…';
      SubtitleDebugLog.instance.log('重复启动请求：标记 pendingRestart');
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
    SubtitleDebugLog.instance.log('起始位置参考 ${_fmt(startPos.toInt())}');
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
      await _raf?.close();
      _raf = null;
      running.value = false;
      if (_pendingRestart) {
        SubtitleDebugLog.instance.log('旧循环已退出，自动开启新一轮识别队列');
      } else if (!_cancelled && segments.isEmpty) {
        status.value = '未识别到语音内容';
        SubtitleDebugLog.instance.log('未识别到语音内容');
      } else if (!_cancelled) {
        status.value = '识别完成';
        SubtitleDebugLog.instance.log('识别完成，共 ${segments.length} 条');
      } else {
        status.value = '识别已停止（结果已保留）';
      }
      // 停止后是否释放原生模型：会话内 stop→start 保留模型实现秒重启；
      // 仅当外部（页面关闭）要求退出时释放，且只有自己仍是活跃识别器才释放。
      if (releaseModelOnExit && !_pendingRestart && identical(_active, this)) {
        _active = null;
        await WhisperController().releaseModel();
      }
      _cancelToken = null;
      if (!_doneCompleter.isCompleted) {
        _doneCompleter.complete();
      }
      if (_pendingRestart) {
        _pendingRestart = false;
        scheduleMicrotask(() {
          if (!running.value) {
            start();
          }
        });
      }
    }
  }

  Future<void> _prepare() async {
    if (_isFileMode) {
      await _prepareFile();
    } else {
      await _prepareHttp();
    }
  }

  /// 离线模式：直接打开本地 audio.m4s。
  ///
  /// 文件头部第一个 moof 之前的部分（ftyp+moov）就是 init 头，字节→时间点
  /// 与在线版同一套 moof/tfdt 机制，但读取是本地的，没有下载等待。
  Future<void> _prepareFile() async {
    final file = audioFile!;
    if (!await File(file).exists()) {
      throw '音频文件不存在：$file';
    }
    final raf = File(file).openSync();
    _raf = raf;
    _totalBytes = await raf.length();
    _rangeSupported = true;
    final probeLen = _totalBytes! > 524288 ? 524288 : _totalBytes!;
    await raf.setPosition(0);
    final head = Uint8List.fromList(await raf.read(probeLen));
    final moofInset = _findMoofType(head, 0);
    final initLen = moofInset >= 4 ? moofInset - 4 : -1;
    if (initLen <= 0) {
      throw '无法解析本地音频流（未找到 fMP4 头）';
    }
    _initHeader = Uint8List.sublistView(head, 0, initLen);
    _parseTimescale(_initHeader!);
    SubtitleDebugLog.instance.log(
      '本地流: initHeader=${_initHeader!.length}B timescale=$_timescale '
      'totalBytes=$_totalBytes',
    );
  }

  Future<void> _prepareHttp() async {
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

  Future<void> _run() async => _runBlockQueue();

  int get _blockCount => (totalSeconds + blockSeconds - 1) ~/ blockSeconds;

  /// 用户跳转次数。块执行期间发生跳转时丢弃该块结果重新选块，
  /// 保证「优先识别用户当前进度」，且跳转不消耗该块的重试次数。
  int _seekEpoch = 0;

  /// 块优先级队列调度：
  /// - 整片按 [blockSeconds] 切块；
  /// - 跟随模式下，从当前播放位置所在块开始环形取第一个未完成的块
  ///   （刚打开就拖进度 → 先认当前位置；回溯到已认过的块 → 直接跳过）；
  /// - 顺序模式依次从第 0 块往后补齐。
  Future<void> _runBlockQueue() async {
    while (!_cancelled) {
      final blk = _pickBlock();
      if (blk == null) {
        break;
      }
      final epoch = _seekEpoch;
      final tries = (_blockTries[blk] = (_blockTries[blk] ?? 0) + 1);
      final s0 = blk * blockSeconds;
      final s1 = (s0 + blockSeconds) > totalSeconds
          ? totalSeconds
          : s0 + blockSeconds;
      SubtitleDebugLog.instance.log(
        '开始块 $blk/${_blockCount - 1} ${_fmt(s0)}~${_fmt(s1)} 第$tries次尝试',
      );
      try {
        final added = await _processChunk(s0, s1);
        if (_seekEpoch != epoch) {
          // 识别期间用户切换了位置：结果可能已过时，退回队列重新选块
          _blockTries[blk] = tries - 1;
          SubtitleDebugLog.instance.log('块 $blk 执行期间发生跳转，重新调度');
          continue;
        }
        if (added) {
          segments.refresh();
        }
        _settledBlocks.add(blk);
        SubtitleDebugLog.instance.log('块完成 $blk 累计${segments.length}条');
      } catch (e) {
        if (_cancelled) {
          break;
        }
        if (_seekEpoch != epoch) {
          _blockTries[blk] = tries - 1;
          continue;
        }
        SubtitleDebugLog.instance.log('块失败 $blk ${_fmt(s0)}（第$tries次）：$e');
        if (tries >= _maxTriesPerBlock) {
          _settledBlocks.add(blk);
          status.value = '${_fmt(s0)} 处的字幕识别失败，已跳过';
        }
      }
    }
  }

  int? _pickBlock() {
    final startIdx = followPlayback
        ? ((positionProvider?.call() ?? 0).clamp(0, totalSeconds) ~/
                  blockSeconds)
              .toInt()
        : 0;
    final count = _blockCount;
    for (var i = 0; i < count; i++) {
      final b = (startIdx + i) % count;
      if (!_settledBlocks.contains(b) &&
          (b + 1) * blockSeconds <= totalSeconds + blockSeconds &&
          (_blockTries[b] ?? 0) < _maxTriesPerBlock) {
        return b;
      }
    }
    return null;
  }

  /// 读取一段字节区间：本地文件用 RandomAccessFile 随机读；
  /// 在线走 HTTP Range 请求。
  Future<Uint8List> _fetchRange(int b0, int rangeEnd) async {
    if (_isFileMode) {
      final raf = _raf!;
      final total = _totalBytes ?? 0;
      final end = rangeEnd >= total ? total - 1 : rangeEnd;
      final len = end - b0 + 1;
      if (len <= 0) {
        return Uint8List(0);
      }
      await raf.setPosition(b0);
      return await raf.read(len);
    }
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
    return Uint8List.fromList(res.data ?? const []);
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
    final res = await _fetchRange(b0, rangeEnd);
    if (_cancelled) {
      return false;
    }
    var slice = res;
    SubtitleDebugLog.instance.log(
      '分段请求 [$s0-$s1]s bytes=$b0-$rangeEnd 收到=${slice.length}B '
      'bps=${bps.toStringAsFixed(1)}${_isFileMode ? ' 本地' : ''}',
    );
    if (slice.isEmpty) {
      throw '音频分段读取失败';
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

  /// 合入一段转写结果：块调度可能乱序产出，且重试块会与已识别区间重叠。
  /// 时间上重叠的分段保留时长更长（内容更完整）的一条，最后整体按开始时间排序。
  bool _append(
    RxList<LocalSubtitleSegment> target,
    List<LocalSubtitleSegment> list,
  ) {
    if (list.isEmpty) {
      return false;
    }
    final merged = <LocalSubtitleSegment>[...target];
    var changed = false;
    for (final seg in list) {
      final overlaps = [
        for (final s in merged)
          if (s.from < seg.to - 0.5 && seg.from < s.to - 0.5) s,
      ];
      if (overlaps.isEmpty) {
        merged.add(seg);
        changed = true;
        continue;
      }
      final shortest = overlaps.reduce(
        (a, b) => (a.to - a.from) <= (b.to - b.from) ? a : b,
      );
      if ((seg.to - seg.from) > (shortest.to - shortest.from)) {
        merged
          ..remove(shortest)
          ..add(seg);
        changed = true;
      }
    }
    if (changed) {
      merged.sort((a, b) => a.from.compareTo(b.from));
      target.assignAll(merged);
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

  /// 播放位置跳变（拖动进度条）时调用：
  /// 已识别结果全部保留（回看已认过的区间直接可看，不清空），
  /// 仅递增跳转世代，让正在执行的块完成后丢弃结果并重新按新位置选块。
  void onSeek(int newPosition) {
    if (!followPlayback || _cancelled) {
      return;
    }
    _seekEpoch++;
    SubtitleDebugLog.instance.log(
      '检测到跳转 -> ${_fmt(newPosition)}，保留已有 ${segments.length} 条字幕',
    );
  }

  @override
  void onClose() {
    stop();
    super.onClose();
  }
}
