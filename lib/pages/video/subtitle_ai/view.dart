import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/services/local_subtitle/local_subtitle_service.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/subtitle_ai/segment_actions.dart';
import 'package:PiliPlus/pages/video/subtitle_ai/settings_sheet.dart';

/// 在线视频页「字幕」标签页内容：
/// - 增量识别出的字幕（逐行滚动、双语）
/// - 本地导入的字幕（逐行滚动，展示行为与识别字幕一致，不含翻译）
class SubtitleAiPanel extends StatefulWidget {
  const SubtitleAiPanel({required this.videoDetailController, super.key});

  final VideoDetailController videoDetailController;

  @override
  State<SubtitleAiPanel> createState() => _SubtitleAiPanelState();
}

class _SubtitleAiPanelState extends State<SubtitleAiPanel> {
  VideoDetailController get ctr => widget.videoDetailController;

  /// 展示来源：true=本地导入字幕，false=识别字幕；null 表示按内容自动选择。
  bool? _showImported;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = ctr.liveSubtitleSession;
    return Obx(() {
      final imported = ctr.importedSubtitleSegments;
      final hasImported = imported.isNotEmpty;
      final showImported = hasImported && (_showImported ?? true);
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
                  tooltip: '导入本地字幕文件',
                  icon: const Icon(Icons.upload_file_outlined, size: 20),
                  onPressed: () => ctr.importSubtitleFile(context),
                ),
                IconButton(
                  tooltip: 'AI 字幕设置',
                  icon: const Text(
                    'AI',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
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
          if (hasImported)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Row(
                children: [
                  ChoiceChip(
                    label: Text('识别字幕 ${session.segments.length}'),
                    selected: !showImported,
                    onSelected: (_) => setState(() => _showImported = false),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: Text('导入字幕 ${imported.length}'),
                    selected: showImported,
                    onSelected: (_) => setState(() => _showImported = true),
                  ),
                ],
              ),
            ),
          const Divider(height: 12),
          Expanded(
            child: showImported
                ? _SubtitleList(
                    segments: imported,
                    playerController: ctr.plPlayerController,
                    emptyHint: '导入的字幕会逐行显示在这里',
                  )
                : _SubtitleList(
                    segments: session.segments,
                    playerController: ctr.plPlayerController,
                    emptyHint:
                        '点击「开始识别字幕」后，识别结果会逐行显示在这里\n'
                        '（边播边识别，中文翻译稍后自动补上）',
                    onLongPress: (seg) => showSegmentActions(
                      context,
                      session: session,
                      playerController: ctr.plPlayerController,
                      segment: seg,
                    ),
                  ),
          ),
        ],
      );
    });
  }
}

class _SubtitleList extends StatefulWidget {
  const _SubtitleList({
    required this.segments,
    required this.playerController,
    required this.emptyHint,
    this.onLongPress,
  });

  final RxList<LocalSubtitleSegment> segments;
  final PlPlayerController playerController;
  final String emptyHint;
  final void Function(LocalSubtitleSegment segment)? onLongPress;

  @override
  State<_SubtitleList> createState() => _SubtitleListState();
}

class _SubtitleListState extends State<_SubtitleList> {
  PlPlayerController get playerController => widget.playerController;

  final ScrollController _scroll = ScrollController();
  final Map<int, GlobalKey> _rowKeys = {};
  bool _follow = true;
  int _lastActive = -1;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScrollChanged);
  }

  @override
  void didUpdateWidget(covariant _SubtitleList oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 在「识别字幕」与「导入字幕」之间切换时列表实例不同，重置跟随状态。
    if (!identical(oldWidget.segments, widget.segments)) {
      _rowKeys.clear();
      _lastActive = -1;
      _follow = true;
    }
  }

  void _onScrollChanged() {
    if (!_scroll.hasClients) {
      return;
    }
    final pos = _scroll.position;
    // 用户滚回底部时恢复自动跟随
    if (pos.pixels >= pos.maxScrollExtent - 120) {
      _follow = true;
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScrollChanged);
    _scroll.dispose();
    super.dispose();
  }

  void _maybeFollow(int active, int count) {
    if (active == _lastActive || !_follow || active < 0) {
      return;
    }
    _lastActive = active;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_follow) {
        return;
      }
      final ctx = _rowKeys[active]?.currentContext;
      if (ctx != null) {
        // 歌词式居中：当前行滚动到列表中部
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.5,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  void _onTapSegment(int fromSeconds) {
    // 点击字幕跳转到对应进度，并恢复自动跟随滚动
    _follow = true;
    _lastActive = -1;
    playerController.seekTo(Duration(seconds: fromSeconds));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Obx(() {
      final segments = widget.segments.toList();
      if (segments.isEmpty) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              widget.emptyHint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
        );
      }
      final currentPos = playerController.position.value;
      // 字幕时间偏移开启时视频上的字幕会整体顺延，逐句高亮需同步偏移。
      final delay = playerController.subtitleOffsetEnabled
          ? playerController.subtitleOffset
          : 0.0;
      int active = segments.length - 1;
      for (var i = 0; i < segments.length; i++) {
        if (currentPos >= segments[i].from + delay &&
            currentPos <= segments[i].to + delay + 1) {
          active = i;
          break;
        }
      }
      if (segments.length < _rowKeys.length) {
        _rowKeys.removeWhere((k, _) => k >= segments.length);
      }
      _maybeFollow(active, segments.length);
      return NotificationListener<UserScrollNotification>(
        onNotification: (n) {
          // 用户手动滚动时暂停自动跟随，滚回底部后恢复
          if (n.direction != .idle) {
            _follow = false;
          }
          return false;
        },
        child: ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.symmetric(vertical: 80),
          itemCount: segments.length,
          itemBuilder: (context, index) {
            final seg = segments[index];
            final isActive = index == active;
            final isPassed = currentPos > seg.to + delay + 1;
            return AnimatedOpacity(
              key: _rowKeys.putIfAbsent(index, GlobalKey.new),
              duration: const Duration(milliseconds: 200),
              opacity: isPassed && !isActive ? 0.45 : 1,
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _onTapSegment(seg.from.toInt()),
                onLongPress: widget.onLongPress == null
                    ? null
                    : () => widget.onLongPress!(seg),
                child: Container(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 2,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: isActive
                        ? theme.colorScheme.primaryContainer.withValues(
                            alpha: 0.45,
                          )
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        seg.text,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontSize: isActive ? 16.5 : null,
                          fontWeight: isActive
                              ? FontWeight.w700
                              : FontWeight.w400,
                          color: isActive ? theme.colorScheme.primary : null,
                        ),
                      ),
                      if (seg.translated != null && seg.translated!.isNotEmpty)
                        Text(
                          seg.translated!,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontSize: isActive ? 15 : null,
                            color: theme.colorScheme.primary,
                            fontWeight: isActive
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      );
    });
  }
}
