import 'dart:io';

import 'package:PiliPlus/http/init.dart';
import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

enum ModelTaskState { idle, downloading, paused, done }

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

  String _key(WhisperModel model) => model.modelName;

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
      final path = await pathOf(model);
      if (await File(path).exists()) {
        states[_key(model)] = ModelState.downloaded;
      }
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

  /// 确保模型就绪（未下载则下载并等待完成）
  Future<void> ensure(WhisperModel model) async {
    final key = _key(model);
    if (states[key]?.state == ModelTaskState.done) {
      return;
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
      states[key] = ModelState.downloaded;
      return;
    }
    var received = await partFile.exists() ? await partFile.length() : 0;
    var total = 0;
    states[key] = ModelState(
      state: ModelTaskState.downloading,
      received: received,
    );
    try {
      final response = await Request.dio.get<ResponseBody>(
        model.modelUri.toString(),
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          headers: {if (received > 0) 'Range': 'bytes=$received-'},
          validateStatus: (status) => status == 206 || status == 200,
        ),
      );
      final headers = response.headers;
      final contentLength =
          int.tryParse(headers.value(Headers.contentLengthHeader) ?? '') ?? 0;
      final statusCode = response.statusCode ?? -1;
      if (statusCode == 200 && received > 0) {
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
        throw '下载不完整';
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
