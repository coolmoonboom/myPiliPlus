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
    String url = '';
    String? audioFile;
    if (ds is NetworkSource) {
      url = ds.audioSource ?? ds.videoSource ?? '';
      if (url.isEmpty) {
        SmartDialog.showToast('无法获取音频地址');
        return;
      }
    } else if (ds is FileSource) {
      // 离线缓存：直接读缓存目录里的 audio.m4s，无需下载
      final p = ds.audioSource;
      if (p == null || !File(p).existsSync()) {
        SmartDialog.showToast('未找到本地音频缓存文件（可能为合并流视频）');
        return;
      }
      audioFile = p;
    } else {
      SmartDialog.showToast('无法获取音频地址');
      return;
    }
    running.value = true;
    stage.value = '检查模型';
    SubtitleDebugLog.instance.log(
      '会话开始 ${audioFile != null ? 'file=$audioFile' : 'url=$url'} '
      '模型=${_model.modelName} 双语=$_bilingual 跟随=$_followPlayback',
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
    // 复用同一识别器实例：块完成进度与已识别结果全部保留，
    // stop→start 秒重启（模型也不释放），转写中被重新点开始则自动排队重启。
    final firstTime = _recognizer == null;
    final recognizer = _recognizer ??= IncrementalRecognizer(
      audioUrl: audioFile == null ? url : '',
      audioFile: audioFile,
      totalSeconds: total,
      segments: segments,
    );
    if (firstTime) {
      recognizer.releaseModelOnExit = false;
      recognizer.status.listen((s) {
        if (!_closed) {
          stage.value = s;
        }
      });
      recognizer.running.listen((r) {
        if (_closed) {
          return;
        }
        if (r) {
          running.value = true;
          return;
        }
        // 识别器自行结束（到末尾/失败）时同步复位会话运行态
        if (running.value) {
          running.value = false;
          if (segments.isNotEmpty) {
            unawaited(_inject(force: true));
          }
          if (stage.value.isEmpty) {
            stage.value = '识别结束';
          }
        }
      });
    }
    _injectTimer?.cancel();
    _injectTimer = Timer.periodic(const Duration(seconds: 5), (_) => _inject());
    recognizer
      ..model = _model
      ..bilingual = _bilingual
      ..followPlayback = _followPlayback;
    recognizer.positionProvider = () => plPlayerController.position.value;
    recognizer.releaseModelOnExit = false;
    SubtitleDebugLog.instance.log(
      '复用识别器：已保留 ${segments.length} 条结果，'
      '剩余块将继续按优先队列识别',
    );
    stage.value = '准备就绪';
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

  /// 用字幕存档中的识别结果恢复会话，不触发识别。
  ///
  /// [inject] 为 true 时立即把结果注入为一支字幕轨并生效；为 false 时仅
  /// 填充面板展示（用于存档里非激活来源）。
  Future<void> restoreSegments(
    List<LocalSubtitleSegment> restored, {
    bool inject = true,
  }) async {
    segments.assignAll(restored);
    if (!inject || restored.isEmpty || _closed) {
      return;
    }
    final track = await videoDetailController.addSubtitleTrack(
      LocalSubtitleService.buildSubtitleEntry(bilingual: _bilingual),
      LocalSubtitleService.buildVtt(restored),
    );
    if (_closed) {
      return;
    }
    _injectTrack = track;
    subtitleTrackIndex.value = track;
  }

  /// 修改某条字幕的原文/译文（按时间定位，面板长按编辑入口调用）。
  ///
  /// 立即强制刷新注入的字幕轨，视频上的字幕同步更新。
  void updateSegment({
    required double from,
    required double to,
    required String text,
    String? translated,
  }) {
    final idx = segments.indexWhere((s) => s.from == from && s.to == to);
    if (idx < 0) {
      return;
    }
    segments[idx] = LocalSubtitleSegment(
      from: from,
      to: to,
      text: text,
      translated: translated,
    );
    segments.refresh();
    unawaited(_inject(force: true));
  }

  /// 释放会话：停止识别、释放模型、取消 position 订阅。由外部生命周期回调调用。
  void shutdown() {
    _closed = true;
    _injectTimer?.cancel();
    _injectTimer = null;
    final recognizer = _recognizer;
    if (recognizer != null) {
      // 页面退出：本轮循环结束后释放原生模型（若用户已开新会话则由守卫跳过）
      recognizer.releaseModelOnExit = true;
      recognizer.stop();
    }
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
