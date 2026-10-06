# CastReader for Mac 首版 App Store 提交

- 任务：提交 Mac App Store 并正式送审。用户明确要求停止反复功能测试，优先证书、签名、上传与 For Mac 商店物料。本轮不声称重新完成全功能验收。
- 产品：国际 Mac 产品配置；与 CastReader for Safari 是独立应用。此次在既有 iPhone/iPad App Store 记录中新增 MAC_OS 平台，不覆盖 Safari 应用。
- App：6757636395 / com.same.castreader；团队 KQW6UNZE8J。
- Mac 1.2.47 (73)，主应用、分享扩展、小组件均为 73；iOS 保持 72。
- 最低 macOS 14.6；主应用及两个扩展均包含 arm64、x86_64。

## 源码与归档

- 工作树：`/Users/xuxuheng/.codex/worktrees/castreader-mac-parity/CastReader`，分支 codex/mac-parity。
- 基础提交：09456f1979cc14ca19977ede4b1edde043c5f840，本次提交完整保存此前 Mac 适配增量，实际送审源码以冻结摘要为准。
- 精确来源：source-hashes.json 中 327 个应用/工程文件 SHA-256；上传后已核对无变化。最近离线双栏和侧栏修复的验收源码摘要一致。
- 归档：`/Users/xuxuheng/Documents/CastReader-Releases/Mac-1.2.47-73-20261006/CastReaderMac-1.2.47-73.xcarchive`。
- 本地安装的是该归档中的正常 Release 73。之前测试包备份在同级 `CastReaderMac-before73.app`，用户数据保留。
- 严格签名、App Group 描述文件、三组件版本、架构、本地化资源及 54 项夹具标记排除通过。未重新运行长功能测试。

## 证书和上传

- Xcode 自动管理 App Store 分发签名。已建立主应用的 Mac Catalyst Team Store 描述文件和两个扩展的 Mac Team Store 描述文件；没有吊销证书。
- 首次导出在苹果证书查询超时后失败，尚未传包；复用同一归档重试成功。
- 官方 Xcode upload 成功：2026-10-06 22:04:31 Asia/Shanghai。
- Build / upload receipt：898d3508-7a23-40b0-9718-78f1f6ae8d44。
- 苹果状态：VALID / APP_STORE_ELIGIBLE；上传回执 COMPLETE，errors / warnings 为空；MAC_OS / 1.2.47 / 73。
- 版本 ID：b4c6afe6-bf93-475e-ae52-0af7b5bee9ab，已绑定该构建。

## 商店物料

- 十一种商店本地化：en-US、zh-Hans、zh-Hant、ja、es-ES、es-MX、fr-FR、de-DE、pt-BR、it、hi。
- 基于当前已发布文案制作 Mac 专用介绍；移除 iPhone/iPad Safari 扩展说明和 O’Reilly 宣传；补充桌面窗口/快捷键/分享入口与 Google Play Books 支持。
- 名称、副标题、价格、订阅、地区、隐私与法律声明保持现状。保留空推广文本。首次 Mac 版本不填写更新说明。
- 三张真实 Release 73 窗口截图，2560×1600，APP_DESKTOP：朗读词高亮、解读原文标注、声音发现页面。样文为本次自有文字，无私人文档；不以模拟图片替代界面。
- en-US 截图三张 COMPLETE；其余十种商店语言使用英文截图回退，不冒称有本地化截图。
- 审核联系人继承当前发布记录；审核说明改为 Mac 登录、导入、朗读/解读、内购恢复、可选平台连接及分享/小组件路径；无独立密码演示账号。

## 已有验收的范围

- 最近离线双栏 OCR/高亮顺序、旧缓存迁移、侧栏切换修复：99 PASS / 0 FAIL / 0 SKIP，见 ../mac-parity-20261004/offline-columns-sidebar-20261006。
- 文件/Web Read/Explain、Kindle/Kobo/Google Books 核心和声音创建的此前证据保留，不把重复测试数量累计成新覆盖。
- 历史未闭环项仍如实保留：YouTube 新视频字幕曾被提供方限流；WeRead 最新付费登录态完整重测待会话；Mac 内购仅本地 StoreKit 验证，未执行真实付费交易。O’Reilly 按用户要求排除。
- 用户明确授权按当前核心范围完成首版送审。本轮生成自有样文只用于制作真实商店截图，不作为上述缺口的新验收结论。
- 截图后已恢复用户原选社区声音 Morgan Freeman by Tims，关闭展示播放并回到首页。

## 审核状态

正式提交成功。版本与 Review Submission 均为 **WAITING_FOR_REVIEW**。

- Submission ID：8288c105-fcc3-48c9-a573-33ae8ba760fc
- 苹果提交时间：2026-10-06T14:12:18.009Z
- 发布方式：AFTER_APPROVAL，审核通过后自动发布。
- 完整回读：submission.json；商店检查：store-audit.json。
