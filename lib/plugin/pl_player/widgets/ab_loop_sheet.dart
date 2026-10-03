import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// 片段循环配置卡片（播放器内嵌 overlay，非模态）
///
/// 特性：
/// 1. 拖动进度条不会收起卡片
/// 2. 「起点 A」「终点 B」为追踪按钮：激活后拖动进度条/播放时实时写入点位
/// 3. 每行支持点击时间手动输入、取「当前」位置、单独「清除」
class AbLoopCard extends StatelessWidget {
  const AbLoopCard({required this.controller, this.onClose, super.key});

  final PlPlayerController controller;

  /// 关闭卡片的行为；为空时使用播放器内嵌面板的显隐开关
  final VoidCallback? onClose;

  static String _fmt(int seconds) =>
      seconds < 0 ? '未设置' : DurationUtils.formatDuration(seconds);

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Material(
      clipBehavior: Clip.hardEdge,
      color: colorScheme.surfaceContainerHigh,
      borderRadius: const BorderRadius.all(Radius.circular(12)),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Obx(() {
              final enabled = controller.abLoopEnabled.value;
              return Row(
                children: [
                  Icon(
                    Icons.repeat,
                    size: 18,
                    color: enabled
                        ? colorScheme.primary
                        : colorScheme.onSurface,
                  ),
                  const SizedBox(width: 6),
                  Text('片段循环', style: theme.textTheme.titleSmall),
                  const Spacer(),
                  if (enabled)
                    Text(
                      '循环中',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colorScheme.primary,
                      ),
                    ),
                  IconButton(
                    tooltip: '关闭',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: onClose ?? controller.toggleAbLoopPanel,
                  ),
                ],
              );
            }),
            Obx(() {
              final tracking = controller.abLoopTracking.value;
              if (tracking == 0) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  tracking == 1
                      ? '正在追踪起点 A：拖动进度条或播放，点值实时更新，再点一次取消'
                      : '正在追踪终点 B：拖动进度条或播放，点值实时更新，再点一次取消',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.primary,
                  ),
                ),
              );
            }),
            Obx(
              () => _buildPointRow(
                context,
                label: '起点 A',
                tracking: controller.abLoopTracking.value == 1,
                value: controller.abLoopStart.value,
                onToggleTracking: () => controller.toggleAbLoopTracking(1),
                onInput: () => _editTime(
                  context: context,
                  title: '设置起点 A',
                  initial: controller.abLoopStart.value,
                  onConfirm: controller.setAbLoopStart,
                ),
                onUseCurrent: controller.setAbLoopStart,
                onClear: () {
                  controller.abLoopStart.value = -1;
                  if (controller.abLoopTracking.value == 1) {
                    controller.abLoopTracking.value = 0;
                  }
                },
              ),
            ),
            const SizedBox(height: 6),
            Obx(
              () => _buildPointRow(
                context,
                label: '终点 B',
                tracking: controller.abLoopTracking.value == 2,
                value: controller.abLoopEnd.value,
                onToggleTracking: () => controller.toggleAbLoopTracking(2),
                onInput: () => _editTime(
                  context: context,
                  title: '设置终点 B',
                  initial: controller.abLoopEnd.value,
                  onConfirm: controller.setAbLoopEnd,
                ),
                onUseCurrent: controller.setAbLoopEnd,
                onClear: () {
                  controller.abLoopEnd.value = -1;
                  if (controller.abLoopTracking.value == 2) {
                    controller.abLoopTracking.value = 0;
                  }
                },
              ),
            ),
            const SizedBox(height: 10),
            Obx(
              () => SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: controller.abLoopReady
                      ? controller.toggleAbLoop
                      : null,
                  icon: Icon(
                    controller.abLoopEnabled.value
                        ? Icons.stop_circle_outlined
                        : Icons.play_circle_outline,
                    size: 18,
                  ),
                  label: Text(controller.abLoopEnabled.value ? '停止' : '开始'),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Obx(
              () => Text(
                controller.abLoopReady
                    ? '循环区间：${_fmt(controller.abLoopStart.value)} - ${_fmt(controller.abLoopEnd.value)}'
                    : '提示：点击「起点 A」/「终点 B」按钮进入追踪模式，拖动进度条选取；也可点击时间手动输入',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPointRow(
    BuildContext context, {
    required String label,
    required bool tracking,
    required int value,
    required VoidCallback onToggleTracking,
    required VoidCallback onInput,
    required VoidCallback onUseCurrent,
    required VoidCallback onClear,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Row(
      children: [
        InkWell(
          onTap: onToggleTracking,
          borderRadius: const BorderRadius.all(Radius.circular(8)),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: tracking
                  ? colorScheme.primaryContainer
                  : colorScheme.surfaceContainerHighest,
              borderRadius: const BorderRadius.all(Radius.circular(8)),
              border: Border.all(
                color: tracking ? colorScheme.primary : Colors.transparent,
              ),
            ),
            child: Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: tracking
                    ? colorScheme.onPrimaryContainer
                    : colorScheme.onSurface,
                fontWeight: tracking ? FontWeight.w600 : null,
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: InkWell(
            onTap: onInput,
            borderRadius: const BorderRadius.all(Radius.circular(8)),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: const BorderRadius.all(Radius.circular(8)),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.schedule,
                    size: 14,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    _fmt(value),
                    style: theme.textTheme.labelLarge,
                  ),
                ],
              ),
            ),
          ),
        ),
        TextButton(
          onPressed: onUseCurrent,
          child: const Text('当前'),
        ),
        TextButton(onPressed: onClear, child: const Text('清除')),
      ],
    );
  }
}
