# iPhone Safari 网页朗读适配与真机验收

日期：2026-09-26。用户现已明确要求适配 iPhone Safari 并通过 iPhone 真机镜像测试，取代此前 Mac Safari 项目中暂不纳入 iPhone 的范围约定。本任务只建立本地测试候选，不代表已提交 App Store。

## 用户场景与交付边界

用户在 iPhone Safari 打开普通网页，希望直接在当前网页启动 CastReader 朗读。验收的核心链路是：启用 Safari 扩展、触发朗读、真实音频推进、当前词高亮、页面随朗读滚动，以及暂停、继续和停止。账号与 Pro 由包含扩展的 CastReader iOS App 提供，不让 Safari 内容脚本接触 OAuth 凭据。Global 与 CN 线路必须保持隔离。

首轮以普通文章网页为主要场景。Kindle 网页、受登录保护的站点、PDF 与长期后台播放分别记录实际结果；不能用普通文章成功推定这些场景成功。iPhone Chrome 无法安装桌面 Chrome 扩展；手机网页支持入口是 Safari Web Extension。

## 实施步骤

1. 从 iOS 1.2.45（67）已送审源码建立独立工作树，核对正式基线祖先和当前真机安装版本；本地测试候选使用 Build 68。保留现有 App、Share、Widget 代码与设置。
2. 将已隔离验证的 Safari 原生目标、App Group 与专用 Keychain 会话投影、账号/Pro 跳转整合进当前 iOS 工程。使用当前扩展源码生成 iOS 专属 WebExtension 资源，并确认不包含 Mac 端旧 QuickRead key。
3. 跑 Safari 路由、原生会话、账号与 Xcode 工程合同检查，完成 iOS 签名构建；仅在设备版本和签名回读一致后覆盖安装本地测试包。
4. 通过 iPhone 镜像，在 Safari 中启用扩展并逐项操作普通网页朗读。以实际媒体播放、高亮词范围和滚动结果作结论；单纯出现按钮、HTTP 成功或静态测试不能算通过。
5. 针对真机发现的问题做最小修复，再重建并复测。记录测试网页、设备系统、构建源码及未覆盖项；测试通过后再考虑正式版本与 App Store 交付。

## 验收记录

设备：iPhone 15 Pro Max / iOS 26.7。进入本轮时安装 1.2.45（67），现已覆盖安装并成功启动本地测试包 1.2.45（68）；真机 Safari 的“管理扩展”中能看到 CastReader，但扩展开关仍关闭，等待用户对网页访问授权的确认。

- iOS Debug 真机签名构建成功；App、Share、Widget、Safari appex 版本/Build 对齐，Safari appex 的扩展点、App Group、专用 Keychain entitlement 和 WebExtension 资源均已回读。
- Safari 双区路由、会话及账号模拟合同通过；iOS Safari 发布资源门禁 177 项通过，Chrome/Safari 对齐门禁 263 项通过。发布门禁已适配 1.2.45 新的多窗口 `ReaderSceneContext` URL 入口。
- 专用 iPhone 15 Pro Max / iOS 26.5 模拟器中的 `SafariExtensionContractTests` 11 项全部通过，含真实签名 Keychain 读写、线路和账号边界、一次性跳转。
- 真机网页朗读、音频时钟、高亮、滚动、会员跳转、关闭重启仍为 **NOT_RUN**；上述静态与模拟器结果均不替代 Safari 真机验收。

源码与包标识：iOS 分支 `codex/ios-safari-iphone-20260926`，集成提交 `0bc80b8`、资源提交 `7463091`，基线 `ffc7c8f` 是当前候选祖先；扩展源码 `readout-desktop` 为 `76e3e58`，其多窗口路由门禁修订为 `c216af4`。已安装 Debug 包的 App 可执行文件 SHA-256 为 `35aa95d2e736ced7c7b2979cc5f2a080d40ce4c32e8414160ade49cf8c9e18f4`，Safari appex 可执行文件为 `a2c057ea88c4b699d63ce0159db89b3039c36d414a15e7a863b7b34006e0ca30`，打包 manifest 为 `e949f4d920c0a23765b3d2eeec4b03504a9e1e3621de129217abc399d7be9fd7`。
