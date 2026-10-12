# User Instruction Memory

This file records user instructions, preferences, and teachings for reference in future interactions.

## Format

### User Instruction Entry
User instruction entries should follow this format:

[User Instruction Summary]
- Date: [YYYY-MM-DD]
- Context: [Mentioned scenario or time]
- Instructions:
  - [Content of user teaching or instruction, described line by line]

### Project Knowledge Entry
Entries discovered by the Agent during task execution should follow this format:

[Project Knowledge Summary]
- Date: [YYYY-MM-DD]
- Context: Discovered by Agent while performing [specific task description]
- Category: [Operations & Deployment|Build Methods|Testing Methods|Troubleshooting & Debugging|Workflow & Collaboration|Environment Configuration]
- Instructions:
  - [Specific knowledge points, described line by line]

## Deduplication Strategy
- Before adding a new entry, check for similar or identical instructions.
- If a duplicate is found, skip the new entry or merge it with the existing one.
- When merging, update the context or date information.

## Entries

[CI 发布 Android 包的流程]
- Date: 2026-09-30
- Context: Discovered by Agent while publishing code and Android release APK
- Category: Operations & Deployment
- Instructions:
  - 本仓库是 fork，origin 为 coolmoonboom/myPiliPlus（无上游 bggRGjQaUbCoE/PiliPlus 写权限）。
  - 发布流程：推 main 到 origin 后执行 `gh workflow run 335279958 --repo coolmoonboom/myPiliPlus --ref main -f build_android=true -f build_ios=false -f build_mac=false -f build_win_x64=false -f build_linux_x64=false -f tag=<版本>`。
  - build.yml 的 android job 在 workflow_dispatch 且 tag 非空时，自动用 softprops/action-gh-release 创建 Release 并上传 APK。用户要求自 2026-10-10 起只发布 arm64-v8a（armv8）：构建命令为 `flutter build apk --release --split-per-abi --target-platform android-arm64`，产物仅 app-arm64-v8a-release.apk（Rename 步骤能正确解析出 arm64-v8a）。
  - 未配置 SIGN_KEYSTORE_BASE64 等 secrets 时，release APK 回退 debug 签名（android/app/build.gradle.kts 中 signingConfig = config ?: signingConfigs["debug"]），可安装但非正式发布签名。
  - 版本号由 lib/scripts/build.ps1 基于 commit 数自动生成，pubspec 的 version 仅作前缀。
  - git push 到 GitHub 偶发 `RPC failed; HTTP 408` / `send-pack: unexpected disconnect`，重试仍失败时加 `git -c http.version=HTTP/1.1 -c http.postBuffer=52428800 push <url> main` 可成功（勿写坏本地 git config）。

[CI Android 构建的已知坑]
- Date: 2026-09-30
- Context: Discovered by Agent while fixing workflow_dispatch Android build failures
- Category: Troubleshooting & Debugging
- Instructions:
  - whisper_ggml 插件要求 NDK 29.0.13113456，GitHub runner 预装 SDK 未含该版本，Gradle 自动安装会被许可拦截（LicenceNotAcceptedException）。修复：构建前执行 `yes | $ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager --licenses` 并显式安装 `ndk;29.0.13113456`（已加入 build.yml）。
  - `flutter pub get` 在 lib/scripts/patch.ps1 内执行（CI 无独立 pub get 步骤），新增依赖只改 pubspec.yaml 即可，CI 会自动解析；本地无 Flutter SDK 时无法更新 pubspec.lock。
  - Dart kernel 编译报 "Type 'StatefulWidget'/'Widget' not found" 说明 UI 文件缺 `import 'package:flutter/material.dart';`。

[本地校验环境的限制与工具]
- Date: 2026-09-30
- Context: Discovered by Agent while doing static verification of Dart files
- Category: Environment Configuration
- Instructions:
  - 本环境无 Flutter/Android SDK，无法完整编译；只能做语法级校验。
  - 代码大量使用 dot-shorthands（`.paused` 等枚举简写），stable Dart 3.9.x 无法解析；需要 dev 渠道 3.14 SDK。dev SDK 非常驻（/opt/dart314 已失效），需要时从 `https://storage.googleapis.com/dart-archive/channels/dev/release/<ver>/sdk/dartsdk-linux-x64-release.zip` 下载解压到 /tmp。
  - 语法校验命令：`<dart-sdk>/bin/dart format --output=none <file>`；格式化工具是容错解析，残缺的孤儿语句块（如 edit 残留的旧函数尾巴）不会报错，不能作为唯一门禁，UI 文件仍需人工核对 material 导入。
  - 严格语法门禁：`/tmp/synchk`（analyzer ^9，Dart 3.13 SDK）。提交前跑 `cd /tmp/synchk && /tmp/dart-sdk/bin/dart run bin/synchk.dart <改动的dart文件绝对路径...>`，exit 0 才可提交推送；该工具曾因 CI 编译失败（format 漏掉的残留片段）而建立。若 /tmp/synchk 被清理，重建：pubspec 依赖 `analyzer: ^9.0.0`，用 `parseFile(path:, featureSet: FeatureSet.latestLanguageVersion())` 并 catch ArgumentError 打印诊断。
  - pubspec.yaml 固定 flutter: 3.47.5、sdk >=3.13.0，CI 的 subosito/flutter-action 通过 flutter-version-file 读取。

[Release 2.2.1 发布经验]
- Date: 2026-09-30
- Context: Discovered by Agent while publishing piliplusfr 2.2.1
- Category: Operations & Deployment
- Instructions:
  - CI 改单 abi 后用 `flutter build apk --target-platform android-arm64`（不带 --split-per-abi），产物是 fat `app-release.apk`，不是 `app-<abi>-release.apk`
  - build.yml Rename 步骤从 `build/app/outputs/flutter-apk` 上跳 4 级才到仓库根；softprops 的 files 通配符在仓库根匹配，匹配不到只打 warning 不报错（会得到空 assets 的 Release）
  - AndroidHelper.java（Java 源）留在旧包 com.example.piliplus 时引用 R 需显式 `import com.example.piliplusfr.R;`

[改应用包名的 Android 配套坑]
- Date: 2026-09-30
- Context: Discovered by Agent while fixing 2.2.1 startup crash
- Category: Troubleshooting & Debugging
- Instructions:
  - 改 namespace/applicationId 但 Kotlin/Java 源码留旧包时，manifest 中所有相对类名（.MainActivity、.BiliDocumentsProvider 等）必须改成旧包全限定名，否则启动即 ClassNotFoundException 闪退
  - 本项目 JNI（ffigen bindings.g.dart）按 com/example/piliplus/... FindClass，源码包名不可轻改；applicationId 可与源码包名不同

[GetX(fork) Obx “improper use” 崩溃的成因与定位]
- Date: 2026-10-01
- Context: Discovered by Agent while fixing 在线视频页白屏（有声音无画面）
- Category: Troubleshooting & Debugging
- Instructions:
  - 规则：Obx 在其「首次 build」内若未读取任何 Rx（canUpdate=_subscriptions.isNotEmpty 为假），get 直接抛 "the improper use of a GetX has been detected"。订阅是累加的、仅随 Obx 卸载清除，故只会在首次 build 触发。
  - 高发写法：把 Rx 读取放在 `&&`/`||` 末尾，被前面的普通条件短路；或在 Obx 内只读 Hive（GStorage.setting.get）等非 Rx 来源；或外层 Obx 的 Rx 只在内层嵌套 Obx 里读。
  - 排查：在 main.dart 用 ErrorWidget.builder 渲染可视化面板，并以「面板自身 element 的 context.visitAncestorElements」枚举祖先 widget 链（注意 Flutter 3.47 的 FlutterErrorDetails.context 是 DiagnosticsNode?，不是 BuildContext?，无法直接遍历）。栈顶 ObxState.build + 祖先链可精确定位到具体 Obx。
  - 修复：把 Rx 读取提到 Obx builder 最前面无条件读取。
  - 健康检查：RxList.toList()/RxMap[key]/.value 都会经由 value getter 注册订阅；Hive-only 读取不会。

[不重新打 tag 时手动发布 APK 到既有 Release]
- Date: 2026-10-01
- Context: Discovered by Agent while publishing fix build to Release 2.3.0
- Category: Operations & Deployment
- Instructions:
  - gh workflow run 省略 tag 时，build.yml 的 Release 步骤被跳过，只跑 upload-artifact；不会自动生成 Release 资产。
  - 取产物：`gh api repos/coolmoonboom/myPiliPlus/actions/artifacts/<artifact_id>/zip`（返回的就是 APK 字节；`gh run download` 会把它解成目录）。artifact_id 用 `gh api .../runs/<run_id>/artifacts --jq '.artifacts[]|select(.name|contains("arm64"))|.id'` 取。
  - 上传：`gh release upload 2.3.0 <apk> --repo coolmoonboom/myPiliPlus`（同名已存在加 --clobber）。若改用 curl POST `uploads.github.com/.../assets?name=...`，`+` 必须写成 URI query 里的 `%2B` + `--data-binary @文件`；multipart `-F name=...`（含表单字段里带 `%`/`+`）会被拒为 `Invalid name for request`，只有 query 方式可行。上传后必须 curl 验证下载 URL 可访问再交付。
  - gh 认证 token 易过期（HTTP 401 Bad credentials）；用 `printf 'protocol=https\nhost=github.com\n\n' | git credential fill` 取 password 后 `gh auth login --with-token` 重新登录即可。

[material_ui 主题体系与禁止混导 flutter/material；视频页弹层走 PageUtils.showVideoBottomSheet]
- Date: 2026-10-01（2026-10-03 补充）
- Context: Discovered by Agent while 修复字幕面板深色失效 / 混导编译失败（CI run 37091894362）
- Category: Troubleshooting & Debugging
- Instructions:
  - 本项目 UI 层只允许 `package:material_ui/material_ui.dart`（Flutter material 的 fork，自带独立 ThemeData/Theme，并重定义 Theme/Icons/Colors/FilledButton 等）。任何文件再显式 import 'package:flutter/material.dart' 会引发大量 "imported from both" 编译错误。
  - Theme.of 只认 material_ui 注入的 app 主题（含深色）；用 flutter/material 会渲成 fallback 浅色；material_ui 的 ThemeData 不能传给 flutter 的 Theme 组件（类型不匹配）。缺符号（如 ScrollDirection/UserScrollNotification）优先用 material_ui 已导出的符号 + Dart 3 枚举简写（`n.direction != .idle`、`position.userScrollDirection == .forward`），参考 lib/pages/live_room/controller.dart。
  - 视频页（播放器之上）显示弹层应复用 PageUtils.showVideoBottomSheet 或 HeaderMixin.showBottomSheet（竖屏底部/横屏右侧面板），不要直接 showModalBottomSheet；深色视频页(darkVideoPage)下用 ThemeUtils.darkTheme 包一层内容。

[Whisper 模型目录与导出/导入约定]
- Date: 2026-10-01
- Context: Discovered by Agent while migrating 模型存放目录 per user request
- Category: Operations & Deployment
- Instructions:
  - 模型根目录：Android 上为 `Download/piliplus_models`（getDownloadsDirectory()，Android 10+ 直写无需权限，manifest 已有 READ/WRITE_EXTERNAL_STORAGE maxSdk 32/28）；iOS/macOS 回退 getLibraryDirectory，其余平台 getApplicationSupportDirectory 下 whisper_models。
  - 识别统一走 LocalSubtitleService.transcribeWithModel（底层 Whisper().transcribe 的 modelPath），实时/整段共用；不要再用 WhisperController().transcribe（它固定用应用私有目录）。
  - ModelManager._migrate 负责把旧私有目录模型拷到新目录并删除旧文件；导出=返回路径供分享，导入=按 ggml-<name>.bin 文件名匹配后 copy 进识别目录。
  - ModelSelector 构造需要 playerController（导出分享/导入 bottom sheet 用），实例化处：settings_sheet.dart 与 local_subtitle/view.dart。

[Dart 陷阱：`&& ... case pattern` 抛 TypeError，必须改用嵌套 if]
- Date: 2026-10-02
- Context: Discovered by Agent while 定位「在线翻译一直失败回退词库」：日志每句都抛 `type '_Map<String, dynamic>' is not a subtype of type 'bool'`
- Category: Troubleshooting & Debugging
- Instructions:
  - 本项目 Django/混合 Dart 代码里 `if (a is Map && a['k'] case final Map v)` 这类「case 模式紧跟 && 」的写法在运行时会抛 TypeError：`case` 模式作用于整个 if 条件（含前面整个 `&&` 链），导致先求值 `a is Map && a['k']`，右侧是 Map 而非 bool，直接抛 `type 'Map' is not a subtype of type 'bool'`。任何加括号 `(x case P)` 在表达式位置也无法编译。
  - `expr case P` 只有作为 if/while 条件的**唯一/末尾**守卫时才安全（如 `if (foo() case final x?)`）；一旦前面还有 `&&`，就不要用 case 模式。
  - 修法：改为嵌套 `if (a is Map) { final v = a['k']; if (v is Map) {...} }`，不用 case 模式。
  - 排查时可用 dev dart SDK 写最小复现脚本确认行为。

[Dart SDK 差异与编译陷阱汇总（dart:io / 级联+lambda）]
- Date: 2026-10-03
- Context: Discovered by Agent while 修复 CI 编译失败（RandomAccessFile.open；级联+lambda）
- Category: Troubleshooting & Debugging
- Instructions:
  - 本项目 Flutter SDK 的 dart:io 没有 `RandomAccessFile.open(...)` 静态方法，随机读文件要用 `File(path).openSync()`（返回 RandomAccessFile，默认 read 模式）；本地无 flutter 环境时本地 dart 分析发现不了这类 SDK 差异，最终以 CI 为准。
  - 写法 `..prop = () => expr..other = v` 会把第二个级联吞进 lambda 返回值上，dart format 与本地无包分析均不报错，只有 CI 编译暴露。级联里含函数字面量时，函数赋值单独成行。
  - Release 资产 label 含中文长文本可能被拒（4-byte Unicode）；用 ASCII label 稳妥。

[Get.put 控制器 onClose 不保证触发，持久化须挂确定生命周期]
- Date: 2026-10-06
- Context: Discovered by Agent while 定位「字幕存档退出视频后丢失」
- Category: Troubleshooting & Debugging
- Instructions:
  - VideoDetailController 用 `Get.put(VideoDetailController(), tag: heroTag)` 创建（无 binding），页面退出时 GetX 不保证调用其 onClose，只在 onClose 落盘会丢数据。
  - 需要持久化的状态应在确定执行的生命周期落盘：View 的 dispose()、didChangeAppLifecycleState 的 paused、子面板 dispose()，以及播放中按节流间隔（positionListener 每约 10s）。

[Scrollable.ensureVisible 会连带滚动外层 TabBarView，跨 tab 跟随禁止用它]
- Date: 2026-10-07
- Context: Discovered by Agent while 定位「字幕播放到下一句会自动切回字幕 tab」
- Category: Troubleshooting & Debugging
- Instructions:
  - Flutter `Scrollable.ensureVisible(ctx, alignment: 0.5)` 会把 ctx 的**所有祖先滚动容器**一起滚动才能让目标可见。字幕页是外层 TabBarView（PageView）的一页，列表内调用它会连带把外层 PageView 翻回字幕 tab，即使用户正停在其他 tab 或面板被 keep-alive。
  - 只想滚动内层列表时，改为直接操作该列表自己的 ScrollController，用 `RenderAbstractViewport.of(row).getOffsetToReveal(row, 0.5).offset` 求目标偏移再 `position.animateTo/jumpTo`（`ScrollPosition.context` 是 `ScrollContext`、并非 `BuildContext`，不能直接 `findRenderObject()`）。
  - 用户手动滑动期间要临时屏蔽自动滚动（但保留高亮）：用 `NotificationListener<ScrollNotification>`；`dragDetails` 只定义在 `ScrollStart/ScrollUpdate/ScrollEndNotification` 子类上（基类 `ScrollNotification` 没有），靠它区分用户拖动与程序 animateTo/jumpTo。


[大模型(turbo/large)识别连环超时的成因与看门狗设计]
- Date: 2026-10-11
- Context: Discovered by Agent while 修复「选 large-v3-turbo 不生效、没有字幕」
- Category: Troubleshooting & Debugging
- Instructions:
  - whisper_ggml 原生转写不可中断：Dart 侧 `.timeout()` 只放弃等待，原生 isolate 仍在跑并会占模型/内存。
  - 大模型（turbo 575MB+/large 3GB）首块转写包含模型加载，固定 240s 看门狗会「首块必超时」；随后新请求与僵尸转写并发，双份大模型加载把所有后续块拖超时（3 连败后全程无字幕）。base 等小模型快，触发不了。
  - 正确设计：看门狗按 arch 自适应（tiny 150s / small·base 240s / medium 480s / large 600s）；下一块前必须 await 僵尸 Future（完成后 keepModelLoaded 会驻留模型，下一块免二次加载）；native 报 failed to load model 时立即终止不重试。
  - 模型文件侧无需担心：HF ggerganov/whisper.cpp 的 turbo/量化文件是 legacy GGML 魔数(6c6d6767)，whisper_ggml 2.6+ 内置 whisper.cpp v1.9.1 支持 turbo；插件 transcribe 按 modelPath 加载，WhisperModel 枚举只是占位。
  - 真机实测（2026-10-11）：turbo q5_0 正常出结果但很慢——15s 音频块转写 73~97s（threads=3，RTF≈5），首块含模型加载约 75s；用户体感的「没有字幕/卡在切换队列」多半是等首块与等在途原生块收尾（不可中断，最长 ~97s），不是挂死。已将 large/medium 的线程 3→4 提速；收尾等待期加心跳显示已用秒数。

[双语翻译可走本地 Offline Translator 的 LibreTranslate 兼容服务]
- Date: 2026-10-07
- Context: Discovered by Agent while 把字幕双语翻译从在线改为本地（用户指定用开源项目 dev.davidv.translator）
- Category: Operations & Deployment
- Instructions:
  - 「Offline Translator」（作者 David Ventura，仓库 github.com/DavidVentura/offline-translator，GPLv3，F-Droid 包名 dev.davidv.translator）内置「Enable LibreTranslate compatible HTTP server」，默认 `http://127.0.0.1:5000`、Bind on localhost，可被其它 App 本机调用做离线翻译（法↔简中等 61 种语言）。我们按 LibreTranslate 协议 POST，不复制其代码，无 GPL 传染。
  - 本 App 的 `TranslationService`（lib/services/local_subtitle/subtitle_translator.dart）provider 有：glossary(0,在线优先)/http(1)/local(2,仅本地)/autoLocal(3,本地优先回退在线/词库，默认)。本地地址常量 `kOfflineTranslatorEndpoint=http://127.0.0.1:5000/translate`，设置键 `translationLocalEndpoint`。
  - 关键实现点：LibreTranslate 响应是顶层 `translatedText`（MyMemory 才是 `responseData.translatedText`），解析需两者兼容；LibreTranslate 目标语言用 `zh`（MyMemory 要 `zh-CN`）。
  - Android 明文：targetSdk 37 默认禁 cleartext，需 `android/app/src/main/res/xml/network_security_config.xml` 只放行 `127.0.0.1`/`localhost`，并在 AndroidManifest 的 `<application>` 加 `android:networkSecurityConfig`。

[LiveSub 测试应用本地安卓构建环境]
- Date: 2026-10-11
- Context: Discovered by Agent while building LiveSub (system-audio-subtitles) in sandbox
- Category: Environment Configuration
- Instructions:
  - Flutter stable 3.47.7 + Android SDK 已装在 /opt（env: source /opt/livesub_env.sh）；flutter 发行包官方 GCS 会报 UserProjectAccountProblem（计费问题），必须用镜像 https://storage.flutter-io.cn/flutter_infra_release/releases/stable/linux/...
  - LiveSub 工程在 /tmp/livesub（不在 git）；APK 产物发布到 coolmoonboom/myPiliPlus 仓库 release，不提交新项目代码。
  - Android 构建内存吃紧（8G 主机）：android/gradle.properties 已限 -Xmx1800m；构建必须经 background_terminal_create 加 memory_percent。

[LiveSub 独立应用：悬浮窗 + sherpa 流式]
- Date: 2026-10-12
- Context: Discovered by Agent while implementing overlay + streaming ASR for LiveSub
- Category: Environment Configuration
- Instructions:
  - 切换识别内核 whisper_ggml → sherpa_onnx（1.13.8，流式 zipformer），pubspec 移除 whisper_ggml、新增 sherpa_onnx（0.2.1 起移除 archive，改为逐文件下载）。
  - 模型: sherpa-onnx-streaming-zipformer-fr-kroko-2025-08-06，**modelType 必须是 zipformer2**；配成 zipformer 时原生直接报 `'attention_dims' does not exist in the metadata`，App 表现为「模型加载失败」。桌面 dart 端用同一份 sherpa_onnx 包 + 同配置可离线复现此类原生错误。
  - 模型下载（0.2.1 起）: 逐文件从 hf-mirror 下载 `https://hf-mirror.com/csukuangfj/<dir>/resolve/main/<file>`（encoder/decoder/joiner.onnx + tokens.txt，共 ~71MB），.part 临时文件 + 大小校验 + rename 原子落盘；国内直连 github.com 下载不通是此前「下载不了」的主因。手动兜底目录 /storage/emulated/0/Download/piliplus_models/<dir>/。
  - 捕获块长改为 100ms（chunkMillis，原 chunkSeconds=8）以适配流式。
  - 悬浮窗: OverlayController.kt 用 SYSTEM_ALERT_WINDOW + WindowManager，悬浮窗视图绑定 applicationContext 而非 Activity， survives Activity 回收。由 livesub/overlay MethodChannel show/hide/update/pushLine 控制，FGS mediaProjection 进程保活。
  - AndroidManifest 加入 SYSTEM_ALERT_WINDOW + FOREGROUND_SERVICE_MEDIA_PROJECTION；FGS mediaProjection 必须在 getMediaProjection 后 startForeground。
  - 发布: APK 不进 git，推到 coolmoonboom/myPiliPlus release（tag livesub-x.y.z）。

[用户教学：不要反复打包 APK]
- Date: 2026-10-12
- Context: User explicitly said "别老跑apk" after multiple builds for the 2.4.16 feature
- Category: Workflow & Collaboration
- Instructions:
  - 除用户明确要求验证，否则不要每次改动都 `flutter build apk`；先静态分析 flutter analyze 过，再在需要验证的里程结点统一打一次。
