import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/services/local_subtitle/incremental_recognizer.dart';
import 'package:PiliPlus/services/local_subtitle/local_subtitle_service.dart';
import 'package:PiliPlus/services/local_subtitle/model_manager.dart';
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
  }

  final PlPlayerController plPlayerController;
  final VideoDetailController videoDetailController;
  final ModelManager _modelManager;

  final RxBool running = false.obs;
  final RxString stage = ''.obs;
  final RxInt subtitleTrackIndex = 0.obs;

  IncrementalRecognizer? _recognizer;
  StreamSubscription<int>? _sub;
  int _lastPosition = -1;
  int _injectTrack = 0;
  Timer? _injectTimer;
  bool _closed = false;

  static final RxList<LocalSubtitleSegment> _emptySegments =
      <LocalSubtitleSegment>[].obs;

  /// 当前已识别出的分段（增量刷新，供字幕面板监听展示）
  RxList<LocalSubtitleSegment> get segments =>
      _recognizer?.segments ?? _emptySegments;

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
    try {
      await _modelManager.ensure(_model);
    } catch (e) {
      running.value = false;
      stage.value = '模型未就绪';
      SmartDialog.showToast('模型下载失败：$e');
      return;
    }
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
      SmartDialog.showToast('无法获取视频时长，请先播放几秒');
      return;
    }
    final recognizer = IncrementalRecognizer(
      audioUrl: url,
      totalSeconds: total,
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
    recognizer.segments.listen((_) => _inject());
    await recognizer.start(fromSeconds: plPlayerController.position.value);
  }

  void _inject() {
    final recognizer = _recognizer;
    if (recognizer == null || _closed) {
      return;
    }
    final segs = recognizer.segments.toList();
    if (segs.isEmpty) {
      return;
    }
    final vtt = LocalSubtitleService.buildVtt(segs);
    final idx = _injectTrack;
    if (idx == 0) {
      _injectTrack = videoDetailController.subtitles.length;
      videoDetailController.addSubtitleTrack(
        LocalSubtitleService.buildSubtitleEntry(bilingual: _bilingual),
        vtt,
      );
      subtitleTrackIndex.value = _injectTrack;
    } else {
      videoDetailController.updateSubtitleTrack(idx, vtt);
    }
  }

  /// 停止识别并保留已识别结果
  void stop() {
    _injectTimer?.cancel();
    _injectTimer = null;
    _recognizer?.stop();
    running.value = false;
  }

  /// 导出识别结果为 SRT
  Future<void> exportSrt() async {
    final recognizer = _recognizer;
    if (recognizer == null) {
      SmartDialog.showToast('尚无识别结果');
      return;
    }
    final segs = recognizer.segments.toList();
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
    running.value = false;
  }

  @override
  void onClose() {
    shutdown();
    super.onClose();
  }
}
