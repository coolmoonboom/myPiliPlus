import 'package:PiliPlus/services/local_subtitle/subtitle_debug_log.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// AI 字幕调试日志界面：展示模型下载/音频探测/分段转写/翻译全链路日志，
/// 支持复制全部与清空。由「AI 字幕设置 → 调试日志」入口打开。
class SubtitleDebugLogSheet extends StatelessWidget {
  const SubtitleDebugLogSheet({super.key});

  Future<void> _copyAll() async {
    final dump = SubtitleDebugLog.instance.dump;
    if (dump.isEmpty) {
      SmartDialog.showToast('暂无日志');
      return;
    }
    await Utils.copyText(dump, toastText: '已复制 ${dump.split('\n').length} 行日志');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SizedBox(
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text('调试日志', style: theme.textTheme.titleMedium),
                  ),
                  Obx(() {
                    // 首次 build 必须读到 Rx，避免 GetX improper use
                    final count = SubtitleDebugLog.instance.entries.length;
                    return Text(
                      '$count 条',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    );
                  }),
                  TextButton(onPressed: _copyAll, child: const Text('复制')),
                  TextButton(
                    onPressed: () {
                      SubtitleDebugLog.instance.clear();
                      SmartDialog.showToast('日志已清空');
                    },
                    child: const Text('清空'),
                  ),
                ],
              ),
            ),
            if (!SubtitleDebugLog.instance.enabled)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  '日志记录已关闭，到「AI 字幕设置」重新打开后才会继续记录',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            Expanded(
              child: Obx(() {
                final entries = SubtitleDebugLog.instance.entries;
                if (entries.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.all(24),
                    child: Center(
                      child: Text(
                        '暂无日志，开始识别后这里会显示全链路调试信息',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  reverse: true,
                  itemCount: entries.length,
                  itemBuilder: (context, i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1.5),
                    child: Text(
                      entries[entries.length - 1 - i],
                      textAlign: TextAlign.start,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }
}
