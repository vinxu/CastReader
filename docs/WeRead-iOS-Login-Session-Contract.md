# 微信读书 iOS 登录会话合同

## 目的

CastReader 在同一台 iPhone 上展示微信读书二维码，用户截图后切换到微信扫码，再返回 CastReader。这个流程能否成功，取决于 CastReader 是否始终保留**生成该二维码的同一个微信读书页面与登录 UID**。

本合同约束微信读书绑定页的生命周期。任何后续主题、本地化、布局或登录优化都不得破坏这些规则。

## 核心事实

微信读书二维码不是一个可脱离页面使用的静态凭证。二维码、页面里的轮询请求、登录 UID 和 Vue 页面状态属于同一个登录会话。

因此，“微信显示登录成功”只证明用户扫描的那个 UID 已成功，不代表 CastReader 当前 WKWebView 仍在观察同一个 UID。如果 WKWebView 在用户扫码期间发生导航或重载，它会生成新的登录 UID；此时旧二维码仍可在微信里显示成功，但新页面不会获得登录态。

## 强制规则

从二维码首次可见开始，到登录页完成认证并进入书架为止：

1. 必须保留同一个 `WKWebView` 实例、同一个页面 document 和同一个登录 UID。
2. 禁止调用 `webView.load`、`reload`、`goBack`，禁止重建 WKWebView。
3. 禁止因系统深浅色变化、前后台切换、几何尺寸变化或 SwiftUI 重绘而重新导航。
4. 主题 cookie 与带主题参数的 URL 必须在首次加载前准备完成。
5. 首次加载以后，主题变化只能更新 `overrideUserInterfaceStyle`；页面主题可在用户下一次主动打开绑定页时生效。
6. 应用进入后台时允许 WebKit 暂停 JavaScript/网络轮询，但不得替换页面。回到前台后应在原页面恢复观察。
7. 不得将二维码重新生成视为“恢复登录”。一旦更换 UID，用户截图中的二维码立即成为旧会话。

## 未登录入口体验

确认当前页面未登录后，绑定页必须同时完成两件事：

1. 通过微信读书 Vue `LoginModal.show` 的语义入口自动展示官方 UID-backed 二维码，不要求用户再寻找或点击网页里的“登录”。
2. 底部展示 CastReader 原生引导栏，说明“截图二维码 → 打开微信扫一扫 → 从相册识别 → 返回后自动进入书架并同步”。

自动展示只能调用当前 document 中微信读书自己的登录组件，不得通过导航、重载或创建第二个 WKWebView 实现。只要当前会话已经获得 UID，后续页面观察必须复用该二维码，不能再次调用 `show` 替换它。

微信读书首页登录按钮的生成 class 和标签类型并不稳定。自动入口应优先使用 Vue 暴露的 `LoginModal.show`；若新版页面不再暴露该实例，则回退查找当前 document 中**可见且文本精确为“登录”**的元素。优先点击其 `a/button/[role=button]/[tabindex]` 祖先；没有语义祖先时点击文字节点本身，让事件冒泡给 Vue 外层处理器。这与用户手动点击是同一语义动作，且仍须遵守“不导航、不重载、不重复点击”的约束。

登录成功后，引导栏应立即隐藏；进入书架并完成扫描后，同一位置切换为“检测到 N 本书 + 同步”操作栏。

## 登录状态判断

登录成功必须以微信读书官方页面进入已认证状态或能够读取书架为依据。

以下展示类 cookie 不能单独证明已认证：

- `wr_avatar`
- `wr_name`
- `wr_gender`
- `wr_theme`
- `wr_localvid`
- `wr_fp`

诊断日志只能记录 cookie 名称、页面可见性、导航次数和认证布尔状态，不得记录 cookie 值、登录 UID、token 或其他凭据。

## 2026-07-23 真机事故复盘

现象：

- 微信内置浏览器显示扫码登录成功。
- 返回 CastReader 后二维码关闭或页面仍未登录。
- 反复清缓存、重装 App、重新扫码均无法稳定解决。

真机日志最终确认：

1. 二维码可见时发生第一次 `navigation-finished`。
2. CastReader 进入后台后，在 `visibility=hidden` 状态又发生第二次 `navigation-finished`。
3. 第二次导航替换了正在轮询的登录页面和 UID。
4. 用户随后扫描的是第一次页面的截图，因此微信显示成功；CastReader 已经在等待第二个 UID。
5. 第二次导航来自绑定页 `updateTheme(isDark:)`：SwiftUI 在生命周期变化时重新发布颜色方案，代码因此重新加载当前 URL。

修复：

- 主题只在首次加载前通过 cookie/URL 准备。
- `updateTheme(isDark:)` 在页面已加载后仅设置 `overrideUserInterfaceStyle`，不导航、不取消轮询。
- 同一台 iPhone 截图扫码、切回 CastReader 后登录恢复正常。

这与 Xcode 或 iOS Runtime 下载/构建问题无关；两者当时同时出现，但属于独立故障。

## 自动化回归要求

`scripts/test-weread-ios-contract.mjs` 必须保证绑定页的 `updateTheme(isDark:)`：

- 包含 `overrideUserInterfaceStyle`；
- 不包含 `webView.load`；
- 不包含 `reload`；
- 不调用 `WeReadNativeTheme.prepare`；
- 不取消 `loginPollingTask`。

同时必须保证自动二维码入口：

- 调用 `WeReadWebScripts.openLoginQRCode`，由官方 Vue 登录组件生成二维码；
- 显示九语本地化的原生底部引导栏；
- 不调用 `webView.load`、`reload` 或 `location.assign/replace`；
- 已获得有效 UID 后停止展示重试，不创建第二个登录会话。

真机发布前还需执行一次同机登录回归：

1. 清除微信读书登录信息。
2. 打开绑定页并确认二维码出现。
3. 截图，切换到微信，扫描相册中的二维码并确认成功。
4. 返回 CastReader。
5. 确认没有第二次页面导航，原页面进入已登录书架。
6. 确认底部显示可同步书籍数量，点击同步后保存本地书架并关闭绑定页。

## 与阅读页主题逻辑的边界

本合同只禁止**登录绑定阶段**的主题重载。已登录后的微信读书阅读页可以按照阅读页自己的主题与版式合同重新渲染，但必须继续遵守 TTS 停止、位置恢复和高亮重新对齐规则，不能复用绑定页的登录会话处理方式。
