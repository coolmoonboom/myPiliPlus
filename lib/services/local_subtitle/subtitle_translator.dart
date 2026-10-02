import 'dart:convert';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/services/local_subtitle/subtitle_debug_log.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:dio/dio.dart';

/// 字幕翻译器抽象。
///
/// 在线优先：默认先调用可配置的在线翻译接口（LibreTranslate 兼容协议，
/// 可指向 MyMemory 或端内本地 translator 服务），当在线不可用时回退到
/// 端内离线词库（[GlossaryTranslator]）。如果后续接入真正的端内 NMT 模型
/// （如 NLLB / opus-mt 的 ONNX 模型），只需实现本接口并在
/// [TranslationService.create] 中替换 [GlossaryTranslator] 即可。
abstract class SubtitleTranslator {
  Future<String> translate(String text, {String from = 'fr', String to = 'zh'});
}

enum TranslationProvider {
  /// 自动：在线翻译接口优先，离线词库兜底
  glossary,

  /// 仅在线翻译接口
  http,
}

class TranslationSettings {
  const TranslationSettings({
    required this.provider,
    this.endpoint,
    this.apiKey,
  });

  final TranslationProvider provider;

  /// 在线接口地址。为空时使用免费的 MyMemory 公共接口。
  final String? endpoint;

  final String? apiKey;

  static TranslationSettings load() {
    final box = GStorage.setting;
    final index = box.get(SettingBoxKey.translationProvider, defaultValue: 0);
    return TranslationSettings(
      provider: TranslationProvider.values[
          index.clamp(0, TranslationProvider.values.length - 1)],
      endpoint: box.get(SettingBoxKey.translationEndpoint) as String?,
      apiKey: box.get(SettingBoxKey.translationApiKey) as String?,
    );
  }

  void save() {
    final box = GStorage.setting;
    box.put(SettingBoxKey.translationProvider, provider.index);
    box.put(SettingBoxKey.translationEndpoint, endpoint);
    box.put(SettingBoxKey.translationApiKey, apiKey);
  }
}

abstract final class TranslationService {
  /// 根据设置创建翻译器；默认「在线优先 + 本地词库兜底」。
  static SubtitleTranslator create([TranslationSettings? settings]) {
    final config = settings ?? TranslationSettings.load();
    if (config.provider == TranslationProvider.glossary) {
      return _FallbackTranslator(
        primary: HttpSubtitleTranslator(
          endpoint: config.endpoint,
          apiKey: config.apiKey,
        ),
        fallback: GlossaryTranslator(),
      );
    }
    return HttpSubtitleTranslator(
      endpoint: config.endpoint,
      apiKey: config.apiKey,
    );
  }
}

/// 当主翻译器失败或未产出有效结果时回退到 [fallback]。
class _FallbackTranslator implements SubtitleTranslator {
  _FallbackTranslator({required this.primary, required this.fallback});

  final SubtitleTranslator primary;
  final SubtitleTranslator fallback;

  @override
  Future<String> translate(String text, {String from = 'fr', String to = 'zh'}) async {
    try {
      final result = await primary.translate(text, from: from, to: to);
      if (result.trim().isNotEmpty && result.trim() != text.trim()) {
        return result;
      }
    } catch (_) {
      // ignore and fall through to fallback
    }
    try {
      return await fallback.translate(text, from: from, to: to);
    } catch (_) {
      return text;
    }
  }
}

/// 端内离线词库翻译器。
///
/// 基于内置法语-中文常用词/短语表做贪心最长匹配替换。
/// 这是完全离线可用的兜底实现，句子级质量有限；接入端内 NMT 模型后可替换。
class GlossaryTranslator implements SubtitleTranslator {
  @override
  Future<String> translate(
    String text, {
    String from = 'fr',
    String to = 'zh',
  }) async {
    var result = text.trim();
    if (result.isEmpty) {
      return result;
    }
    final lower = result.toLowerCase();
    // 长词优先，避免短词覆盖长词
    final entries = _glossary.entries.toList()
      ..sort((a, b) => b.key.length.compareTo(a.key.length));
    for (final entry in entries) {
      final key = entry.key;
      var index = lower.indexOf(key);
      if (index == -1) {
        continue;
      }
      // 使用正则按词边界替换，避免破坏法语单词
      final pattern = RegExp(
        '(?<![\\p{L}])${RegExp.escape(key)}(?![\\p{L}])',
        caseSensitive: false,
        unicode: true,
      );
      result = result.replaceAll(pattern, entry.value);
    }
    return result;
  }

  /// 高频法语词/短语 -> 中文（可自行扩充，或替换为端内模型）
  static const Map<String, String> _glossary = {
    'bonjour': '你好',
    'bonsoir': '晚上好',
    'salut': '嗨',
    'merci': '谢谢',
    'merci beaucoup': '非常感谢',
    'de rien': '不客气',
    's\'il vous plaît': '请',
    's\'il te plaît': '请',
    'pardon': '抱歉',
    'excusez-moi': '打扰一下',
    'au revoir': '再见',
    'à bientôt': '回头见',
    'oui': '是',
    'non': '不',
    'peut-être': '也许',
    'bien sûr': '当然',
    'd\'accord': '好的',
    'bonne chance': '祝你好运',
    'bonne journée': '祝你今天愉快',
    'je': '我',
    'tu': '你',
    'vous': '您',
    'il': '他',
    'elle': '她',
    'nous': '我们',
    'ils': '他们',
    'elles': '她们',
    'et': '和',
    'ou': '或者',
    'mais': '但是',
    'parce que': '因为',
    'donc': '所以',
    'si': '如果',
    'quand': '当',
    'où': '哪里',
    'comment': '怎样',
    'pourquoi': '为什么',
    'qui': '谁',
    'quoi': '什么',
    'très': '非常',
    'bien': '好',
    'mal': '不好',
    'beaucoup': '很多',
    'un peu': '一点',
    'toujours': '总是',
    'jamais': '从不',
    'maintenant': '现在',
    'aujourd\'hui': '今天',
    'demain': '明天',
    'hier': '昨天',
    'ici': '这里',
    'là': '那里',
    'temps': '时间',
    'jour': '天',
    'nuit': '夜晚',
    'matin': '早上',
    'soir': '晚上',
    'eau': '水',
    'pain': '面包',
    'café': '咖啡',
    'restaurant': '餐厅',
    'maison': '家',
    'école': '学校',
    'travail': '工作',
    'ami': '朋友',
    'famille': '家人',
    'monde': '世界',
    'vie': '生活',
    'amour': '爱',
    'français': '法语',
    'française': '法国的',
    'chinois': '中文',
    'chinoise': '中国的',
    'langue': '语言',
    'mot': '单词',
    'phrase': '句子',
    'apprendre': '学习',
    'étudier': '学习',
    'parler': '说',
    'écouter': '听',
    'regarder': '看',
    'comprendre': '理解',
    'savoir': '知道',
    'penser': '认为',
    'vouloir': '想要',
    'pouvoir': '能够',
    'devoir': '必须',
    'faire': '做',
    'aller': '去',
    'venir': '来',
    'voir': '看见',
    'dire': '说',
    'être': '是',
    'avoir': '有',
    'aimer': '喜欢',
    'bon': '好的',
    'grand': '大的',
    'petit': '小的',
    'nouveau': '新的',
    'vieux': '旧的',
    'beau': '美的',
    'content': '高兴的',
    'triste': '悲伤的',
    'facile': '容易的',
    'difficile': '困难的',
    'rapide': '快的',
    'lent': '慢的',
    'chaud': '热的',
    'froid': '冷的',
    'un': '一',
    'deux': '二',
    'trois': '三',
    'quatre': '四',
    'cinq': '五',
    'six': '六',
    'sept': '七',
    'huit': '八',
    'neuf': '九',
    'dix': '十',
    'cent': '百',
    'mille': '千',
  };
}

/// 在线翻译器。
///
/// - [endpoint] 为空时使用 MyMemory 免费接口（无需 key）。
/// - 提供 [endpoint] 时按 LibreTranslate 兼容协议 POST JSON。
class HttpSubtitleTranslator implements SubtitleTranslator {
  HttpSubtitleTranslator({this.endpoint, this.apiKey});

  final String? endpoint;
  final String? apiKey;

  @override
  Future<String> translate(
    String text, {
    String from = 'fr',
    String to = 'zh',
  }) async {
    final value = text.trim();
    if (value.isEmpty) {
      return value;
    }
    final target = _normalizeTarget(to);
    try {
      if (endpoint == null || endpoint!.isEmpty) {
        final res = await Request.dio.get(
          'https://api.mymemory.translated.net/get',
          queryParameters: {
            'q': value,
            'langpair': '$from|$target',
          },
          options: Options(
            connectTimeout: const Duration(seconds: 6),
            receiveTimeout: const Duration(seconds: 8),
          ),
        );
        final data = res.data;
        if (data is Map && data['responseData'] case final Map rd) {
          final translated = rd['translatedText']?.toString();
          if (translated != null && translated.trim().isNotEmpty) {
            return translated;
          }
        }
        return value;
      }

      final res = await Request.dio.post(
        endpoint!,
        data: {
          'q': value,
          'source': from,
          'target': target,
          'format': 'text',
          if (apiKey != null && apiKey!.isNotEmpty) 'api_key': apiKey,
        },
        options: Options(
          connectTimeout: const Duration(seconds: 6),
          receiveTimeout: const Duration(seconds: 8),
        ),
      );
      final data = res.data;
      if (data is Map) {
        final translated = data['translatedText']?.toString();
        if (translated != null && translated.trim().isNotEmpty) {
          return translated;
        }
      } else if (data is String && data.isNotEmpty) {
        try {
          final decoded = jsonDecode(data);
          if (decoded is Map && decoded['translatedText'] case final String t) {
            return t;
          }
        } catch (_) {}
      }
      return value;
    } catch (e) {
      SubtitleDebugLog.instance.log(
        '在线翻译失败（回退词库）：$value => $e',
      );
      return value;
    }
  }

  String _normalizeTarget(String to) {
    switch (to) {
      case 'zh':
      case 'zh-CN':
      case 'zh-cn':
        return 'zh-CN';
      default:
        return to;
    }
  }
}
