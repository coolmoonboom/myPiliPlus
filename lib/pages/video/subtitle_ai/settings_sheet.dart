import 'dart:io';

import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/services/local_subtitle/local_subtitle_service.dart';
import 'package:PiliPlus/services/local_subtitle/model_manager.dart';
import 'package:PiliPlus/services/local_subtitle/subtitle_translator.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/theme_utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

/// 在视频页之上显示字幕相关面板。
///
/// 复用视频页统一的底部面板机制（竖屏为底部面板、横屏为右侧面板），
/// 并在深色视频页下套用深色主题，保证与播放器 UI 一致。
Future<void>? showSubtitleBottomSheet(
  BuildContext context, {
  required Widget child,
  required PlPlayerController playerController,
}) {
  final theme = playerController.darkVideoPage ? ThemeUtils.darkTheme : null;
  return PageUtils.showVideoBottomSheet(
    context,
    child: theme == null ? child : Theme(data: theme, child: child),
  );
}

/// AI 字幕设置面板（竖屏字幕页与横屏字幕按钮共用）。
///
/// 包含：模型下载/暂停/继续/卸载、双语开关、跟随播放开关、字幕时间偏移
/// （基准 + 精细调控）、翻译设置。
class AiSubtitleSettingsSheet extends StatefulWidget {
  const AiSubtitleSettingsSheet({
    required this.videoDetailController,
    super.key,
  });

  final VideoDetailController videoDetailController;

  @override
  State<AiSubtitleSettingsSheet> createState() =>
      _AiSubtitleSettingsSheetState();
}

class _AiSubtitleSettingsSheetState extends State<AiSubtitleSettingsSheet> {
  late bool _bilingual = GStorage.setting.get(
    SettingBoxKey.whisperBilingual,
    defaultValue: true,
  );

  late bool _followPlayback = GStorage.setting.get(
    SettingBoxKey.whisperFollowPlayback,
    defaultValue: true,
  );

  @override
  void dispose() {
    // 关闭设置面板即落盘（偏移/样式改完常在此刻），避免退出视频时丢设置。
    widget.videoDetailController.persistSubtitleArchive();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Material(
        clipBehavior: Clip.hardEdge,
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.7,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              Text('AI 字幕设置', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                '离线 Whisper 识别法语，支持增量边播边识别',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              const SizedBox(height: 12),
              ModelSelector(
                modelManager: ModelManager.instance,
                playerController: widget.videoDetailController.plPlayerController,
              ),
              const Divider(height: 28),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('双语字幕'),
                subtitle: const Text('在法文原文下方附加中文翻译'),
                value: _bilingual,
                onChanged: (value) {
                  setState(() => _bilingual = value);
                  GStorage.setting.put(SettingBoxKey.whisperBilingual, value);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('跟随播放识别'),
                subtitle: const Text('边播边识别播放位置前后的内容，字幕实时更新；关闭则从当前位置顺序识别整段'),
                value: _followPlayback,
                onChanged: (value) {
                  setState(() => _followPlayback = value);
                  GStorage.setting.put(
                    SettingBoxKey.whisperFollowPlayback,
                    value,
                  );
                },
              ),
              const Divider(height: 28),
              SubtitleOffsetSettings(
                playerController:
                    widget.videoDetailController.plPlayerController,
              ),
              const Divider(height: 28),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.translate_outlined, size: 20),
                title: const Text('翻译设置'),
                onTap: () => showSubtitleBottomSheet(
                  context,
                  playerController:
                      widget.videoDetailController.plPlayerController,
                  child: const TranslationSettingsSheet(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ModelSelector extends StatefulWidget {
  const ModelSelector({
    required this.modelManager,
    required this.playerController,
    super.key,
  });

  final ModelManager modelManager;
  final PlPlayerController playerController;

  @override
  State<ModelSelector> createState() => _ModelSelectorState();
}

class _ModelSelectorState extends State<ModelSelector> {
  late WhisperModel _current = LocalSubtitleService.currentModel;

  void _select(WhisperModel model) {
    if (model == _current) {
      return;
    }
    setState(() => _current = model);
    LocalSubtitleService.setCurrentModel(model);
    final state = widget.modelManager.states[model.modelName];
    if (state == null ||
        (state.state != ModelTaskState.done &&
            state.state != ModelTaskState.downloading)) {
      if (state?.state == ModelTaskState.corrupt) {
        widget.modelManager.redownload(model);
        SmartDialog.showToast('模型文件损坏，正在重新下载 ${model.modelName}…');
      } else {
        widget.modelManager.download(model);
        SmartDialog.showToast('正在下载 ${model.modelName} 识别模型…');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('识别模型', style: theme.textTheme.titleSmall),
        const SizedBox(height: 2),
        Text(
          '点选即切换实时/离线识别使用的模型；未下载的会自动下载。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
        const SizedBox(height: 4),
        ...ModelManager.managedModels.map((model) {
          return Obx(() {
            final state =
                widget.modelManager.states[model.modelName] ??
                ModelState.unknown;
            return _buildRow(context, model, state);
          });
        }),
        const SizedBox(height: 4),
        TextButton.icon(
          onPressed: _pickImport,
          icon: const Icon(Icons.file_download_outlined, size: 18),
          label: const Text('从 Download 导入模型'),
          style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4)),
        ),
      ],
    );
  }

  Future<void> _export(WhisperModel model) async {
    final path = await widget.modelManager.exportModelPath(model);
    if (path == null) {
      SmartDialog.showToast('模型尚未下载');
      return;
    }
    await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
  }

  Future<void> _pickImport() async {
    final candidates = await widget.modelManager.importCandidates();
    if (candidates.isEmpty) {
      SmartDialog.showToast('未在 Download 目录找到 ggml-*.bin 模型文件');
      return;
    }
    showSubtitleBottomSheet(
      context,
      playerController: widget.playerController,
      child: _ImportPicker(
        files: candidates,
        onPick: (file) async {
          final model = await widget.modelManager.importModel(file);
          if (model != null) {
            SmartDialog.showToast('已导入 ${model.modelName} 模型');
          } else {
            SmartDialog.showToast('导入失败：模型文件名需为 ggml-<name>.bin');
          }
          Get.back();
        },
      ),
    );
  }

  Widget _buildRow(BuildContext context, WhisperModel model, ModelState state) {
    final theme = Theme.of(context);
    final label = LocalSubtitleService.modelLabel(model);
    final progress = state.progress;
    final isCurrent = model == _current;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _select(model),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isCurrent
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: isCurrent
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outline,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: isCurrent ? theme.colorScheme.primary : null,
                      fontWeight: isCurrent ? FontWeight.w600 : null,
                    ),
                  ),
                ),
                if (isCurrent)
                  Text(
                    '使用中',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                const SizedBox(width: 8),
                if (state.state == ModelTaskState.done)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('已下载', style: TextStyle(color: Colors.green)),
                      const SizedBox(width: 4),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: '导出模型文件',
                        icon: const Icon(Icons.ios_share, size: 16),
                        onPressed: () => _export(model),
                      ),
                    ],
                  )
                else ...[
                  TextButton(
                    onPressed: state.state == ModelTaskState.downloading
                        ? () => widget.modelManager.pause(model)
                        : (state.state == ModelTaskState.corrupt
                              ? () => widget.modelManager.redownload(model)
                              : () => widget.modelManager.download(model)),
                    child: Text(
                      state.state == ModelTaskState.downloading
                          ? '暂停'
                          : (state.state == ModelTaskState.paused
                                ? '继续'
                                : (state.state == ModelTaskState.corrupt
                                      ? '重新下载'
                                      : '下载')),
                    ),
                  ),
                  if (state.state == ModelTaskState.paused ||
                      state.state == ModelTaskState.done ||
                      state.state == ModelTaskState.corrupt)
                    TextButton(
                      onPressed: () => widget.modelManager.remove(model),
                      child: const Text('卸载'),
                    ),
                ],
              ],
            ),
            if (state.state == ModelTaskState.downloading ||
                state.state == ModelTaskState.paused) ...[
              const SizedBox(height: 2),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(value: progress, minHeight: 4),
              ),
              if (state.received > 0)
                Text(
                  '${(state.received / 1048576).toStringAsFixed(1)} MB'
                  '${state.total > 0 ? '/ ${(state.total / 1048576).toStringAsFixed(1)} MB' : ''}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
            ],
            if (state.error != null)
              Text(
                state.error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 字幕时间偏移设置：开关 + 偏移方向 + 时/分/秒/毫秒输入 + 毫秒级精细调控滑块。
///
/// 由播放器「字幕设置」面板与「AI 字幕设置」面板共用，两处修改实时同步。
class SubtitleOffsetSettings extends StatefulWidget {
  const SubtitleOffsetSettings({required this.playerController, super.key});

  final PlPlayerController playerController;

  /// 精细调控滑块的毫秒范围（前后各 10 分钟，1 毫秒一档）。
  static const int maxMilliseconds = 600000;

  @override
  State<SubtitleOffsetSettings> createState() => _SubtitleOffsetSettingsState();
}

class _SubtitleOffsetSettingsState extends State<SubtitleOffsetSettings> {
  PlPlayerController get pc => widget.playerController;

  late final TextEditingController _hour = TextEditingController();
  late final TextEditingController _minute = TextEditingController();
  late final TextEditingController _second = TextEditingController();
  late final TextEditingController _milli = TextEditingController();
  late bool _later;

  @override
  void initState() {
    super.initState();
    _later = pc.subtitleBaseMs >= 0;
    _syncFields(pc.subtitleBaseMs);
  }

  @override
  void dispose() {
    _hour.dispose();
    _minute.dispose();
    _second.dispose();
    _milli.dispose();
    super.dispose();
  }

  /// 将基准偏移回填到「时/分/秒/毫秒」输入框（参数单位：毫秒）。
  void _syncFields(double ms) {
    final totalMs = ms.abs().round();
    _hour.text = totalMs ~/ 3600000 == 0 ? '' : '${totalMs ~/ 3600000}';
    _minute.text = (totalMs % 3600000) ~/ 60000 == 0
        ? ''
        : '${(totalMs % 3600000) ~/ 60000}';
    _second.text = (totalMs % 60000) ~/ 1000 == 0
        ? ''
        : '${(totalMs % 60000) ~/ 1000}';
    _milli.text = totalMs % 1000 == 0 ? '' : '${totalMs % 1000}';
  }

  /// 输入框只负责设置基准偏移，不触碰精细调控叠加量。
  void _updateFromFields() {
    final h = int.tryParse(_hour.text.trim()) ?? 0;
    final m = int.tryParse(_minute.text.trim()) ?? 0;
    final s = int.tryParse(_second.text.trim()) ?? 0;
    final ms = int.tryParse(_milli.text.trim()) ?? 0;
    final baseMs = h * 3600000 + m * 60000 + s * 1000 + ms;
    pc
      ..setSubtitleBaseMs((_later ? baseMs : -baseMs).toDouble())
      ..subtitleOffsetEnabled = true
      ..applySubtitleDelay();
    setState(() {});
  }

  /// 精细调控滑块只负责叠加量，在基准偏移之上叠加，不回写输入框。
  void _updateFromSlider(double milliseconds) {
    pc
      ..setSubtitleFineTuneMs(milliseconds.roundToDouble())
      ..subtitleOffsetEnabled = true
      ..applySubtitleDelay();
    setState(() {});
  }

  String _format(double seconds) {
    final totalMs = (seconds.abs() * 1000).round();
    final parts = <String>[
      if (totalMs ~/ 3600000 > 0) '${totalMs ~/ 3600000} 时',
      if ((totalMs % 3600000) ~/ 60000 > 0) '${(totalMs % 3600000) ~/ 60000} 分',
      if ((totalMs % 60000) ~/ 1000 > 0) '${(totalMs % 60000) ~/ 1000} 秒',
      if (totalMs % 1000 > 0) '${totalMs % 1000} 毫秒',
    ];
    final duration = parts.isEmpty ? '0 毫秒' : parts.join(' ');
    return '${seconds >= 0 ? '延后' : '提前'} $duration';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = pc.subtitleOffsetEnabled;
    final total = pc.subtitleOffset;
    final fineMs = pc.subtitleFineTuneMs;
    const maxMs = SubtitleOffsetSettings.maxMilliseconds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('字幕时间偏移'),
          subtitle: Text(
            enabled ? '当前总偏移：${_format(total)}' : '开启后可将字幕整体提前或延后',
          ),
          value: enabled,
          onChanged: (value) {
            pc
              ..subtitleOffsetEnabled = value
              ..applySubtitleDelay();
            setState(() {});
          },
        ),
        if (enabled) ...[
          const SizedBox(height: 8),
          Text(
            '基准偏移',
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              ChoiceChip(
                label: const Text('延后'),
                selected: _later,
                onSelected: (_) {
                  _later = true;
                  _updateFromFields();
                },
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('提前'),
                selected: !_later,
                onSelected: (_) {
                  _later = false;
                  _updateFromFields();
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _buildField(_hour, '时')),
              const SizedBox(width: 6),
              Expanded(child: _buildField(_minute, '分')),
              const SizedBox(width: 6),
              Expanded(child: _buildField(_second, '秒')),
              const SizedBox(width: 6),
              Expanded(child: _buildField(_milli, '毫秒')),
            ],
          ),
          const Divider(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('精细调控（毫秒）'),
              Text(
                '微调：${_format(fineMs / 1000)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          Slider(
            min: -maxMs.toDouble(),
            max: maxMs.toDouble(),
            divisions: maxMs * 2,
            value: fineMs.clamp(-maxMs.toDouble(), maxMs.toDouble()).toDouble(),
            label: _format(fineMs / 1000),
            onChanged: _updateFromSlider,
            onChangeStart: (_) => pc.beginSubtitleOffsetDrag(),
            onChangeEnd: (_) => pc.endSubtitleOffsetDrag(),
          ),
          Text(
            '先用「时/分/秒/毫秒」设置基准偏移，再拖动上方滑块按毫秒叠加微调。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildField(TextEditingController controller, String label) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      onChanged: (_) => _updateFromFields(),
    );
  }
}

class _ImportPicker extends StatelessWidget {
  const _ImportPicker({required this.files, required this.onPick});

  final List<File> files;
  final Future<void> Function(File file) onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SizedBox(
        height: 360,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                '选择要导入的模型文件',
                style: theme.textTheme.titleMedium,
              ),
            ),
            Flexible(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: files.length,
                itemBuilder: (context, i) {
                  final f = files[i];
                  return InkWell(
                    onTap: () => onPick(f),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            p.basename(f.path),
                            style: theme.textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            f.path,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class TranslationSettingsSheet extends StatefulWidget {
  const TranslationSettingsSheet({super.key});

  @override
  State<TranslationSettingsSheet> createState() =>
      _TranslationSettingsSheetState();
}

class _TranslationSettingsSheetState extends State<TranslationSettingsSheet> {
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
                  child: Text('自动：在线翻译优先，离线词库兜底'),
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
                helperText: '留空使用 MyMemory 免费接口；填写则按 LibreTranslate 协议 POST',
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

