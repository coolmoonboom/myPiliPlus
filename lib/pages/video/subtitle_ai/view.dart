import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/services/local_subtitle/incremental_recognizer.dart';
import 'package:PiliPlus/services/local_subtitle/live_subtitle_session.dart';
import 'package:PiliPlus/services/local_subtitle/local_subtitle_service.dart';
import 'package:get/get.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
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
                  tooltip: '导入字幕文件 / 存档 zip',
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
                  tooltip: '导出字幕存档 (zip)',
                  icon: const Icon(Icons.save_alt, size: 20),
                  onPressed: ctr.exportSubtitleArchive,
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
          if (!showImported)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: _CoverageBar(
                session: session,
                playerController: ctr.plPlayerController,
              ),
            ),
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
                    onLongPress: (seg) => showSegmentActions(
                      context,
                      playerController: ctr.plPlayerController,
                      segment: seg,
                      onEdit: (text, translated) => ctr.updateImportedSegment(
                        seg,
                        text: text,
                        translated: translated,
                      ),
                    ),
                  )
                : _SubtitleList(
                    segments: session.segments,
                    playerController: ctr.plPlayerController,
                    emptyHint:
                        '点击「开始识别字幕」后，识别结果会逐行显示在这里\n'
                        '（边播边识别，中文翻译稍后自动补上）',
                    onLongPress: (seg) => showSegmentActions(
                      context,
                      playerController: ctr.plPlayerController,
                      segment: seg,
                      onEdit: (text, translated) => Future.sync(
                        () => session.updateSegment(
                          from: seg.from,
                          to: seg.to,
                          text: text,
                          translated: translated,
                        ),
                      ),
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
  int _lastActive = -2;
  bool _hasPositioned = false;
  bool _wasDragging = false;
  /// 用户手动滑动列表后，在此时间点之前暂停自动滚动（高亮不受影响）。
  DateTime? _userScrollUntil;

  @override
  void didUpdateWidget(covariant _SubtitleList oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 在「识别字幕」与「导入字幕」之间切换时列表实例不同，重置跟随状态。
    if (!identical(oldWidget.segments, widget.segments)) {
      _rowKeys.clear();
      _lastActive = -2;
      _hasPositioned = false;
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 歌词式跟随：只要当前句变化，就把该句滚动到列表中部。
  ///
  /// 列表按需构建，远距离的目标行可能尚未生成（拿不到 context），
  /// 此时先按平均行高估算位置跳过去，下一帧目标行生成后再精确居中。
  void _maybeFollow(int active) {
    // 拖动「精细调控」滑块时暂停跟随，松手 2 秒后才恢复（见 begin/endSubtitleOffsetDrag）。
    if (playerController.subtitleOffsetDragging) {
      return;
    }
    // 用户手动滑动列表后 5 秒内先不自动滚动；高亮仍会逐句更新。
    final until = _userScrollUntil;
    if (until != null && DateTime.now().isBefore(until)) {
      return;
    }
    if (active < 0 || active == _lastActive) {
      return;
    }
    _lastActive = active;
    WidgetsBinding.instance.addPostFrameCallback((_) => _followTo(active, 0));
  }

  bool _onScrollNotification(ScrollNotification notification) {
    // 仅用户拖动产生的通知带 dragDetails；程序 animateTo/jumpTo 为 null，不会被误判。
    final dragging =
        (notification is ScrollStartNotification &&
            notification.dragDetails != null) ||
        (notification is ScrollUpdateNotification &&
            notification.dragDetails != null) ||
        (notification is ScrollEndNotification &&
            notification.dragDetails != null);
    if (dragging) {
      _userScrollUntil = DateTime.now().add(const Duration(seconds: 5));
    }
    return false;
  }

  void _followTo(int index, int attempt) {
    if (!mounted || attempt > 4) {
      return;
    }
    if (!_scroll.hasClients) {
      return;
    }
    final pos = _scroll.position;
    final ctx = _rowKeys[index]?.currentContext;
    final row = ctx?.findRenderObject();
    if (row is RenderBox && row.attached) {
      // 只滚动列表自身的 ScrollController：取「行相对内层视口」的目标偏移，
      // 避免用 Scrollable.ensureVisible（它会连带滚动外层 TabBarView 切回本 tab）。
      final target = RenderAbstractViewport.of(row)
          .getOffsetToReveal(row, 0.5)
          .offset
          .clamp(0.0, pos.maxScrollExtent)
          .toDouble();
      if (_hasPositioned) {
        pos.animateTo(
          target,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
        );
      } else {
        pos.jumpTo(target);
      }
      _hasPositioned = true;
      return;
    }
    final count = widget.segments.length;
    if (count == 0) {
      return;
    }
    final avgRowHeight = (pos.maxScrollExtent + pos.viewportDimension) / count;
    final target = (avgRowHeight * index - pos.viewportDimension / 2)
        .clamp(0.0, pos.maxScrollExtent)
        .toDouble();
    pos.jumpTo(target);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _followTo(index, attempt + 1),
    );
  }

  void _onTapSegment(int fromSeconds) {
    // 点击字幕跳转到对应进度，并恢复歌词式跟随
    _lastActive = -2;
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
      int active = -1;
      for (var i = 0; i < segments.length; i++) {
        if (currentPos >= segments[i].from + delay) {
          active = i;
        } else {
          break;
        }
      }
      if (segments.length < _rowKeys.length) {
        _rowKeys.removeWhere((k, _) => k >= segments.length);
      }
      // 读取拖动状态会订阅该 Rx：松手满 2 秒后其翻转会触发本 Obx 重建。
      final dragging = playerController.subtitleOffsetDragging;
      if (_wasDragging && !dragging) {
        // 恢复跟随时强制重新定位到当前句。
        _lastActive = -2;
      }
      _wasDragging = dragging;
      _maybeFollow(active);
      final list = ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.symmetric(vertical: 80),
        itemCount: segments.length,
        itemBuilder: (context, index) {
          final seg = segments[index];
          final isActive = index == active;
          final isPassed = currentPos > seg.to + delay + 1;
          // 字幕叠加偏移后实际出现的时间点：延后（delay>0）则加，提前则减。
          final shiftedFrom = (seg.from + delay)
              .clamp(0, double.infinity)
              .toDouble();
          return AnimatedOpacity(
            key: _rowKeys.putIfAbsent(index, GlobalKey.new),
            duration: const Duration(milliseconds: 200),
            opacity: isPassed && !isActive ? 0.45 : 1,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _onTapSegment(shiftedFrom.toInt()),
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
                      _fmtClock(shiftedFrom),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                    const SizedBox(height: 2),
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
      );
      return NotificationListener<ScrollNotification>(
        onNotification: _onScrollNotification,
        child: list,
      );
    });
  }
}

/// 识别覆盖进度条：按已识别时间区间着色，红点标记当前播放位置。
///
/// 让用户在拖动进度条后一眼看出哪些时间段已有字幕、哪些还在补。
class _CoverageBar extends StatelessWidget {
  const _CoverageBar({required this.session, required this.playerController});

  final LiveSubtitleSession session;
  final PlPlayerController playerController;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Obx(() {
      final total = playerController.duration.value;
      final ranges = session.coverage.toList();
      final running = session.running.value;
      if (total <= 0 || (ranges.isEmpty && !running)) {
        return const SizedBox.shrink();
      }
      final pos = (playerController.position.value / total).clamp(0.0, 1.0);
      return LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          return SizedBox(
            height: 6,
            child: Stack(
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
                for (final r in ranges)
                  Positioned(
                    left: (r.fromSeconds / total).clamp(0.0, 1.0) * w,
                    width: ((r.toSeconds - r.fromSeconds) / total).clamp(
                          0.0,
                          1.0,
                        ) *
                        w,
                    top: 0,
                    bottom: 0,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.65),
                      ),
                    ),
                  ),
                Positioned(
                  left: (pos * w - 1).clamp(0.0, (w - 2).clamp(0.0, w)),
                  top: 0,
                  bottom: 0,
                  child: Container(width: 2, color: theme.colorScheme.error),
                ),
              ],
            ),
          );
        },
      );
    });
  }
}

/// 把秒数格式化为「分:秒」，用于字幕列表逐句时间展示。
String _fmtClock(double seconds) {
  final total = seconds < 0 ? 0 : seconds.toInt();
  final m = total ~/ 60;
  final s = total % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}
