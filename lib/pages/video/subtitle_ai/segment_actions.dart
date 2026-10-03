import 'package:PiliPlus/pages/video/subtitle_ai/settings_sheet.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/services/local_subtitle/live_subtitle_session.dart';
import 'package:PiliPlus/services/local_subtitle/local_subtitle_service.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:material_ui/material_ui.dart';

/// 长按字幕单条后的操作：复制或编辑（原文与译文）。
Future<void>? showSegmentActions(
  BuildContext context, {
  required LiveSubtitleSession session,
  required PlPlayerController playerController,
  required LocalSubtitleSegment segment,
}) {
  return showSubtitleBottomSheet(
    context,
    playerController: playerController,
    child: _SegmentActionSheet(
      session: session,
      playerController: playerController,
      segment: segment,
    ),
  );
}

class _SegmentActionSheet extends StatelessWidget {
  const _SegmentActionSheet({
    required this.session,
    required this.playerController,
    required this.segment,
  });

  final LiveSubtitleSession session;
  final PlPlayerController playerController;
  final LocalSubtitleSegment segment;

  String get _copyText {
    final translated = segment.translated;
    if (translated == null || translated.isEmpty) {
      return segment.text;
    }
    return '${segment.text}\n$translated';
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
            '字幕 ${_fmtTime(segment.from)}',
            style: Theme.of(context).textTheme.titleSmall,
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
            title: const Text('编辑'),
            subtitle: const Text('修改识别出的原文和翻译'),
            onTap: () {
              Navigator.of(context).maybePop();
              showSubtitleBottomSheet(
                context,
                playerController: playerController,
                child: _SegmentEditSheet(session: session, segment: segment),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _SegmentEditSheet extends StatefulWidget {
  const _SegmentEditSheet({required this.session, required this.segment});

  final LiveSubtitleSession session;
  final LocalSubtitleSegment segment;

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
    widget.session.updateSegment(
      from: widget.segment.from,
      to: widget.segment.to,
      text: text,
      translated: translated.isEmpty ? null : translated,
    );
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
            '编辑字幕 ${_fmtTime(widget.segment.from)}',
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
  final s = seconds.toInt();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}
