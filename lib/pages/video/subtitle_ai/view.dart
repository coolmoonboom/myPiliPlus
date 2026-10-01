import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/services/local_subtitle/live_subtitle_session.dart';
import 'package:PiliPlus/services/local_subtitle/local_subtitle_service.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/subtitle_ai/settings_sheet.dart';

/// 在线视频页「字幕」标签页内容：展示增量识别出的字幕（逐行滚动、双语）。
class SubtitleAiPanel extends StatefulWidget {
  const SubtitleAiPanel({required this.videoDetailController, super.key});

  final VideoDetailController videoDetailController;

  @override
  State<SubtitleAiPanel> createState() => _SubtitleAiPanelState();
}

class _SubtitleAiPanelState extends State<SubtitleAiPanel> {
  VideoDetailController get ctr => widget.videoDetailController;

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = ctr.liveSubtitleSession;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Obx(() {
                  final running = session.running.value;
                  return FilledButton.tonalIcon(
                    onPressed: running ? session.stop : session.start,
                    icon: Icon(running ? Icons.stop : Icons.mic),
                    label: Text(running ? '停止识别' : '开始识别字幕'),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  );
                }),
              ),
              IconButton(
                tooltip: 'AI 字幕设置',
                icon: const Icon(Icons.settings_outlined, size: 20),
                onPressed: () => showSubtitleBottomSheet(
                  context,
                  playerController: ctr.plPlayerController,
                  child: AiSubtitleSettingsSheet(videoDetailController: ctr),
                ),
              ),
              IconButton(
                tooltip: '保存为 SRT',
                icon: const Icon(Icons.save_alt, size: 20),
                onPressed: session.exportSrt,
              ),
            ],
          ),
        ),
        Obx(() {
          final running = session.running.value;
          if (running) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      session.stage.value,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }
          return const SizedBox.shrink();
        }),
        const Divider(height: 12),
        Expanded(
          child: _SubtitleList(
            session: session,
            playerController: ctr.plPlayerController,
          ),
        ),
      ],
    );
  }
}

class _SubtitleList extends StatelessWidget {
  const _SubtitleList({required this.session, required this.playerController});

  final LiveSubtitleSession session;
  final PlPlayerController playerController;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Obx(() {
      final segments = session.segments.toList();
      if (segments.isEmpty) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '点击「开始识别字幕」后，识别结果会逐行显示在这里\n'
              '（边播边识别，覆盖播放位置前后约 20 秒）',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
        );
      }
      final currentPos = playerController.position.value;
      int active = segments.length - 1;
      for (var i = 0; i < segments.length; i++) {
        if (currentPos >= segments[i].from &&
            currentPos <= segments[i].to + 1) {
          active = i;
          break;
        }
      }
      return ListView.builder(
        itemCount: segments.length,
        itemBuilder: (context, index) {
          final seg = segments[index];
          final isActive = index == active;
          final isPassed = currentPos > seg.to + 1;
          return AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: isPassed && !isActive ? 0.5 : 1,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: isActive
                    ? theme.colorScheme.primaryContainer
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    seg.text,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: isActive ? FontWeight.w600 : null,
                    ),
                  ),
                  if (seg.translated != null && seg.translated!.isNotEmpty)
                    Text(
                      seg.translated!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      );
    });
  }
}
