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
  - build.yml 的 android job 在 workflow_dispatch 且 tag 非空时，自动用 softprops/action-gh-release 创建 Release 并上传三个 ABI 的 APK。
  - 未配置 SIGN_KEYSTORE_BASE64 等 secrets 时，release APK 回退 debug 签名（android/app/build.gradle.kts 中 signingConfig = config ?: signingConfigs["debug"]），可安装但非正式发布签名。
  - 版本号由 lib/scripts/build.ps1 基于 commit 数自动生成，pubspec 的 version 仅作前缀。

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
  - 代码大量使用 dot-shorthands（`.paused` 等枚举简写），stable Dart 3.9.x 无法解析；需要 dev 渠道 3.14 SDK，已安装于 /opt/dart314/dart-sdk/bin/dart。
  - 语法校验命令：`/opt/dart314/dart-sdk/bin/dart format --output=none <file>`；注意它只解析语法，不检查符号/导入，UI 文件仍需人工核对 material 导入。
  - pubspec.yaml 固定 flutter: 3.47.5、sdk >=3.13.0，CI 的 subosito/flutter-action 通过 flutter-version-file 读取。
