import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/services/local_subtitle/local_subtitle_service.dart';
import 'package:PiliPlus/services/local_subtitle/subtitle_translator.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

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

  late WhisperModel _model = _savedModel;
  late bool _bilingual = setting.get(SettingBoxKey.whisperBilingual, defaultValue: true);

  bool _running = false;
  String _stage = '';
  int _percent = 0;
  List<LocalSubtitleSegment> _segments = [];
  String? _vtt;
  String? _error;

  WhisperModel get _savedModel {
    final index = setting.get(SettingBoxKey.whisperModel, defaultValue: 1);
    final options = LocalSubtitleService.modelOptions;
    return options[index.clamp(0, options.length - 1)].model;
  }

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
      model: _model,
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
            onPressed: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              useSafeArea: true,
              builder: (_) => const _TranslationSettingsSheet(),
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
          _buildModelSelector(theme),
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

  Widget _buildModelSelector(ThemeData theme) {
    return Row(
      children: [
        const Text('识别模型'),
        const SizedBox(width: 12),
        Expanded(
          child: DropdownButtonFormField<WhisperModel>(
            initialValue: _model,
            isExpanded: true,
            decoration: const InputDecoration(border: InputBorder.none),
            items: [
              for (final option in LocalSubtitleService.modelOptions)
                DropdownMenuItem(
                  value: option.model,
                  child: Text(
                    option.label,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
            ],
            onChanged: (value) {
              if (value == null) return;
              setState(() => _model = value);
              final index = LocalSubtitleService.modelOptions
                  .indexWhere((e) => e.model == value);
              setting.put(SettingBoxKey.whisperModel, index);
            },
          ),
        ),
      ],
    );
  }
}

class _TranslationSettingsSheet extends StatefulWidget {
  const _TranslationSettingsSheet();

  @override
  State<_TranslationSettingsSheet> createState() =>
      _TranslationSettingsSheetState();
}

class _TranslationSettingsSheetState
    extends State<_TranslationSettingsSheet> {
  late final TextEditingController _endpoint = TextEditingController(
    text: setting.get(SettingBoxKey.translationEndpoint) as String? ?? '',
  );
  late final TextEditingController _apiKey = TextEditingController(
    text: setting.get(SettingBoxKey.translationApiKey) as String? ?? '',
  );
  late TranslationProvider _provider = TranslationSettings.load().provider;

  Box get setting => GStorage.setting;

  @override
  void dispose() {
    _endpoint.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  void _save() {
    TranslationSettings(
      provider: _provider,
      endpoint: _endpoint.text.trim(),
      apiKey: _apiKey.text.trim(),
    ).save();
    SmartDialog.showToast('翻译设置已保存');
    Get.back();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: Material(
        clipBehavior: Clip.hardEdge,
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(16),
          children: [
              Text('中文翻译方式', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              DropdownButton<TranslationProvider>(
                isExpanded: true,
                value: _provider,
                items: const [
                  DropdownMenuItem(
                    value: TranslationProvider.glossary,
                    child: Text('本地词库优先，在线接口自动回退'),
                  ),
                  DropdownMenuItem(
                    value: TranslationProvider.http,
                    child: Text('在线翻译接口'),
                  ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _provider = value);
                },
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _endpoint,
                decoration: const InputDecoration(
                  labelText: '接口地址（可选）',
                  helperText:
                      '留空使用 MyMemory 免费接口；填写则按 LibreTranslate 协议 POST',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _apiKey,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'API Key（可选）',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _save, child: const Text('保存')),
          ],
        ),
      ),
    );
  }
}
