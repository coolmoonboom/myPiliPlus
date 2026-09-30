import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:get/get.dart';

/// 指定片段循环（AB 循环）配置面板
///
/// 支持两种设置方式：
/// 1. 边播放边设置：点击「当前」以当前播放位置作为起点/终点
/// 2. 手动输入：点击起点/终点时间直接输入时间轴（如 1:00 或 75）
void showAbLoopSheet(BuildContext context, PlPlayerController controller) {
  PageUtils.showVideoBottomSheet(
    context,
    maxWidth: 420,
    child: _AbLoopSheet(controller: controller),
  );
}

class _AbLoopSheet extends StatelessWidget {
  const _AbLoopSheet({required this.controller});

  final PlPlayerController controller;

  String _fmt(int seconds) =>
      seconds < 0 ? '未设置' : DurationUtils.formatDuration(seconds);

  Future<void> _editTime({
    required BuildContext context,
    required String title,
    required int initial,
    required ValueChanged<int> onConfirm,
  }) async {
    final textController = TextEditingController(
      text: initial >= 0 ? _fmt(initial) : '00:00',
    );
    final result = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: textController,
          autofocus: true,
          keyboardType: TextInputType.text,
          decoration: const InputDecoration(
            hintText: '格式：mm:ss 或 秒数，例如 1:15 或 75',
          ),
          onSubmitted: (_) => Get.back(result: _parse(textController.text)),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Get.back(result: _parse(textController.text)),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (result != null && result >= 0) {
      onConfirm(result);
    }
  }

  /// 解析用户输入的时间：支持 `1:15`、`01:15.500`、`75` 等
  static int _parse(String input) {
    final text = input.trim();
    if (text.isEmpty) {
      return -1;
    }
    final parts = text.split(':');
    if (parts.length == 1) {
      final seconds = double.tryParse(parts[0].replaceAll(',', '.'));
      return seconds?.round() ?? -1;
    }
    double total = 0;
    for (final part in parts) {
      final value = double.tryParse(part.replaceAll(',', '.'));
      if (value == null) {
        return -1;
      }
      total = total * 60 + value;
    }
    return total.round();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.repeat, size: 20),
                const SizedBox(width: 8),
                Text(
                  '片段循环',
                  style: theme.textTheme.titleMedium,
                ),
                const Spacer(),
                Obx(
                  () => controller.abLoopEnabled.value
                      ? Text(
                          '循环中',
                          style: TextStyle(
                            color: theme.colorScheme.primary,
                            fontSize: 13,
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                IconButton(
                  tooltip: '关闭',
                  icon: const Icon(Icons.close),
                  onPressed: () => Get.back(),
                ),
              ],
            ),
            const Divider(height: 12),
            Obx(() {
              final position = controller.position.value;
              return Text(
                '当前播放位置：${_fmt(position)}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              );
            }),
            const SizedBox(height: 12),
            Obx(
              () => _buildPointRow(
                context,
                theme,
                label: '起点 A',
                value: controller.abLoopStart.value,
                onUseCurrent: () => controller.setAbLoopStart(),
                onInput: () => _editTime(
                  context: context,
                  title: '设置起点 A',
                  initial: controller.abLoopStart.value,
                  onConfirm: (v) => controller.setAbLoopStart(v),
                ),
                onClear: () => controller.abLoopStart.value = -1,
              ),
            ),
            const SizedBox(height: 10),
            Obx(
              () => _buildPointRow(
                context,
                theme,
                label: '终点 B',
                value: controller.abLoopEnd.value,
                onUseCurrent: () => controller.setAbLoopEnd(),
                onInput: () => _editTime(
                  context: context,
                  title: '设置终点 B',
                  initial: controller.abLoopEnd.value,
                  onConfirm: (v) => controller.setAbLoopEnd(v),
                ),
                onClear: () => controller.abLoopEnd.value = -1,
              ),
            ),
            const SizedBox(height: 16),
            Obx(
              () => Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: controller.abLoopReady
                          ? controller.toggleAbLoop
                          : null,
                      icon: Icon(
                        controller.abLoopEnabled.value
                            ? Icons.pause_circle_outline
                            : Icons.play_circle_outline,
                        size: 18,
                      ),
                      label: Text(
                        controller.abLoopEnabled.value ? '停止循环' : '开始循环',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: () {
                      controller.clearAbLoop();
                      Get.back();
                    },
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('清除'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Obx(
              () => controller.abLoopReady
                  ? Text(
                      '循环区间：${_fmt(controller.abLoopStart.value)} - ${_fmt(controller.abLoopEnd.value)}',
                      style: theme.textTheme.bodySmall,
                    )
                  : const Text(
                      '提示：播放到起点后点击「当前」，再播放到终点点击「当前」即可',
                      style: TextStyle(fontSize: 12),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPointRow(
    BuildContext context,
    ThemeData theme, {
    required String label,
    required int value,
    required VoidCallback onUseCurrent,
    required VoidCallback onInput,
    required VoidCallback onClear,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 54,
          child: Text(label, style: theme.textTheme.bodyMedium),
        ),
        Expanded(
          child: InkWell(
            onTap: onInput,
            borderRadius: const BorderRadius.all(Radius.circular(8)),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: const BorderRadius.all(Radius.circular(8)),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.schedule,
                    size: 16,
                    color: theme.colorScheme.outline,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    value < 0
                        ? '未设置（点击输入）'
                        : DurationUtils.formatDuration(value),
                    style: const TextStyle(fontSize: 15),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        TextButton(
          onPressed: onUseCurrent,
          child: const Text('当前'),
        ),
        IconButton(
          tooltip: '清除',
          visualDensity: VisualDensity.compact,
          onPressed: onClear,
          icon: const Icon(Icons.backspace_outlined, size: 18),
        ),
      ],
    );
  }
}
