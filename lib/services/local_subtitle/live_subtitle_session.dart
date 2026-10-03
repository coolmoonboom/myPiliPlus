import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/services/local_subtitle/incremental_recognizer.dart';
import 'package:PiliPlus/services/local_subtitle/local_subtitle_service.dart';
import 'package:PiliPlus/services/local_subtitle/model_manager.dart';
import 'package:PiliPlus/services/local_subtitle/subtitle_debug_log.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

/// 增量字幕识别会话：绑定播放器，边播边识别、边注入字幕。
class LiveSubtitleSession extends GetxController {
  LiveSubtitleSession({
    required this.plPlayerController,
    required this.videoDetailController,
    required ModelManager modelManager,
  }) : _modelManager = modelManager {
    _sub = plPlayerController.position.stream.listen(_onPosition);
    // 会话级一次性订阅：识别出新分段就刷新注入轨。每轮重启识别器都
    // 复用同一个 segments 实例，避免逐轮叠加监听。
    _segSub = segments.listen((_) => _inject());
  }

  final PlPlayerController plPlayerController;
  final VideoDetailController videoDetailController;
  final ModelManager _modelManager;

  final RxBool running = false.obs;
  final RxString stage = ''.obs;
  final RxInt subtitleTrackIndex = 0.obs;

  IncrementalRecognizer? _recognizer;
  StreamSubscription<int>? _sub;
  StreamSubscription<void>? _segSub;
  int _lastPosition = -1;

  /// 注入字幕轨的 1 起始轨号；-1 表示正在添加，0 表示尚未注入
  int _injectTrack = 0;
  Timer? _injectTimer;
  bool _closed = false;

  /// 当前已识别出的分段（增量刷新，供字幕面板监听展示）。
  ///
  /// 必须是稳定实例：面板 Obx 首次 build 时识别器可能还没创建，
  /// 若 getter 在识别器缺位时返回别的列表，订阅就会落在错误对象上，
  /// 导致识别出内容后面板也不刷新（字幕 tab 一直空白）。
  final RxList<LocalSubtitleSegment> segments = <LocalSubtitleSegment>[].obs;

  Stream<int> get positionStream => plPlayerController.position.stream;

  WhisperModel get _model {
    final box = GStorage.setting;
    final index = box.get(SettingBoxKey.whisperModel, defaultValue: 1);
    final options = LocalSubtitleService.modelOptions;
    return options[index.clamp(0, options.length - 1)].model;
  }

  bool get _bilingual =>
      GStorage.setting.get(SettingBoxKey.whisperBilingual, defaultValue: true);

  bool get _followPlayback => GStorage.setting.get(
    SettingBoxKey.whisperFollowPlayback,
    defaultValue: true,
  );

  void _onPosition(int pos) {
    if (!running.value) {
      return;
    }
    if (_lastPosition >= 0 && (pos - _lastPosition).abs() > 8) {
      _recognizer?.onSeek(pos);
    }
    _lastPosition = pos;
  }

  /// 开始/继续识别
  Future<void> start() async {
    if (running.value) {
      return;
    }
    final ds = plPlayerController.dataSource;
    final String? audioUrl;
    if (ds is NetworkSource) {
      audioUrl = ds.audioSource ?? ds.videoSource;
    } else if (ds is FileSource) {
      SmartDialog.showToast('本地文件识别请使用旧版全量识别');
      return;
    } else {
      SmartDialog.showToast('无法获取音频地址');
      return;
    }
    final url = audioUrl ?? '';
    if (url.isEmpty) {
      SmartDialog.showToast('无法获取音频地址');
      return;
    }
    running.value = true;
    stage.value = '检查模型';
    SubtitleDebugLog.instance.log(
      '会话开始 url=$url 模型=${_model.modelName} 双语=$_bilingual '
      '跟随=$_followPlayback',
    );
    try {
      await _modelManager.ensure(_model);
    } catch (e) {
      running.value = false;
      stage.value = '模型未就绪';
      SubtitleDebugLog.instance.log('模型就绪失败：$e');
      SmartDialog.showToast('模型下载失败：$e');
      return;
    }
    SubtitleDebugLog.instance.log('模型就绪：${_model.modelName}');
    if (_closed) {
      return;
    }
    var total = plPlayerController.duration.value;
    for (var i = 0; i < 10 && total <= 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      total = plPlayerController.duration.value;
    }
    if (total <= 0) {
      running.value = false;
      stage.value = '无法获取视频时长';
      SubtitleDebugLog.instance.log('视频时长始终为 0，放弃识别');
      SmartDialog.showToast('无法获取视频时长，请先播放几秒');
      return;
    }
    SubtitleDebugLog.instance.log(
      '视频时长 $total 秒，播放位置 ${plPlayerController.position.value} 秒',
    );
    // 串行化重启：等旧的识别循环（含可能的原生转写挂起）彻底退出，
    // 避免新旧会话同时操作原生模型导致新转写永久卡死（进度卡 0%）
    final old = _recognizer;
    if (old != null) {
      old.stop();
      stage.value = '整理上一轮识别';
      var finishedInTime = true;
      try {
        await old.done.timeout(const Duration(seconds: 270));
      } on TimeoutException {
        finishedInTime = false;
      }
      SubtitleDebugLog.instance.log(
        finishedInTime ? '旧识别循环已退出，启动新会话' : '旧识别循环超时未退出，强制启动新会话',
      );
    }
    segments.clear();
    final recognizer = IncrementalRecognizer(
      audioUrl: url,
      totalSeconds: total,
      segments: segments,
    );
    _recognizer = recognizer
      ..model = _model
      ..bilingual = _bilingual
      ..followPlayback = _followPlayback
      ..positionProvider = () => plPlayerController.position.value;
    _injectTimer = Timer.periodic(const Duration(seconds: 5), (_) => _inject());
    stage.value = '准备就绪';
    recognizer.status.listen((s) {
      if (!_closed) {
        stage.value = s;
      }
    });
    recognizer.running.listen((r) {
      // 识别器自行结束（到末尾/失败）时同步复位会话运行态，避免 UI 卡在识别中
      if (!r && running.value) {
        running.value = false;
        if (segments.isNotEmpty) {
          unawaited(_inject(force: true));
        }
        if (!_closed && stage.value.isEmpty) {
          stage.value = '识别结束';
        }
      }
    });
    await recognizer.start(fromSeconds: plPlayerController.position.value);
  }

  DateTime _lastInjectAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _inject({bool force = false}) async {
    final recognizer = _recognizer;
    if (recognizer == null || _closed || _injectTrack == -1) {
      return;
    }
    // 节流：识别每 add 一句都会触发，重建播放器字幕轨有闪烁，
    // 至少间隔 4 秒再更新（定时器会兜底补上最终内容）
    final now = DateTime.now();
    final hasTrack = _injectTrack > 0;
    if (!force &&
        hasTrack &&
        now.difference(_lastInjectAt) < const Duration(seconds: 4)) {
      return;
    }
    _lastInjectAt = now;
    final segs = segments.toList();
    if (segs.isEmpty) {
      return;
    }
    final vtt = LocalSubtitleService.buildVtt(segs);
    if (_injectTrack == 0) {
      // -1 占位，防止并发重入重复加轨
      _injectTrack = -1;
      final track = await videoDetailController.addSubtitleTrack(
        LocalSubtitleService.buildSubtitleEntry(bilingual: _bilingual),
        vtt,
      );
      if (_closed) {
        return;
      }
      // 必须记录播放器返回的 1 起始轨号；此前记「添加前下标」差一，
      // 后续更新全部写错轨道，注入的字幕只会显示开头几句
      _injectTrack = track;
      subtitleTrackIndex.value = track;
    } else {
      videoDetailController.updateSubtitleTrack(_injectTrack, vtt);
    }
  }

  /// 停止识别并保留已识别结果
  void stop() {
    _injectTimer?.cancel();
    _injectTimer = null;
    _recognizer?.stop();
    SubtitleDebugLog.instance.log('会话停止（保留已识别结果）');
    if (segments.isNotEmpty) {
      unawaited(_inject(force: true));
    }
    running.value = false;
  }

  /// 导出识别结果为 SRT
  Future<void> exportSrt() async {
    final segs = segments.toList();
    if (segs.isEmpty) {
      SmartDialog.showToast('尚无识别结果');
      return;
    }
    final srt = LocalSubtitleService.buildSrt(segs);
    final tempDir = await getTemporaryDirectory();
    final file = await File(
      '${tempDir.path}/subtitles_${DateTime.now().millisecondsSinceEpoch}.srt',
    ).writeAsString(srt);
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
  }

  /// 释放会话：停止识别、取消 position 订阅。由外部生命周期回调调用。
  void shutdown() {
    _closed = true;
    _injectTimer?.cancel();
    _injectTimer = null;
    _recognizer?.stop();
    _recognizer = null;
    _sub?.cancel();
    _sub = null;
    _segSub?.cancel();
    _segSub = null;
    running.value = false;
  }

  @override
  void onClose() {
    shutdown();
    super.onClose();
  }
}
