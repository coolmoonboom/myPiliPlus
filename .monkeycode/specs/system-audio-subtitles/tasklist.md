# 需求实施计划（LiveSub · system-audio-subtitles）

约束：工程建在 当前工作区 外 `/tmp/livesub`，代码不进任何 git；产物 APK 发布到 coolmoonboom/myPiliPlus 仓库 GitHub Release；不持久化音频（R1 补充），持久化字幕文本（R5-5）；本沙箱本地构建（工具链由后台任务安装到 /opt）。

- [x] 1. 构建环境与工程脚手架
  - [x] 1.1 安装本地工具链（JDK17、Flutter stable、Android SDK platform-36/build-tools/NDK）并验证 `flutter doctor --android`
  - [x] 1.2 `flutter create` 生成 /tmp/livesub 工程：包名 com.coolmoonfrench.livesub，minSdk 29，仅配 arm64-v8a（design: Architecture）
  - [x] 1.3 配置依赖：whisper_ggml、path_provider、path、get（或 flutter_riverpod，沿用 get 习惯）；material_ui 依赖按需（测试应用可直接用 material，UI 从简）（design: 复用策略）
  - [x] 1.4 移植 myPiliPlus 复用文件：local_subtitle_service（裁剪为直接调 whisper_ggml）、model_manager、subtitle_translator + 词库资产、subtitle_debug_log（design: Components）

- [x] 2. Kotlin 采集层（R1）
  - [x] 2.1 CaptureService 前台服务：MediaProjection 接收、AudioRecord(AudioPlaybackCaptureConfiguration, 16kHz/mono/PCM16)、按 chunk 秒攒块、EventChannel 向 Dart 推 ByteData（R1-1/2/4/5）
  - [x] 2.2 常驻通知「停止捕获」action 与 Android 14+ FGS 类型声明（R1-4/5）
  - [x] 2.3 静音统计：首块起计算全零/低能量时长，MethodChannel 回传静音秒数（R1-3）
  - [x] 2.4 MainActivity MethodChannel 门面：start/stop/permission（MediaProjection 授权 Activity 流程）（R1-1）

- [x] 3. Dart 识别管线（R2）
  - [x] 3.1 CapturePipeline：EventChannel PCM → 能量 VAD（20ms 窗 RMS，静音>85% 跳块）→ 串行转写队列（上限 3，超限丢最旧+缺口标记）（R2-2、设计 Error Handling 队列积压）
  - [x] 3.2 PCM→16k WAV 临时文件写入与 whisper_ggml 串行转写封装（threads 默认 4）（R2-1）
  - [x] 3.3 时间轴换算：块 k 起点 + 段相对秒 → SessionSegment.absStartMs；相邻块首尾去重（R2-3/4）
  - [x] 3.4 RTF 监控：最近 10 块均 RTF>0.9 提示换小模型（R2 设计监控条）

- [x] 4. 翻译与文本持久化（R3、R5 部分）
  - [x] 4.1 翻译队列：原文逐条走移植的 autoLocal 链（本地 2s 超时→词库兜底），失败重试≤2（R3-1/2/3）
  - [x] 4.2 会话存储：sessions/<ts>.json 保存字幕文本（不含音频），保留最近 20 场（R5-5）；临时 WAV 转写完立即覆写（R1 补充约束）
  - [ ] 4.3 导出 SRT 与双语 txt 到 Download/livesub/（R5-3）

- [x] 5. M1 最小 UI 与出包验证
  - [x] 5.1 单页 Home：开始/停止捕获、状态文本、识别日志流（debug log 复用样式）、模型选择（R6-1）
  - [x] 5.2 调试日志页复用 myPiliPlus debug_log_sheet 模式
  - [x] 5.3 `flutter build apk --release --target-platform android-arm64` 构建成功
  - [x] 5.4 以 tag livesub-m1 创建 Release 并上传 APK，curl 验证下载 200
- [ ] 6. 检查点 — M1 真机验证：FGS 崩溃已修、共享目录已修；whisper 块式 RTF≈5 太慢 → 触发换流式内核（见任务 11）；v0.1.2 已发布待复测

- [x] 7. Kotlin 悬浮窗（M2，R4）
  - [x] 7.1 OverlayController：TYPE_APPLICATION_OVERLAY「历史区 + 当前双语行」，livesub/overlay 通道 show/hide/update/pushLine（R4-1/2）
  - [x] 7.2 整块拖动（ACTION_MOVE 更新 LayoutParams）；轻点清空历史（R4-3；展开列表/位置持久化遗留 M3）
  - [x] 7.3 SYSTEM_ALERT_WINDOW 权限引导：ACTION_MANAGE_OVERLAY_PERMISSION + onActivityResult 回传结果（R4-5）
  - [x] 7.4 悬浮窗视图绑定 applicationContext，FGS 保活覆盖任意前台应用

- [ ] 8. 应用内完整界面（M2 部分完成，R5 partially）
  - [x] 8.1 双语列表页（应用内历史列表 + 当前行卡片），长按操作未做（R5-1；R5-2 遗留）
  - [ ] 8.2 会话历史页（最近 20 场查看/重导出）（R5-5）
  - [ ] 8.3 设置页：块长/端点阈值/翻译端点/悬浮窗字号（R6-2/3）
  - [ ] 8.4 设置页翻译服务探测按钮（R3-4）

- [x] 11. 流式识别内核切换 + 模型下载（2026-10-12，响应用户性能反馈）
  - [x] 11.1 pubspec 移除 whisper_ggml，新增 sherpa_onnx ^1.13.8 + archive ^3.6.1；arm64 验证 libonnxruntime.so/libsherpa-onnx-c-api.so 已打包
  - [x] 11.2 SherpaRecognizer：initBindings + OnlineRecognizer(numThreads=4)；acceptChunk 返回 text+isEndpoint，端点自动 reset
  - [x] 11.3 CaptureService 块长 chunkSeconds 8 → chunkMillis 100，静音占比仅统计不再跳块
  - [x] 11.4 翻译节流：≥1.2s 且文本变化才翻；回调校验同句才上屏；端点定句后补翻回填历史
  - [x] 11.5 ModelDownloader：kroko fr 55MB tar.bz2 下载（体积进度）→ BZip2+Tar 解压（真实包离线验证）→ 防路径穿越 → 删除归档
  - [x] 11.6 ModelDir 改扫 sherpa 子目录（encoder/decoder/joiner/tokens 齐备判定）；Home 下载按钮 + 进度条 + 重新扫描
  - [x] 11.7 flutter analyze 零告警；构建成功 app-release.apk 95.2MB（v0.2.0）

- [x] 9. 收尾与发布（M2）
  - [x] 9.1 修正 M1 真机反馈问题（FGS 顺序、共享目录）
  - [x] 9.2 `flutter build apk --release --target-platform android-arm64`，tag livesub-0.2.0 发布到 myPiliPlus Release

- [x] 12. 0.2.1 修复「模型加载失败」+ 下载链路改造（2026-10-12，响应用户真机反馈）
  - [x] 12.1 桌面 dart 用真实 kroko 模型复现：modelType=zipformer 原生报 `'attention_dims' does not exist`；改 **zipformer2** 后实测输出正确法语
  - [x] 12.2 SherpaModel 重构：downloadUrl(tar.bz2) → fileBaseUrl(hf-mirror resolve/main) + fileBytes 逐文件表；移除 archive 依赖
  - [x] 12.3 ModelDownloader 逐文件下载 .part → 字节数校验 → rename；失败原因红字显示在主界面并显示当前文件名
  - [x] 12.4 识别器 initError 透传到状态条「模型加载失败: 原因」
  - [ ] 12.5 v0.2.1 构建 + tag livesub-0.2.1 发布

- [ ] 10. 检查点 — 0.2.1 真机回归：下载→加载→流式延迟/端点断句/悬浮窗覆盖效果；按反馈调端点阈值
