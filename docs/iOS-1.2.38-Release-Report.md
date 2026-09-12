# iOS 1.2.38（59）发布记录

## 授权与来源

- 2026-09-12 用户要求打包提交 App Store，并确保新增定时/阅读设置支持多语言。
- 使用 `submit-castreader-ios-to-app-store` 技能；只从指定发布工作树 `/Users/xuxuheng/Documents/.worktrees/CastReader-reading-resume-real-libraries-20260909` 构建。
- 源码 HEAD `abc35c66481697a9aee13aaed40af4af74de99eb` + 已有集成补丁/新增文件；包含发布基线 `b6dd4d7`。没有用旧主目录源码覆盖。
- App Store 实时检查：1.2.37 `READY_FOR_SALE`，最高上传 Build 58，无活动 Review Submission；本次选 1.2.38 / 59。
- 基线版本 ID：`e7f30c6a-f42a-4702-9a7f-8525577e00f8`；基线 App Info：`533af389-b786-4148-8dd0-239ea489b1bd`。
- 商店标题、副标题、既有描述/关键词/截图等保留；本次更新 11 地区语言的 What's New，沿用审核后自动发布。

## 发布范围

- 更多菜单、三滑杆阅读设置图标、共享 Sleep Timer 与到期防自动复播。
- App 本地字号/字体/行距与 Kindle 原生字号桥接，既有平台设置接入。
- 微信读书统一桌面模式、封面/简介开读准备与中文短页语言识别修复。
- 发布前补齐微信读书提示/取消的应用语言注入；指定停止日期与分钟数量遵循应用选择的 locale。
- 不增加新界面语言种类：App 仍为英、简中、日、西、法、德、巴葡、意、印地语 9 种；商店 11 地区语言额外覆盖繁中与墨西哥西语。

## 当前状态

**已提交 App Store 审核。** 2026-09-12 21:01:18（上海时间），版本和 Review Submission 均回读为 `WAITING_FOR_REVIEW`。不是仅上传或保存草稿；尚未获 Apple 审核通过。

- 新版本 ID：`cc42d487-9da6-49e5-b36d-357c6c94f4ca`（`WAITING_FOR_REVIEW`）。
- Build：`59`，ID `d69b4e1b-6e6b-47ee-a038-1efe7e1ed02a`，`VALID / APP_STORE_ELIGIBLE`；预发布版本关系核对为 `1.2.38 / IOS`，加密声明 `usesNonExemptEncryption=false`。
- Review Submission：`c232f7da-979c-4e93-bec7-91ba431bb284`（`WAITING_FOR_REVIEW`），只包含本次版本一个审核项。
- Apple 提交时间：`2026-09-12T13:01:18.165Z`。
- 待审 App Info：`057ada58-395d-44c7-93f4-eda9f682a11c`。
- 发布方式：`AFTER_APPROVAL`（沿用上一版，审核通过后自动发布）。
- Xcode 于 2026-09-12 20:56:33（上海时间）报告 `Upload succeeded` / `EXPORT SUCCEEDED`。上传完成后等到精确 Build 可用于 App Store 才绑定送审。
- 本轮未再次安装 iPhone；本记录是 App Store 发布验证，不能据此把模拟器测试写成真机测试。

## 验证证据

- 全量单元测试：1616 项，1609 通过，0 失败，7 跳过。结果：`/tmp/CastReader-1238-unit.xcresult`。
- 跳过项：3 项 StoreKitTest 购买环境不可用（`notEntitled`）；4 项按需手动启用的在线测试（解读、Google Play Books、服务线路、YouTube）。本轮未改动支付实现，不能据此宣称完成了支付或全部在线平台真机回归。
- 新增本地化测试已通过：37 个相关文案在全部 9 个实际语言资源包中存在；停止时间按指定 locale 格式化；微信读书提示与取消按钮使用各应用语言。
- 界面回归：11 项全部通过，0 失败、0 跳过。包含 Kindle 设置的 9 语言 × 深浅色 × 普通/辅助大字号；更多菜单、定时设置与本地阅读设置的 9 语言；定时防复播、后台解读到期与位置恢复。结果：`/tmp/CastReader-1238-ui.xcresult`。
- 已导出 UI 证据至 `/tmp/CastReader-1238-ui-attachments`，`manifest.json` 对应测试名/图片。人工复核英文更多图标、中英停止日期差异、印地语定时/设置、德语设置与 Kindle 深色辅助大字号截图，未发现阻断项。截图中的测试控制条仅属于测试 fixture，不是商店界面。
- 商店 11 地区 What's New 已回读核对；其余描述、关键词、宣传文本和链接与 1.2.37 一致。原审核联系人、无需演示账号设置保留。
- 送审前独立审计 `errors=[]`：Build 绑定正确，11 个 App Info/版本地区语言齐全，标题/副标题与基线完全一致；可选 Promotional Text 沿用空值，未为填空而新写营销文案。
- 送审后再次审计 `errors=[]`：版本仍为 `WAITING_FOR_REVIEW`，Build 仍为 `VALID / APP_STORE_ELIGIBLE`，标题/副标题保留检查通过；另行 GET Review Submission 确认其状态也是 `WAITING_FOR_REVIEW`。
- 既有中英文隐私政策/条款链接均可访问（最终 HTTP 200），未修改声明内容。
- 继承截图：9 个地区各 5 张 `APP_IPHONE_67`（1290×2796），均 `COMPLETE`；繁中、墨西哥西语使用主语言回退。本轮没有重新制作或上传截图。

## 归档与源码指纹

- 归档：`build/CastReader-1.2.38-59.xcarchive`（本工作树内）。
- 独立 DerivedData：`/tmp/CastReader1238ArchiveDerivedData`。
- 归档日志：`/tmp/CastReader-1238-archive.log`；源码检查清单：`/tmp/CastReader-1238-source-manifest.log`。
- 主 App、Share Extension、Widget 的归档版本均为 `1.2.38 (59)`；未包含 Safari 扩展。
- 归档 App 签名完整性检查通过；Xcode 导出后已对最终分发 App 及两个扩展回读 `get-task-allow=false`，深度/严格签名检查通过，主 App 签名链为 Apple Distribution → Apple Worldwide Developer Relations Certification Authority → Apple Root CA。
- 分发 IPA：`build/CastReader-1.2.38-59-AppStore.ipa`（由本次 Xcode 上传管线的 Packages 目录留存）。SHA-256：`b1ddf9e304fdb6817e448a06321b1257e59cfcb07389d08fb97e027a6ce1c77c`。
- 上传日志：`/tmp/CastReader-1238-upload.log`；构建处理日志：`/tmp/CastReader-1238-build-processing.log`。
- 商店审计：`/tmp/CastReader-1238-asc-audit-before.json`、`/tmp/CastReader-1238-asc-audit-after.json`；送审预演与回读：`/tmp/CastReader-1238-review-dry-run.json`、`/tmp/CastReader-1238-review-submission.json`。
- 非阻塞接口限制：当前 API key 读取 `buildUploads` 集合返回 HTTP 403；按发布 SOP，以 Xcode 上传成功 + 精确 Build 的 `VALID / APP_STORE_ELIGIBLE` 状态作为上传验证门槛，不修改账号权限或合规声明。
- 主可执行文件 SHA-256：`b03e3fc780e94ae974b02911757cc046544cc87f48b3b7d91284515965af8f91`。
- 归档前 tracked patch SHA-256：`82c5c78ce28c8dad212261e07cb4aac9d0784a6604873353d0e906c38b7f530e`；新增 Swift 文件和脚本的独立 SHA-256 见源码检查清单。
- 37 个定时/设置相关字符串在归档中全部 9 个 `.lproj/Localizable.strings` 中存在。

## 本次补充修复

- 微信读书 DOM 提示和取消文案通过安全参数传入 JavaScript，使用应用选定语言，不再硬编码中文。
- 定时的停止日期、分钟数量显式使用应用 locale，覆盖系统语言与应用语言不同的组合。
- 集成构建脚本不再覆盖为旧的 `1.2.37 / 58.25`，正式版本以工程配置为准。
- 阅读设置图标继续使用三滑杆 `slider.horizontal.3`，不使用可能本地化成“格式”的文本字形。
