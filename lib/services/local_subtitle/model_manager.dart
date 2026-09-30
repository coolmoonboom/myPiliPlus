import 'dart:io';

import 'package:PiliPlus/http/init.dart';
import 'package:dio/dio.dart';
import 'package:get/get.dart';
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

  Future<void> _initStates() async {
    for (final model in managedModels) {
      final path = await WhisperController.getPath(model);
      if (await File(path).exists()) {
        states[_key(model)] = ModelState.downloaded;
      }
    }
  }

  Future<String> pathOf(WhisperModel model) => WhisperController.getPath(model);

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
      final response = await Request().dio.get<ResponseBody>(
        model.modelUri.toString(),
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
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
        received += chunk.length;
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
      if (CancelToken.isCancel(cancelToken)) {
        return;
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
      if (CancelToken.isCancel(cancelToken)) {
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
      received: current.received,
      total: current.total,
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
}
