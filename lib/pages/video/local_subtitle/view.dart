import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/subtitle_ai/settings_sheet.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/services/local_subtitle/local_subtitle_service.dart';
import 'package:PiliPlus/services/local_subtitle/model_manager.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';

/// 本地法语字幕识别页面
/// 端内 Whisper 识别法语语音，生成法中双语字幕
class LocalSubtitleView extends StatefulWidget {
  const LocalSubtitleView({
    required this.plPlayerController,
    required this.videoDetailController,
    super.key,
  });

  final PlPlayerController plPlayerController;
  final VideoDetailController videoDetailController;

  @override
  State<LocalSubtitleView> createState() => _LocalSubtitleViewState();
}

class _LocalSubtitleViewState extends State<LocalSubtitleView> {
  final Box setting = GStorage.setting;

  late bool _bilingual = setting.get(SettingBoxKey.whisperBilingual, defaultValue: true);

  bool _running = false;
  String _stage = '';
  int _percent = 0;
  List<LocalSubtitleSegment> _segments = [];
  String? _vtt;
  String? _error;

  Future<void> _start() async {
    setState(() {
      _running = true;
      _error = null;
      _stage = '准备中';
      _percent = 0;
      _segments = [];
      _vtt = null;
    });
    final res = await LocalSubtitleService.recognize(
      dataSource: widget.plPlayerController.dataSource,
      model: LocalSubtitleService.currentModel,
      bilingual: _bilingual,
      onStage: (stage) {
        if (mounted) setState(() => _stage = stage);
      },
      onProgress: (percent) {
        if (mounted) setState(() => _percent = percent);
      },
    );
    if (!mounted) return;
    switch (res) {
      case Success(:final response):
        setState(() {
          _segments = response;
          _vtt = LocalSubtitleService.buildVtt(response);
        });
        await _apply();
      case Error(:final errMsg):
        setState(() => _error = errMsg ?? '识别失败');
      default:
        setState(() => _error = '识别失败');
    }
    if (mounted) {
      setState(() => _running = false);
    }
  }

  Future<void> _apply() async {
    final vtt = _vtt;
    if (vtt == null) return;
    await widget.videoDetailController.addSubtitleTrack(
      LocalSubtitleService.buildSubtitleEntry(bilingual: _bilingual),
      vtt,
    );
    SmartDialog.showToast('双语字幕已启用，可在底部字幕按钮切换');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('本地法语字幕'),
        actions: [
          IconButton(
            tooltip: '翻译设置',
            icon: const Icon(Icons.tune),
            onPressed: () => showSubtitleBottomSheet(
              context,
              playerController: widget.plPlayerController,
              child: const TranslationSettingsSheet(),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '使用端内 Whisper 模型离线识别法语语音，自动生成法中双语字幕。识别与翻译均不依赖 B 站服务器。',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          const SizedBox(height: 20),
          ModelSelector(
            modelManager: ModelManager.instance,
            playerController: widget.plPlayerController,
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('双语字幕'),
            subtitle: const Text('在法文原文下方附加中文翻译'),
            value: _bilingual,
            onChanged: (value) {
              setState(() => _bilingual = value);
              setting.put(SettingBoxKey.whisperBilingual, value);
            },
          ),
          const Divider(height: 28),
          FilledButton.icon(
            onPressed: _running ? null : _start,
            icon: const Icon(Icons.subtitles_outlined),
            label: Text(_running ? '识别中…' : '开始识别本视频'),
          ),
          if (_running) ...[
            const SizedBox(height: 14),
            LinearProgressIndicator(value: _percent > 0 ? _percent / 100 : null),
            const SizedBox(height: 6),
            Text(
              _percent > 0 ? '$_stage $_percent%' : _stage,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 14),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ],
          if (_segments.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Text(
                  '共 ${_segments.length} 条字幕（$_percent% 后进入翻译）',
                  style: theme.textTheme.bodyMedium,
                ),
                const Spacer(),
                TextButton(
                  onPressed: _apply,
                  child: const Text('应用字幕'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ..._segments
                .take(30)
                .toList()
                .asMap()
                .entries
                .map(
                  (e) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _fmt(e.value.from),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                        Text(e.value.text),
                        if (e.value.translated != null &&
                            e.value.translated!.isNotEmpty)
                          Text(
                            e.value.translated!,
                            style: TextStyle(
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        const Divider(height: 10),
                      ],
                    ),
                  ),
                ),
          ],
          const SizedBox(height: 30),
        ],
      ),
    );
  }

  static String _fmt(double seconds) {
    final s = seconds.toInt();
    final m = s ~/ 60;
    final ss = s % 60;
    return '$m:${ss.toString().padLeft(2, '0')}';
  }
}

