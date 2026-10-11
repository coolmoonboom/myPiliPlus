# Requirements Document

## Introduction

独立的 Android 应用（暂名 LiveSub）：抓取系统其他应用播放的音频，本地 whisper 模型流式识别为法语字幕，并调用 dev.davidv.translator 的 LibreTranslate 兼容 HTTP 服务生成中文翻译。字幕以悬浮窗覆盖在源应用之上显示，应用内同时提供完整双语列表。识别内核取自 myPiliPlus 的 whisper FFI 与增量识别设计，采集与分块管线按"连续 PCM、小分块、跳过静音"重建，以实现比 myPiliPlus 在线取流更低的出词延迟。

## Glossary

- **System**：本应用（LiveSub）
- **源应用**：播放音频、被捕获声音的其他 Android 应用
- **捕获会话（Capture Session）**：从开始抓取到停止抓取的一次连续过程
- **PCM 块（PCM Chunk）**：从捕获流按固定时长切分的原始音频片段，是识别的调度单位
- **悬浮窗（Overlay）**：显示在源应用之上的系统级窗口
- **本地翻译服务（Local Translator）**：dev.davidv.translator 提供的 LibreTranslate 兼容 HTTP 服务，默认 `http://127.0.0.1:5000/translate`
- **模型目录（Model Directory）**：共享目录 `Download/piliplus_models`，存放 ggml 模型文件

## Requirements

### Requirement 1 系统音频捕获

**User Story:** AS 用户, I want 应用抓取其他应用正在播放的声音, so that 任何来源的法语视频都能出字幕。

#### Acceptance Criteria

1. WHEN 用户点按「开始捕获」, System SHALL 发起 MediaProjection 授权并启动 AudioPlaybackCapture 采集其他应用的音频输出。
2. WHILE 捕获会话进行中, System SHALL 以 16-bit PCM、16 kHz 单声道连续读取音频流并切成 PCM 块（默认 8 秒/块，可配置 5/8/12 秒）。
3. IF 目标应用声明禁止音频捕获（FLAG_SECURE 或 allowedCapturePolicy 拒收）导致捕获内容为静音, System SHALL 在界面提示「该应用禁止捕获音频」并显示累计静音时长。
4. WHEN 用户点按「停止」或移除通知栏停止, System SHALL 停止采集、释放 MediaProjection 资源并结束捕获会话。
5. System SHALL 以前台服务承载采集与识别， Android 版本下限为 10（API 29）。

### Requirement 2 本地流式识别

**User Story:** AS 用户, I want 识别在手机上离线完成且延迟低, so that 字幕与语音基本同步。

#### Acceptance Criteria

1. WHEN PCM 块读取完成, System SHALL 将该块送入本地 whisper 模型转写（默认 small，支持 tiny/base 切换，模型来自模型目录）。
2. IF PCM 块的静音占比超过阈值（默认 85%，VAD 判定）, System SHALL 跳过该块转写并标记为静音块。
3. WHEN 转写产出一条分段, System SHALL 以「会话开始时刻 + 分段相对秒数」换算绝对时间轴并追加到结果列表。
4. WHEN 识别出相邻 PCM 块的衔接分段文本, System SHALL 去除相邻块的词重复（沿用 myPiliPlus 的块间去重策略）。
5. IF 模型文件缺失或加载失败, System SHALL 停止识别并在界面给出「模型未下载」提示与跳转入口。
6. WHILE 捕获会话进行中, System SHALL 支持切换识别模型，切换后从新块开始使用新模型。

### Requirement 3 翻译

**User Story:** AS 用户, I want 每条字幕带中文翻译, so that 听不懂的法语句可以直接看懂。

#### Acceptance Criteria

1. WHEN 一条识别分段产出, System SHALL 将原文送入本地翻译服务获取译文，与字幕一并展示。
2. IF 本地翻译服务在 2 秒内无响应, System SHALL 回退端内置顶词库翻译并标注「词库」来源。
3. IF 某条分段翻译失败, System SHALL 保留该条字幕且译文位显示「-」，重试不超过 2 次。
4. WHEN 用户在设置中修改翻译服务地址, System SHALL 校验服务可用性并反馈结果（沿用 myPiliPlus 的探测逻辑）。

### Requirement 4 悬浮字幕窗

**User Story:** AS 用户, I want 字幕悬浮在源应用上方, so that 不用切换应用就能看双语字幕。

#### Acceptance Criteria

1. WHILE 捕获会话进行中, System SHALL 在屏幕下方显示悬浮窗，内容为最近 1 条字幕的双语两行。
2. WHEN 新字幕段产出（原文稳定）, System SHALL 更新悬浮窗内容。
3. WHEN 用户拖动悬浮窗, System SHALL 移动窗口位置并持久化位置设置。
4. WHEN 用户点按悬浮窗, System SHALL 展开显示最近 10 条双语字幕列表。
5. IF 用户未授予悬浮窗（SYSTEM_ALERT_WINDOW）权限, System SHALL 引导用户到系统设置开启。

### Requirement 5 应用内字幕列表

**User Story:** AS 用户, I want 在应用内浏览本次会话的全部字幕, so that 可以回看、复制和导出。

#### Acceptance Criteria

1. WHEN 每条字幕（原文或译文）产出, System SHALL 追加到应用内双语列表并滚动到最新条。
2. WHEN 用户长按一条字幕, System SHALL 提供「复制原文」「复制译文」「重新翻译该句」操作。
3. WHEN 用户点按「导出」, System SHALL 将会话字幕以 SRT 与纯双语 txt 两种格式写入 `Download/livesub/`。
4. WHEN 用户新建捕获会话, System SHALL 清空当前列表并开启新会话记录。
5. WHEN 捕获会话结束, System SHALL 持久化本次会话结果供再次查看（保留最近 20 场）。

### Requirement 6 模型与设置

**User Story:** AS 用户, I want 复用已有模型和熟悉的设置, so that 无需重复下载模型。

#### Acceptance Criteria

1. WHEN 应用首次启动, System SHALL 扫描模型目录列出可用 ggml 模型供选择（沿用 myPiliPlus 扫描与命名解析规则）。
2. System SHALL 提供设置项：识别模型、PCM 块长、VAD 静音阈值、翻译服务地址、悬浮窗字号与行数。
3. WHEN 设置项被修改, System SHALL 持久化并在下一次捕获会话或下一次分块生效。
