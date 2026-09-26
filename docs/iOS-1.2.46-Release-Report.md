# iOS 1.2.46（68）Safari 发布记录

状态：**发布候选已合并、商店草稿已准备，尚未上传或提交审核。** 更新于 2026-09-27。

## 源码和设备支持

- 本轮 ASC 回读线上 1.2.45（67）为 `READY_FOR_SALE`，最大已上传 Build 67，无活跃审核单。线上源码在远端 `main` 的 `baccb69aacf845b348347015dd84af7879ae006d` 中。
- 从该远端主线建立 `codex/ios-release-1.2.46`，以双亲合并 `e1e10d988adc9d7612add70ebf37ecae6759aacf` 纳入 Safari 分支 `2b26f99`；版本配置提交 `9960e13`。此前已发布的 `b6dd4d7`、`fe64420`、`66fc2e1` 和全部基线脚本要求的提交均保留。
- **正式主线已快进并推送至 `09bb80e`**，包括集成、版本、测试/商店记录和包装校验脚本。此后的报告更新不改应用源码。基于测试和真机包的 390 文件清单再次逐文件核对全部一致，主线不包含主目录旧分支的未提交改动。首次 Git 传输受本机代理影响（扩展分支 HTTP 408），回读旧远端引用后使用仅本次命令的直连重传成功，没有强推或改系统代理。
- App、Share、Widget、Safari 的 Debug / Release 全部统一为 **1.2.46（68）**，`TARGETED_DEVICE_FAMILY=1,2`。Safari bundle ID 为 `com.same.castreader.SafariExtension`，扩展点 `com.apple.Safari.web-extension`，由 App 依赖并嵌入 PlugIns，沿用 App Group 和专用 Safari Keychain。
- 原生 TTS、QuickRead、播放器、Kindle/WeRead/Kobo 等实现没有被旧分支替换。原生差异仅 Safari 会话投影、账户边界清理、URL 导航、设置跳转，以及对应工程、entitlements 和资源。
- 扩展源码提交 `31f8c7b`；完整 WXT iOS 输出与原生资源同步验证通过。生产 `content.js` SHA-256：`192e07f0e15b8ce27ec088b2e62e17ecdb5a9491235e8b2243153e523d333a75`，与前轮两台模拟器和用户手机已安装候选的修复脚本相同。没有临时 QA textarea 探针。
- 390 个应用/组件/工程文件的清单摘要：`151ee7dcacdf8ba4502637529ee48bec5116f17bfaac2a1924b6a417cd2dee9d`。逐文件清单保存在下方私有证据目录。

## Safari 和本地检查

- `build-voice-toc-integration.sh --check`、`verify_safari_extension.rb`、发布 preflight `--include-safari` 均通过。Safari 在未显式启用该参数的发布预检中仍默认禁止；启用后增加第四组件及 iPhone/iPad 入包合同检查，不豁免真实播放验收。
- 九种扩展语言的键和占位符一致。11 语商店文本均符合长度限制，最长描述 3,867 字符。
- 沿用同一应用源码/配置的有效 Safari 验证：Safari 180 项、Chrome 一致性 263 项，类型检查、折叠章节/视口恢复/像素回归；实际 iPad WebKit 浅深网页 × 浅深系统 × 词句绘制 8/8 通过。
- 最新普通包在 iPhone、iPad 模拟器的 Safari 真实云端朗读回归已通过，涵盖高亮、滚动、跨段、暂停/恢复、换音色、停止清理；iPhone 最终轮实际从 1x 改为 0.75x。iPad 最终轮选择的是原本的 1x，实际变速证据来自此前完整回归。详见 [Safari 高亮修复与验收](Safari-Highlight-Repaint-2026-09-26.md)，保留非 canonical Wikipedia URL 读到导航文字及未做声学逐字审校等限制。
- 2026-09-27 00:50 完成候选全量隔离单测：**1,890 PASS、0 FAIL、8 SKIP**，整轮 `TEST EXECUTE SUCCEEDED`，结果 `evidence/unit-tests/tests.xcresult`。跳过为既有需要显式启用真实服务/本机样本的用例，不当作真实核心格通过；PaymentTests 仍按原隔离脚本显式排除。使用专用模拟器应用/Keychain/App Group，没有在用户手机的正式 App 内执行会改变账户状态的单测；完成后已卸载本轮创建的模拟器隔离应用。
- Release 真机编译 `BUILD SUCCEEDED`。四组件代码签名 `--deep --strict`、版本/设备族、专用 Keychain/App Group、加密声明、九语编译资源、最新 content.js 哈希检查通过。`verify_release_no_shelf_fixtures.py` 扫描 204 文件 / 54 个标志，Debug 阳性对照有效，Release 夹具命中 0。`CastReaderInternalDistributionControlsEnabled` 实际为字符串 `NO`；第一次人工审计只接受 Bool false 而触发断言，随后依项目既有校验合同同时接受 false/NO，未修改二进制或降低产品要求。

## 最新真机包

- 正常 **Release 配置、开发签名** App：`/Users/xuxuheng/Desktop/CastReader-Safari-Release-20260927/DeviceDerivedData/Build/Products/Release-iphoneos/CastReader.app`。这不是 App Store 分发归档。
- 00:49:15 后成功安装到已配对的 iPhone 15 Pro Max，bundle `com.same.castreader`，容器 `03A51D29-10B2-47E4-9DB0-4F40F735DFAC`；设备应用清单回读版本 **1.2.46**，包内四组件 Build 均 **68**。
- 00:50:03 请求启动新包，被 iOS 以 `Locked / Unable to launch ... because the device was not, or could not be, unlocked` 拒绝。未把安装成功计为真机播放通过，也未声称当前 Safari 标签页已经重新加载新安装容器。此前已运行候选与这次包的扩展脚本哈希相同，但仍需启动后验收。
- 手机第二个同名应用是旧隔离检查包 `com.same.castreader.releasechecks1244` 1.2.44；没有删除用户手机里的应用。当前正式 bundle 的新包和旧检查包身份清楚分离。

## 核心服务门禁

当前缺少本候选的完整真机核心验收。1.2.44 的真实两区记录作为历史参考保留；1.2.45 曾由用户单独明确豁免最终真机验收而直接送审，该历史授权不自动作为 1.2.46 的通过证据。

| 地区 / 语言 | R-K | R-C（vl / vc） | E-K | E-C（vl / vc） |
| --- | --- | --- | --- | --- |
| CN / zh | NOT_RUN | NOT_RUN / NOT_RUN | NOT_RUN | NOT_RUN / NOT_RUN |
| International / en | NOT_RUN | NOT_RUN / NOT_RUN | NOT_RUN | NOT_RUN / NOT_RUN |

Safari 的真机连续播放、高亮/滚动及新包账户/Pro 衔接也仍需补验。手机已配对且无需输入密码，但本会话电脑控制工具未提供，系统对 AppleScript 辅助控制明确返回 `osascript is not allowed assistive access (-1719)`。前轮真机 XCTest 在运行方法前被 `dtxproxy` 通道拒绝，不能记为产品测试 PASS。已向用户请求恢复电脑控制，继续完成独立的编译、单测和商店资料准备。

按 `submit-castreader-ios-to-app-store` 技能和项目核心服务 SOP，缺失的真实验收阻止上传/正式送审；静态预检、模拟器截图或商店草稿不改变这个结论。

## App Store 草稿

- 版本 ID：`f835f4df-b17b-4c1b-a71f-50de22006ae7`，状态 `PREPARE_FOR_SUBMISSION`。
- 待发布 App Info：`a3a05161-de19-4dd4-8c99-363187f758c7`；线上基线 App Info：`62ad576b-3ab7-4759-bf88-05840a7647eb`。
- 已 PATCH 并回读 11 语 `description` 和 `whatsNew`：仅增加 Safari iPhone/iPad 功能和启用说明。标题、副标题 11/11 保留，关键词、推广文字、支持链接、营销链接逐字段未变。文案：[What's New](AppStore-Whats-New-1.2.46.json)、[Safari 描述增量](AppStore-Safari-Description-1.2.46.json)、[完整当前文案](CastReader-AppStore-Metadata-1.2.46.md)。
- 审核说明将旧版本开头摘要压缩为本版 Safari 启用、网站授权和核心控件测试步骤，保留账户/审核资料及其它审核说明；共 3,939 字符，回读一致。首次尝试因追加后超长而在本地拒绝，未提交超长内容。
- 现有 55 张截图保留，草稿逐张回读全部 `COMPLETE`；`zh-Hant`、`es-MX` 沿用主语言回退。不改价格、订阅、地区、隐私、年龄分级、类别或法律声明；继承审核后自动发布 `AFTER_APPROVAL`。
- 尚无本版上传 Build ID、归档或 Review Submission ID。没有宣称草稿等于送审。
- 最终精确版本回读仍为 `PREPARE_FOR_SUBMISSION / AFTER_APPROVAL`，没有正式提交审核。

## 证据与续跑

私有原始证据目录：`/Users/xuxuheng/Desktop/CastReader-Safari-Release-20260927/evidence/`。包含一次 ASC inspect、商店基线快照、草稿创建结果、预检、应用源文件摘要、元数据回读、测试日志和编译日志。审核账号、会话和凭据不写入仓库。

恢复真机控制后补齐受影响的真实核心和 Safari 验收；保持本版 Build 68 及已有商店草稿，从未完成步骤继续。通过后，基于正式主线做不可变 Release archive、官方 Xcode 上传，等待精确 Build `VALID / APP_STORE_ELIGIBLE`，绑定并 audit，再正式提交并回读版本与审核单均为 `WAITING_FOR_REVIEW`。

参考 [Apple 的 Safari 扩展分发文档](https://developer.apple.com/documentation/safariservices/distributing-your-safari-web-extension)：iOS 扩展随包含它的签名 App 分发。本版设备支持由通用 App、Safari target 和嵌入扩展配置共同保证；没有把 macOS 独立应用当作 iPhone/iPad 安装包。
