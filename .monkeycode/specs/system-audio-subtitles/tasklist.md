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
- [ ] 6. 检查点 — M1 真机验证延迟与捕获可用性，向用户确认后再进 M2

- [ ] 7. Kotlin 悬浮窗（M2，R4）
  - [ ] 7.1 OverlayController：TYPE_APPLICATION_OVERLAY 折叠双语两行，MethodChannel 收数据（R4-1/2）
  - [ ] 7.2 拖动与位置持久化、点按展开最近 10 条 RecyclerView（R4-3/4)
  - [ ] 7.3 SYSTEM_ALERT_WINDOW 权限引导（R4-5）

- [ ] 8. 应用内完整界面（M2，R5、R6）
  - [ ] 8.1 双语列表页 + 长按操作（复制原文/译文/重译该句）（R5-1/2）
  - [ ] 8.2 会话历史页（最近 20 场查看/重导出）（R5-5）
  - [ ] 8.3 设置页：模型/块长/VAD 阈值/翻译端点/悬浮窗字号，修改即持久化（R6-2/3）
  - [ ] 8.4 设置页翻译服务探测按钮（R3-4）

- [ ] 9. 收尾与发布（M2）
  - [ ] 9.1 修正 M1 真机反馈问题
  - [ ] 9.2 `flutter build apk --release --target-platform android-arm64`，tag 递增发布到 myPiliPlus Release

- [ ] 10. 检查点 — 确保所有分析器无 error，构建通过，如有疑问询问用户
