import 'package:PiliPlus/pages/video/subtitle_ai/settings_sheet.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/services/local_subtitle/local_subtitle_service.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';

/// 长按字幕单条后的操作：在此定轴、复制、修改或循环该句。
Future<void>? showSegmentActions(
  BuildContext context, {
  required PlPlayerController playerController,
  required LocalSubtitleSegment segment,
  required Future<void> Function(String text, String? translated) onEdit,
}) {
  return showSubtitleBottomSheet(
    context,
    playerController: playerController,
    child: _SegmentActionSheet(
      playerController: playerController,
      segment: segment,
      onEdit: onEdit,
    ),
  );
}

class _SegmentActionSheet extends StatelessWidget {
  const _SegmentActionSheet({
    required this.playerController,
    required this.segment,
    required this.onEdit,
  });

  final PlPlayerController playerController;
  final LocalSubtitleSegment segment;
  final Future<void> Function(String text, String? translated) onEdit;

  String get _copyText {
    final translated = segment.translated;
    if (translated == null || translated.isEmpty) {
      return segment.text;
    }
    return '${segment.text}\n$translated';
  }

  /// 字幕偏移开启时，弹窗展示与循环都应使用叠加偏移后的实际时间。
  double get _delay => playerController.subtitleOffsetEnabled
      ? playerController.subtitleOffset
      : 0.0;

  /// 在此定轴：以当前播放位置对齐这句字幕，整条字幕轨随之整体平移。
  void _relocateHere(BuildContext context) {
    Navigator.of(context).maybePop();
    final offset = playerController.position.value - segment.from;
    playerController
      ..subtitleOffset = offset
      ..subtitleOffsetEnabled = true
      ..applySubtitleDelay();
    SmartDialog.showToast('已在此定轴');
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '字幕 ${_fmtTime(segment.from + _delay)}',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.gps_fixed_outlined, size: 20),
            title: const Text('在此定轴'),
            subtitle: const Text('以当前播放位置对齐这句，其余字幕整体跟着对齐'),
            onTap: () => _relocateHere(context),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.copy_all_outlined, size: 20),
            title: const Text('复制'),
            subtitle: const Text('复制这句原文与译文'),
            onTap: () {
              Navigator.of(context).maybePop();
              Utils.copyText(_copyText);
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.edit_outlined, size: 20),
            title: const Text('修改'),
            subtitle: const Text('修改这句原文和翻译'),
            onTap: () {
              Navigator.of(context).maybePop();
              showSubtitleBottomSheet(
                context,
                playerController: playerController,
                child: _SegmentEditSheet(
                  segment: segment,
                  delay: _delay,
                  onSave: onEdit,
                ),
              );
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.repeat, size: 20),
            title: const Text('循环该句'),
            subtitle: const Text('把这句字幕设为片段循环并立即开始'),
            onTap: () {
              Navigator.of(context).maybePop();
              final from = (segment.from + _delay).round();
              final shiftedTo = segment.to + _delay;
              final to = shiftedTo.ceil() > from ? shiftedTo.ceil() : from + 1;
              playerController.setAbLoopStart(from);
              playerController.setAbLoopEnd(to);
              playerController.setAbLoopEnabled(true);
              SmartDialog.showToast('已循环播放该句');
            },
          ),
        ],
      ),
    );
  }
}

class _SegmentEditSheet extends StatefulWidget {
  const _SegmentEditSheet({
    required this.segment,
    required this.delay,
    required this.onSave,
  });

  final LocalSubtitleSegment segment;

  /// 字幕偏移（秒），仅用于标题时间展示。
  final double delay;

  final Future<void> Function(String text, String? translated) onSave;

  @override
  State<_SegmentEditSheet> createState() => _SegmentEditSheetState();
}

class _SegmentEditSheetState extends State<_SegmentEditSheet> {
  late final TextEditingController _textCtrl = TextEditingController(
    text: widget.segment.text,
  );
  late final TextEditingController _translatedCtrl = TextEditingController(
    text: widget.segment.translated ?? '',
  );

  @override
  void dispose() {
    _textCtrl.dispose();
    _translatedCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) {
      return;
    }
    final translated = _translatedCtrl.text.trim();
    widget.onSave(text, translated.isEmpty ? null : translated);
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '编辑字幕 ${_fmtTime(widget.segment.from + widget.delay)}',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _textCtrl,
            maxLines: 3,
            minLines: 1,
            decoration: const InputDecoration(
              labelText: '识别原文',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _translatedCtrl,
            maxLines: 3,
            minLines: 1,
            decoration: const InputDecoration(
              labelText: '中文翻译（可留空）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: const Text('取消'),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _save, child: const Text('保存')),
            ],
          ),
        ],
      ),
    );
  }
}

String _fmtTime(double seconds) {
  final total = seconds < 0 ? 0 : seconds.toInt();
  return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
}
