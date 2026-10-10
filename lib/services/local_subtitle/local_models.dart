import 'package:whisper_ggml/whisper_ggml.dart';

/// 应用层可选的本地识别模型描述。
///
/// 覆盖 whisper.cpp 标准模型（tiny/base/small/medium/large-v3）与扩展模型
/// （large-v3-turbo、量化 q5/q8）。下载地址、文件名、体积以本结构为准。
///
/// [arch] 是传给 whisper_ggml 的占位枚举：插件 `Whisper.transcribe` 实际按我们
/// 传入的 `modelPath` 加载权重，枚举仅用于插件构造与日志，因此自定义模型可安全
/// 复用同架构的枚举。
class LocalModel {
  const LocalModel({
    required this.id,
    required this.label,
    required this.url,
    required this.expectedBytes,
    required this.arch,
    this.hint,
  });

  /// 稳定标识，同时用作下载状态键与文件名 stem（`ggml-<id>.bin`）。
  final String id;

  /// UI 展示名。
  final String label;

  /// 下载地址（HuggingFace `ggerganov/whisper.cpp`）。
  final String url;

  /// 完整文件预期字节数，用于完整性/损坏校验（识别时允许 10% 余量）。
  final int expectedBytes;

  /// 传给 whisper_ggml 的占位模型枚举。
  final WhisperModel arch;

  /// 可选补充说明（如「量化」「推荐」）。
  final String? hint;

  /// 模型文件名。
  String get fileName => 'ggml-$id.bin';

  Uri get uri => Uri.parse(url);

  @override
  bool operator ==(Object other) => other is LocalModel && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

const String _hfBase =
    'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/';

const LocalModel _baseModel = LocalModel(
  id: 'base',
  label: 'base (推荐, 约140MB)',
  url: '${_hfBase}ggml-base.bin',
  expectedBytes: 147951465,
  arch: WhisperModel.base,
);

/// 全部可选识别模型。索引顺序即设置项的持久化顺序，
/// 新增模型只能追加，避免已有用户的选择被错位。
const List<LocalModel> kLocalModels = [
  LocalModel(
    id: 'tiny',
    label: 'tiny (最快, 约75MB)',
    url: '${_hfBase}ggml-tiny.bin',
    expectedBytes: 77691713,
    arch: WhisperModel.tiny,
  ),
  _baseModel,
  LocalModel(
    id: 'small',
    label: 'small (更准, 约460MB)',
    url: '${_hfBase}ggml-small.bin',
    expectedBytes: 487601967,
    arch: WhisperModel.small,
  ),
  LocalModel(
    id: 'medium',
    label: 'medium (高准, 约1.5GB)',
    url: '${_hfBase}ggml-medium.bin',
    expectedBytes: 1533763059,
    arch: WhisperModel.medium,
  ),
  LocalModel(
    id: 'large-v3',
    label: 'large-v3 (最佳, 约3GB)',
    url: '${_hfBase}ggml-large-v3.bin',
    expectedBytes: 3095033483,
    arch: WhisperModel.large,
  ),
  LocalModel(
    id: 'large-v3-turbo-q5_0',
    label: 'large-v3-turbo 量化 (又快又准, 约575MB)',
    url: '${_hfBase}ggml-large-v3-turbo-q5_0.bin',
    expectedBytes: 574041195,
    arch: WhisperModel.large,
    hint: 'turbo 解码快，准确度接近 large-v2；量化后体积仅约 575MB',
  ),
  LocalModel(
    id: 'large-v3-turbo-q8_0',
    label: 'large-v3-turbo 量化高清 (更准, 约875MB)',
    url: '${_hfBase}ggml-large-v3-turbo-q8_0.bin',
    expectedBytes: 874188075,
    arch: WhisperModel.large,
    hint: 'turbo 的 q8_0 量化，精度损失更小、体积稍大',
  ),
  LocalModel(
    id: 'small-q5_1',
    label: 'small 量化 (省内存, 约190MB)',
    url: '${_hfBase}ggml-small-q5_1.bin',
    expectedBytes: 190085487,
    arch: WhisperModel.small,
    hint: 'small 的 q5_1 量化，准确度接近原版、体积大幅缩小',
  ),
  LocalModel(
    id: 'base-q5_1',
    label: 'base 量化 (极小, 约60MB)',
    url: '${_hfBase}ggml-base-q5_1.bin',
    expectedBytes: 59707625,
    arch: WhisperModel.base,
    hint: 'base 的 q5_1 量化，体积最小，适合低端设备',
  ),
];

/// 默认模型（base）。
const LocalModel kDefaultLocalModel = _baseModel;

/// 按 id 查找模型，找不到返回 null。
LocalModel? localModelById(String id) {
  for (final m in kLocalModels) {
    if (m.id == id) {
      return m;
    }
  }
  return null;
}
