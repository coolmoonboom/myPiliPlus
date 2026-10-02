import 'dart:io';

import 'package:PiliPlus/http/init.dart';
import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

enum ModelTaskState { idle, downloading, paused, done, corrupt }

/// 模型文件校验结果（用于诊断「文件存在但加载失败」）。
class ModelValidation {
  const ModelValidation({
    required this.exists,
    required this.size,
    this.valid = false,
    this.magic,
  });

  final bool exists;
  final int size;
  final bool valid;

  /// 文件头 4 字节的十六进制（如 `6c6d6767` = ggml，`47475546` = GGUF）
  final String? magic;
}

class ModelState {
  const ModelState({
    required this.state,
    this.received = 0,
    this.total = 0,
    this.error,
  });

  final ModelTaskState state;
  final int received;
  final int total;
  final String? error;

  double? get progress => total > 0 ? received / total : null;

  static const ModelState unknown = ModelState(state: ModelTaskState.idle);
  static const ModelState downloaded = ModelState(state: ModelTaskState.done);
}

/// Whisper 模型下载管理：断点续传、暂停/继续、删除。
/// App 进入后台时自动暂停进行中的下载（由 AppHandler 调用 pauseAll）。
class ModelManager {
  ModelManager._() {
    _initStates();
  }

  /// 全局单例
  static final ModelManager instance = ModelManager._();

  static const List<WhisperModel> managedModels = [
    WhisperModel.tiny,
    WhisperModel.base,
    WhisperModel.small,
    WhisperModel.medium,
    WhisperModel.large,
  ];

  final RxMap<String, ModelState> states = <String, ModelState>{}.obs;

  final Map<String, CancelToken> _cancelTokens = {};

  /// 合法模型文件的最小体积（最小的 tiny 模型也有几十 MB）
  static const int _minModelBytes = 4 * 1024 * 1024;

  /// 各模型在 HuggingFace `ggerganov/whisper.cpp` 上的标准体积（字节），
  /// 用于识别下载/迁移过程中被截断的文件。识别时允许 10% 的余量。
  static const Map<String, int> _expectedBytes = {
    'tiny': 77691713,
    'base': 147951465,
    'small': 487601967,
    'medium': 1533763059,
    'large-v3': 3095033483,
  };

  int _minExpectedBytes(WhisperModel model) {
    final expected = _expectedBytes[model.modelName] ?? 0;
    final withMargin = expected - expected ~/ 10;
    return withMargin > _minModelBytes ? withMargin : _minModelBytes;
  }

  /// legacy ggml 魔数，小端存储为字节 `6c 6d 67 67`
  static const List<int> _ggmlMagic = [0x6c, 0x6d, 0x67, 0x67];

  /// 新版 GGUF 魔数，字节 `47 47 55 46`（"GGUF"）
  static const List<int> _ggufMagic = [0x47, 0x47, 0x55, 0x46];

  String _key(WhisperModel model) => model.modelName;

  static bool _matchesMagic(List<int> head) {
    if (head.length < 4) {
      return false;
    }
    final ggml = head[0] == _ggmlMagic[0] &&
        head[1] == _ggmlMagic[1] &&
        head[2] == _ggmlMagic[2] &&
        head[3] == _ggmlMagic[3];
    final gguf = head[0] == _ggufMagic[0] &&
        head[1] == _ggufMagic[1] &&
        head[2] == _ggufMagic[2] &&
        head[3] == _ggufMagic[3];
    return ggml || gguf;
  }

  static String? _hexMagic(List<int> head) {
    if (head.length < 4) {
      return null;
    }
    return head
        .take(4)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// 仅检查文件头魔数（用于断点续传的 `.part` 前缀文件）。
  Future<bool> _hasValidMagic(File file) async {
    try {
      if (!await file.exists()) {
        return false;
      }
      final raf = await file.open();
      try {
        return _matchesMagic(await raf.read(4));
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  /// 完整校验：存在、体积达标、魔数正确。
  Future<bool> _isValidModelFile(
    File file, {
    int minBytes = _minModelBytes,
  }) async {
    try {
      if (!await file.exists() || await file.length() < minBytes) {
        return false;
      }
      return await _hasValidMagic(file);
    } catch (_) {
      return false;
    }
  }

  /// 校验某模型文件（供识别前诊断与调试日志使用）。
  Future<ModelValidation> validate(WhisperModel model) async {
    final file = File(await pathOf(model));
    if (!await file.exists()) {
      return const ModelValidation(exists: false, size: 0);
    }
    final size = await file.length();
    final minBytes = _minExpectedBytes(model);
    String? magic;
    var valid = false;
    try {
      final raf = await file.open();
      try {
        final head = await raf.read(4);
        magic = _hexMagic(head);
        valid = size >= minBytes && _matchesMagic(head);
      } finally {
        await raf.close();
      }
    } catch (_) {}
    return ModelValidation(
      exists: true,
      size: size,
      valid: valid,
      magic: magic,
    );
  }

  /// 模型文件存放目录。
  ///
  /// Android 10+ 放到用户可见的 Download/piliplus_models（便于导出/导入/管理）；
  /// 其余平台（含 iOS/macOS 沙盒）回退到应用私有目录。
  static Future<Directory> _baseDir() async {
    if (Platform.isIOS || Platform.isMacOS) {
      return await getLibraryDirectory();
    }
    return await getApplicationSupportDirectory();
  }

  static Future<Directory> _modelDir() async {
    if (Platform.isAndroid) {
      try {
        final downloads = await getDownloadsDirectory();
        if (downloads != null) {
          final dir = Directory('${downloads.path}/piliplus_models');
          await dir.create(recursive: true);
          return dir;
        }
      } catch (_) {}
    }
    final base = await _baseDir();
    return Directory('${base.path}/whisper_models');
  }

  Future<void> _initStates() async {
    for (final model in managedModels) {
      await _migrate(model);
      final v = await validate(model);
      if (!v.exists) {
        continue;
      }
      states[_key(model)] = v.valid
          ? ModelState.downloaded
          : const ModelState(
              state: ModelTaskState.corrupt,
              error: '模型文件损坏或不完整，请重新下载',
            );
    }
  }

  /// 把历史版本下载到应用私有目录的模型迁移到新目录（旧的删掉以释放空间）。
  Future<void> _migrate(WhisperModel model) async {
    final oldPath = await WhisperController().getPath(model);
    final newPath = await pathOf(model);
    if (oldPath == newPath) {
      return;
    }
    try {
      final oldFile = File(oldPath);
      if (await oldFile.exists() && !await File(newPath).exists()) {
        await oldFile.copy(newPath);
        await oldFile.delete();
      }
      final oldPart = File('$oldPath.part');
      if (await oldPart.exists() && !await File('$newPath.part').exists()) {
        await oldPart.copy('$newPath.part');
        await oldPart.delete();
      }
    } catch (_) {}
  }

  Future<String> pathOf(WhisperModel model) async =>
      '${(await _modelDir()).path}/ggml-${model.modelName}.bin';

  Future<String> _partPath(WhisperModel model) async =>
      '${await pathOf(model)}.part';

  bool isDownloading(WhisperModel model) =>
      states[_key(model)]?.state == ModelTaskState.downloading;

  /// 是否已下载（用于识别前快速判断）
  Future<bool> exists(WhisperModel model) async =>
      await File(await pathOf(model)).exists();

  /// 确保模型就绪（未下载则下载并等待完成）。
  ///
  /// 若已有文件但校验失败（损坏/不完整），先删除再重新下载。
  Future<void> ensure(WhisperModel model) async {
    final key = _key(model);
    if (states[key]?.state == ModelTaskState.done) {
      return;
    }
    if (states[key]?.state == ModelTaskState.corrupt) {
      await remove(model);
    }
    download(model);
    await everUntilDone(key);
    final state = states[key];
    if (state?.state != ModelTaskState.done) {
      throw state?.error ?? '模型下载未完成';
    }
  }

  /// 等待某个模型的下载结束（成功、失败或暂停）
  Future<void> everUntilDone(String key) async {
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final state = states[key];
      if (state == null) {
        continue;
      }
      if (state.state == ModelTaskState.done ||
          state.state == ModelTaskState.paused ||
          state.state == ModelTaskState.corrupt ||
          state.state == ModelTaskState.idle) {
        return;
      }
    }
  }

  void download(WhisperModel model) {
    final key = _key(model);
    final current = states[key];
    if (current?.state == ModelTaskState.downloading) {
      return;
    }
    _run(model);
  }

  Future<void> _run(WhisperModel model) async {
    final key = _key(model);
    final cancelToken = CancelToken();
    _cancelTokens[key] = cancelToken;
    await _migrate(model);
    final path = await pathOf(model);
    final partFile = File(await _partPath(model));
    final file = File(path);
    if (await file.exists()) {
      if (await _isValidModelFile(file, minBytes: _minExpectedBytes(model))) {
        states[key] = ModelState.downloaded;
        return;
      }
      // 损坏/不完整的残留文件先删除，避免误判为已下载
      try {
        await file.delete();
      } catch (_) {}
      states[key] = ModelState(
        state: ModelTaskState.paused,
        error: '已删除损坏的模型文件，正在重新下载',
      );
    }
    var received = await partFile.exists() ? await partFile.length() : 0;
    if (received > 0 && !await _hasValidMagic(partFile)) {
      // 断点文件头也不是有效模型，丢弃重下
      try {
        await partFile.delete();
      } catch (_) {}
      received = 0;
    }
    var total = 0;
    states[key] = ModelState(
      state: ModelTaskState.downloading,
      received: received,
    );
    try {
      // 模型走 HTTP/1.1 适配器：HF 下载是 302 跳转到 CDN，HTTP/2 适配器对
      // 流式请求的跳转支持不确定，用 h11 可确保跟随跳转拿到真实文件。
      final response = await Request.http11Dio.get<ResponseBody>(
        model.modelUri.toString(),
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: true,
          maxRedirects: 5,
          headers: {
            // 模型是二进制，强制不压缩，避免 autoUncompress=false 下写入压缩字节
            'accept-encoding': 'identity',
            if (received > 0) 'Range': 'bytes=$received-',
          },
          validateStatus: (status) => status == 206 || status == 200,
          connectTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(seconds: 60),
        ),
      );
      final headers = response.headers;
      var contentLength =
          int.tryParse(headers.value(Headers.contentLengthHeader) ?? '') ?? 0;
      final statusCode = response.statusCode ?? -1;
      if (statusCode == 206) {
        // 优先用 Content-Range 得到真实总大小，比 content-length 更可靠
        final contentRange = headers.value('content-range') ?? '';
        if (contentRange.contains('/')) {
          final full = int.tryParse(contentRange.split('/').last);
          if (full != null && full > 0) {
            contentLength = full - received;
          }
        }
      } else if (received > 0) {
        // 服务器不支持 Range，重新下载
        received = 0;
      }
      total = statusCode == 206 ? received + contentLength : contentLength;
      final sink = partFile.openWrite(
        mode: statusCode == 206 ? FileMode.append : FileMode.write,
      );
      states[key] = ModelState(
        state: ModelTaskState.downloading,
        received: received,
        total: total,
      );
      int lastTick = DateTime.now().millisecondsSinceEpoch;
      final sub = response.data!.stream.listen((chunk) {
        sink.add(chunk);
        received += chunk.length.toInt();
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - lastTick > 250) {
          lastTick = now;
          states[key] = ModelState(
            state: ModelTaskState.downloading,
            received: received,
            total: total,
          );
        }
      }, onDone: sink.flush);
      try {
        await sub.asFuture<void>();
      } finally {
        await sink.flush();
        await sink.close();
      }
      if (total > 0 && received < total) {
        throw '下载不完整（$received/$total）';
      }
      if (!await _isValidModelFile(
        partFile,
        minBytes: _minExpectedBytes(model),
      )) {
        throw '模型文件校验失败（请检查网络后重试）';
      }
      await partFile.rename(path);
      states[key] = const ModelState(
        state: ModelTaskState.done,
        received: -1,
        total: -1,
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        // pause() 已写入 paused 状态；主动取消则回到空闲
        final state = states[key];
        if (state?.state == ModelTaskState.downloading) {
          states[key] = ModelState(
            state: ModelTaskState.idle,
            received: received,
            total: total,
          );
        }
      } else {
        states[key] = ModelState(
          state: ModelTaskState.paused,
          received: received,
          total: total,
          error: e.message ?? '网络错误',
        );
      }
    } catch (e) {
      states[key] = ModelState(
        state: ModelTaskState.paused,
        received: received,
        total: total,
        error: '$e',
      );
    } finally {
      _cancelTokens.remove(key);
    }
  }

  /// 暂停下载
  void pause(WhisperModel model) {
    final key = _key(model);
    final current = states[key];
    if (current?.state != ModelTaskState.downloading) {
      return;
    }
    states[key] = ModelState(
      state: ModelTaskState.paused,
      received: current!.received,
      total: current!.total,
    );
    _cancelTokens[key]?.cancel('paused');
  }

  /// 暂停所有下载（App 退到后台时调用）
  void pauseAll() {
    for (final model in managedModels) {
      pause(model);
    }
  }

  /// 删除已下载的模型文件
  Future<void> remove(WhisperModel model) async {
    final key = _key(model);
    pause(model);
    final file = File(await pathOf(model));
    if (await file.exists()) {
      await file.delete();
    }
    final part = File(await _partPath(model));
    if (await part.exists()) {
      await part.delete();
    }
    states.remove(key);
  }

  /// 删除并重新下载（用于文件损坏时）。
  Future<void> redownload(WhisperModel model) async {
    await remove(model);
    download(model);
  }

  /// 导出模型：返回模型文件路径（Android 上位于 Download/piliplus_models，
  /// 用户可直接访问/分享）；未下载返回 null。
  Future<String?> exportModelPath(WhisperModel model) async {
    final file = File(await pathOf(model));
    return await file.exists() ? file.path : null;
  }

  /// 导入模型：把 [sourceFile]（文件名须为 ggml-<name>.bin）复制到识别目录。
  ///
  /// 返回导入的模型；文件不匹配返回 null。
  Future<WhisperModel?> importModel(File sourceFile) async {
    final name = p.basename(sourceFile.path);
    for (final model in managedModels) {
      if ('ggml-${model.modelName}.bin' != name) {
        continue;
      }
      await _migrate(model);
      final target = await pathOf(model);
      await sourceFile.copy(target);
      if (!await _isValidModelFile(
        File(target),
        minBytes: _minExpectedBytes(model),
      )) {
        // 导入的并不是有效模型文件，清理并报告失败
        try {
          await File(target).delete();
        } catch (_) {}
        return null;
      }
      states[_key(model)] = ModelState.downloaded;
      return model;
    }
    return null;
  }

  /// 扫描 Download 及模型目录下的 ggml-*.bin 文件，作为可导入的候选。
  Future<List<File>> importCandidates() async {
    final seen = <String>{};
    final result = <File>[];
    final dirs = <Directory>[];
    dirs.add(await _modelDir());
    if (Platform.isAndroid) {
      try {
        final d = await getDownloadsDirectory();
        if (d != null) {
          dirs.add(d);
        }
      } catch (_) {}
    }
    for (final dir in dirs) {
      if (!await dir.exists()) {
        continue;
      }
      await for (final e in dir.list(recursive: false)) {
        if (e is! File) {
          continue;
        }
        final base = p.basename(e.path);
        if (!base.startsWith('ggml-') || !base.endsWith('.bin')) {
          continue;
        }
        if (seen.add(e.path)) {
          result.add(e);
        }
      }
    }
    return result;
  }
}
