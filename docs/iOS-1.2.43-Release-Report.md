# iOS 1.2.43（65）通用 iPhone / iPad 发布记录

状态：发布准备与验收中，尚未上传、尚未送审。不得将本记录视为已发布。

## 正式合并与功能保留

2026-09-21 从远端重新获取 `main`，最新为 `8298f84`。ASC 同时确认 1.2.42（64）为 `READY_FOR_SALE`，没有其他活动审核单。新发布分支 `codex/ios-release-1.2.43` 从该提交建立，以双亲合并 `e2b3878` 纳入整个 `codex/ipad-adaptation`（`bcd9778`）。合并无冲突，合并结果与 iPad 功能分支的树完全一致，不是从孤立旧分支打包。

- iPhone 应用发布源码 `1ce1e56` 与 1.2.41 完整发布增量 `94499d2` 均为祖先。
- 保留既有语音/声音发现、社区与私人声音、换声续播、额度隔离、EPUB 目录与插图、PDF 原页/OCR、Kindle 离线、书架恢复、更多/Aa/定时及播放器失败恢复。
- 必备提交 `64c2dbd`、`633f6bb`、`ad4b885`、`48998e7`、`f94b41d`、`9935c6d`、`94499d2`、`d4e427c`、`d165045`、`1ce1e56` 的祖先门禁通过；新增 7 个 iPad 功能提交全部包含。
- App / Share Extension / Widget 均为 1.2.43（65），支持设备族 `1,2`。相同 Bundle ID `com.same.castreader`、相同商店 App ID `6757636395`，同一个下载同时支持 iPhone 与 iPad。
- iPad 支持四方向旋转、按窗口宽度布局、多窗口会话、导入、原生与商业阅读器、书架和播放控件。保持用户确认的移动端 Safari 不在发布范围。
- 源码身份与逐文件摘要保存于 `reports/ios-release-1.2.43/`。原 iPad 验收详情见 `docs/CastReader-iPad-Delivery-2026-09-21.md`。

## 验收范围与状态

已保留 iPad 各模块与 Kindle / Google Play Books / Kobo / 微信读书实际账号验收证据；最终共享平台回归 276 通过。O’Reilly 没有可用绑定账号，不声称新增真实在线验收。合并没有改变这些已验证功能的源码；版本与发布配置另行验证。

本版执行账号保留的广泛单测，显式排除会退出真实账号的 `PaymentTests`，保留未执行与外部样本跳过记录。真机 iPhone 使用正常开发签名候选，实际 API 与播放验收进行中，模拟器结果不替代真机核心门禁。

| 地区/输出语言 | R-K | R-C（vl/vc） | E-K | E-C（vl/vc） |
| --- | --- | --- | --- | --- |
| CN / zh | NOT_RUN | NOT_RUN / NOT_RUN | NOT_RUN | NOT_RUN / NOT_RUN |
| International / en | NOT_RUN | NOT_RUN / NOT_RUN | NOT_RUN | NOT_RUN / NOT_RUN |

现有且唯一启动的模拟器为 `BFCF61DE-9C45-4467-8996-6F4E03AE7725`，保留账号、各平台绑定和缓存。真机为已配对 iPhone 15 Pro Max。

## 商店资料与构建计划

- 已保存当前 ASC 11 语 App Info、11 语版本文案及 9 组共 45 张 iPhone 截图快照。
- 保留标题、副标题、关键词、推广文字、原有描述与有效 iPhone 截图；仅在 11 语描述增加 iPhone/iPad 通用支持段落，更新 What's New，并新增 iPad 物料。
- 不修改价格、订阅、地区、隐私、年龄分级或法律声明。发布方式沿用审核通过自动发布。
- Xcode Apple Accounts 中已看到正确团队及证书/设备权限，正常签名构建成功；正式上传凭据仍以 export 返回为准。
- Preflight 已通过；独立构建目录 `/tmp/CastReader1243Device`，归档/上传必须在核心门禁通过后执行。
