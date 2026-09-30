import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/services/local_subtitle/local_subtitle_service.dart';
import 'package:PiliPlus/services/local_subtitle/model_manager.dart';
import 'package:PiliPlus/services/local_subtitle/subtitle_translator.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

/// AI 字幕设置面板（竖屏字幕页与横屏字幕按钮共用）。
///
/// 包含：模型下载/暂停/继续/卸载、双语开关、跟随播放开关、导入本地字幕、
/// 翻译设置。
class AiSubtitleSettingsSheet extends StatelessWidget {
  const AiSubtitleSettingsSheet({
    required this.videoDetailController,
    super.key,
  });

  final VideoDetailController videoDetailController;

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
              _ModelList(modelManager: ModelManager.instance),
              const Divider(height: 28),
              Obx(() {
                final box = GStorage.setting;
                final bilingual = box.get(
                  SettingBoxKey.whisperBilingual,
                  defaultValue: true,
                );
                return SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('双语字幕'),
                  subtitle: const Text('在法文原文下方附加中文翻译'),
                  value: bilingual,
                  onChanged: (value) {
                    box.put(SettingBoxKey.whisperBilingual, value);
                  },
                );
              }),
              Obx(() {
                final box = GStorage.setting;
                final follow = box.get(
                  SettingBoxKey.whisperFollowPlayback,
                  defaultValue: false,
                );
                return SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('跟随播放识别'),
                  subtitle: const Text('边播边识别当前进度后的内容；关闭则从开头顺序识别整段'),
                  value: follow,
                  onChanged: (value) {
                    box.put(SettingBoxKey.whisperFollowPlayback, value);
                  },
                );
              }),
              const Divider(height: 28),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.upload_file_outlined, size: 20),
                title: const Text('导入本地字幕文件'),
                subtitle: const Text('支持 .srt / .vtt，导入后立即在播放器显示'),
                onTap: () => videoDetailController.importSubtitleFile(context),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.translate_outlined, size: 20),
                title: const Text('翻译设置'),
                onTap: () => showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  useSafeArea: true,
                  builder: (_) => const _TranslationSettingsSheet(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModelList extends StatelessWidget {
  const _ModelList({required this.modelManager});

  final ModelManager modelManager;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('识别模型', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        ...ModelManager.managedModels.map((model) {
          return Obx(() {
            final state =
                modelManager.states[model.modelName] ?? ModelState.unknown;
            return _buildRow(context, model, state);
          });
        }),
      ],
    );
  }

  Widget _buildRow(BuildContext context, WhisperModel model, ModelState state) {
    final theme = Theme.of(context);
    final label = LocalSubtitleService.modelLabel(model);
    final progress = state.progress;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
              if (state.state == ModelTaskState.done)
                const Text('已下载', style: TextStyle(color: Colors.green))
              else ...[
                TextButton(
                  onPressed: state.state == ModelTaskState.downloading
                      ? () => modelManager.pause(model)
                      : () => modelManager.download(model),
                  child: Text(
                    state.state == ModelTaskState.downloading
                        ? '暂停'
                        : (state.state == ModelTaskState.paused ? '继续' : '下载'),
                  ),
                ),
                if (state.state == ModelTaskState.paused ||
                    state.state == ModelTaskState.done)
                  TextButton(
                    onPressed: () => modelManager.remove(model),
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
    );
  }
}

class _TranslationSettingsSheet extends StatefulWidget {
  const _TranslationSettingsSheet();

  @override
  State<_TranslationSettingsSheet> createState() =>
      _TranslationSettingsSheetState();
}

class _TranslationSettingsSheetState extends State<_TranslationSettingsSheet> {
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
