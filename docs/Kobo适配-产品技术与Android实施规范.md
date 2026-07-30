# Kobo 适配：产品、技术实现与 Android 实施规范

> 版本：1.0  
> 日期：2026-07-30  
> iOS 参考实现：CastReader iOS  
> Android 落地仓库：`/Users/xuxuheng/Documents/CastReader-Android`
>
> 本文是 Kobo 平台专章。所有实时网页阅读平台共同遵守的页面身份、页尾音频、
> 高亮、预加载、生命周期、日志和验收合同，以
> [`实时网页阅读平台接入标准.md`](./实时网页阅读平台接入标准.md) 为最高约束。
> Kobo 不得复制一套新的 TTS、解读或播放器状态机。

## 1. 目标和结论

Kobo 接入必须形成完整产品闭环：

```text
选择 Kobo
  → 打开 Kobo 官方网页登录/书架
  → 持久保留网页登录态
  → 同步可信书架元数据
  → 从 CastReader 书架打开 Kobo 官方阅读器
  → 当前页朗读 / 当前页解读
  → 自动上一页、下一页
  → 手动翻页后按原播放意图处理新页
  → 保存本地书籍锚点并继续阅读
```

Kobo 与 Google Play Books 的共同点：

- 都是第三方商业网页阅读器，正文和版权控制继续由平台负责；
- CastReader 只读取当前合法可见页，不保存正文；
- 使用 DOM Range 做字符定位、高亮和解读 marks；
- 朗读、解读、预加载、页尾和翻页身份复用同一 native 协调器；
- 绑定、书架和阅读器必须共享持久网页会话。

Kobo 的平台差异：

- 正文位于 `readnow.kobo.com` 顶层页面下的多个**同源 `srcdoc` iframe**；
- 一个 iframe 内可能包含多页 CSS columns；
- 页面会预加载后续章节 iframe，DOM 已存在不代表用户正在看；
- Kobo 手机壳不总是暴露上一页/下一页按钮；
- 官方阅读引擎可以暴露当前页范围及按全书百分比跳转能力；
- Kobo 阅读 URL 的 UUID 标识书籍，但通常不携带视觉页位置，进度主要由 Kobo 账号同步。

## 2. 产品需求

### 2.1 入口

1. Kobo 与 Kindle、微信读书、Google Play Books 同级展示。
2. 首次绑定书库引导“平时在哪里看书”中包含 Kobo。
3. 已绑定且有书时，首页展示 Kobo 书架摘要；点击进入完整书架。
4. 设置中展示 Kobo 绑定状态和“解除 Kobo 绑定”。

### 2.2 绑定和登录

绑定页状态必须明确且连续：

| 状态 | 用户看到的内容 | 允许操作 |
|---|---|---|
| 打开 Kobo | Kobo 官方网页 + loading 文案 | 关闭 |
| 未登录 | 登录说明 + 原生“登录”按钮 | 登录 |
| 官方认证中 | 官方认证页面使用完整空间 | 关闭 |
| 返回书架 | “正在同步 Kobo 书架” | 等待 |
| 书架可信稳定 | “找到 N 本书，可以同步” | 同步 |
| 已同步 | “已同步 N 本书” | 完成 |
| 可恢复错误 | 原网页仍可见 + 简短错误 | 重试 |

硬要求：

1. 原生登录按钮必须触发 Kobo 当前页面的真实登录入口，不能只关闭弹层。
2. 进入 Rakuten、Google、Apple 或邮箱认证页面后，底部登录卡必须隐藏，不能遮挡密码、
   Passkey、验证码或其他认证内容。
3. 登录弹窗必须复用平台传入的 WebView configuration 和同一持久网页 profile。
4. 弹窗关闭、弹窗返回书架、主 WebView 自己返回书架三条路径都要收敛到书架扫描。
5. CastReader 不读取、不保存密码、Passkey、验证码、Cookie 或 OAuth token。
6. 原生 Google OAuth 登录不能替代 Kobo 网页中的 Google 登录。

### 2.3 书架

每本书展示：

- 真实书名；
- 真实作者，缺失时显示“未知作者”；
- 真实封面；无可信封面时才使用占位图；
- Kobo 进度文案，缺失时显示“尚未开始”；
- 最近打开时间用于本地排序。

支持：

- 首页最近阅读摘要；
- 完整书架；
- 按最近阅读、书名、作者排序；
- 书名/作者搜索；
- 封面持久缓存和预取；
- 账号切换时只替换 Kobo 本地数据；
- 从历史记录恢复同一本书。

### 2.4 阅读

朗读必须满足：

- 只读当前真正可见的 Kobo 文本；
- 词级高亮和音频同步；
- 当前页内流式生成；
- 能证明下一视觉页时预取下一页，否则只预取下一句；
- 当前页真实播放结束后自动翻到下一页；
- 新页稳定提交后继续播放；
- 最后一句不提前清高亮、不漏读、不重复；
- 手动翻页立即暂停旧页；
- 手势回弹恢复原页原位置；
- 手动翻到新页时，仅当手势前正在播放才自动继续。

解读必须满足：

- 输入是当前完整可见页；
- TTS 播放 LLM 讲解，不是再次朗读原文；
- marks 使用当前页原文的稳定字符坐标；
- 解读当前页完成后自动翻页并继续；
- 切换朗读/解读时转移播放器回调所有权；
- 旧模式的音频、marks、翻页请求和迟到回调不得继续。

### 2.5 阅读器视觉

1. Kobo 官方页面占满顶部导航和底部播放器之间的实际可用区域。
2. `WKWebView.pageZoom` / Android `WebView` 整体缩放保持 1；不能用缩小整个网页修正文大小。
3. 字号异常必须在章节 iframe 内规范 `text-size-adjust`，让 Kobo 自己重新分页。
4. 底部播放器与 Kindle 紧凑播放器同高、同布局。
5. loading 保留橙色按钮外形，只在按钮内部显示 spinner，并做短等待防抖。
6. 自动续页时是“翻页中/准备下一页”，不能闪出“播放完成·重播”状态。
7. 播放器不能遮住正文；阅读区域必须消费播放器实测高度和安全区。

### 2.6 体验指标

以下指标用于发现体验回退，不能替代正确性合同：

| 指标 | 目标 |
|---|---|
| 进入书架后的状态反馈 | 约 100ms 内显示同步中，不等待十几秒才出现 loading |
| 首次 session probe | DOM commit 后约 200ms 内启动 |
| 手动翻页暂停 | 可信意图出现后约 100ms 内暂停旧音频 |
| 自动翻页发起 | 最后 media item ended 后约 100ms 内发送一次动作 |
| 页面稳定提交 | 至少约 420ms；一般动画应在 1.5s 左右完成，5.2s 为确认超时 |
| 短句间等待 | 短于约 300ms 不闪 loading；长静音必须显示明确等待状态 |
| 高亮交接 | 最后词不提前消失；新页稳定画面不残留旧页高亮 |
| 资源 | 连续打开五本书后仍只有一个活跃 reader 和一份播放器回调所有权 |

### 2.7 异常与恢复

| 异常 | 必须行为 |
|---|---|
| 登录取消或 Passkey 失败 | 保留 Kobo 官方“其他方式”，不循环、不清会话 |
| 登录 popup 关闭 | 回到主 WebView 并重新进入书架 |
| 网络失败 | 保留旧书架、Cookie 和锚点，显示可重试状态 |
| 书架扫描超时 | 不提交 0 本书，不删除旧书 |
| 阅读器约 15s 仍无可信正文 | 保留官方页面并显示明确可恢复错误，不能一直裸露白屏 |
| fixed-layout/canvas | 明确提示暂不支持 |
| 自动翻页无 transport | 停在当前页并结束本次 turn，同一 turn 不换动作重试 |
| Web 内容进程终止 | 重建 reader，恢复同一本书、模式和播放意图 |
| 页尾在后台到达 | 延迟到前台只执行一次物理翻页 |
| 可信账号切换 | 只替换 Kobo 本地书架、历史和锚点 |
| 解绑 | 只清 Kobo 本地状态，保留共享网页会话 |

## 3. 合规、隐私和支持边界

CastReader 可以：

- 在用户已登录且有权访问的 Kobo 官方网页中读取当前可见 DOM；
- 保存书名、作者、封面 URL、Kobo UUID、规范阅读 URL、本地进度摘要；
- 在当前页 DOM 上绘制临时高亮和 marks；
- 调用 Kobo 已加载页面自己的翻页语义。

CastReader 不得：

- 保存正文、Cookie、密码、验证码或认证 token；
- 绕过 Kobo 登录、DRM、地区或购买限制；
- 把公开商店页、预览页或推荐卡片冒充用户书架；
- 把屏外预加载章节当作当前页朗读；
- 在固定版式/canvas 书籍没有可靠 DOM 时朗读工具栏或伪造正文。

当前支持重点是 Kobo reflowable EPUB。若检测到只有 canvas、SVG、整页图片或 fixed-layout
而没有可信文本，必须明确显示“该 Kobo 固定版式书暂不支持”，不能降级为错误正文。

## 4. 可复用架构

```text
Kobo 绑定/书架 WebView
  └─ 持久网页 profile + 书架扫描 adapter

Kobo Reader WebView
  ├─ 平台 profile：UA、URL、origin、消息白名单
  ├─ Kobo DOM adapter：可见页、source range、signature、翻页、手势
  ├─ 通用 DOM bridge：高亮、marks、字符 Range
  └─ 共享 native coordinator
       ├─ 朗读 VM / TTS / 播放队列
       ├─ 解读 VM / LLM / marks 时间线
       ├─ 自动/手动翻页状态机
       ├─ 预加载 gate
       └─ 额度、播放器 UI、生命周期
```

平台专有代码只负责：

- 登录和书架 DOM；
- Kobo URL/UUID 校验；
- 当前可见页提取；
- 源字符坐标；
- 页面 signature；
- Kobo 物理翻页；
- 手动翻页意图；
- 平台诊断。

平台专有代码不得负责：

- 自己请求 TTS 或 LLM；
- 自己创建第二套 ExoPlayer/AVPlayer；
- 自己决定 Pro/额度；
- 自己维护独立的朗读/解读播放器 UI；
- 仅凭 URL 或“JS 调用没抛错”宣布翻页成功。

## 5. iOS 参考实现文件

| 文件 | 职责 |
|---|---|
| `CastReader/Models/KoboModels.swift` | 书、账号证据、URL、锚点和可信快照合同 |
| `CastReader/Services/KoboLibraryStore.swift` | 书架合并、账号隔离、进度、本地解绑 |
| `CastReader/Services/KoboWebScripts.swift` | 绑定 URL、导航白名单、登录入口、书架扫描 |
| `CastReader/Views/Kobo/KoboLibraryViews.swift` | 首页书架、完整书架、绑定和 popup 流程 |
| `CastReader/Services/LiveWebPlatform.swift` | Kobo 平台 profile 与消息安全 |
| `CastReader/Views/Reader/WebReaderView.swift` | 持久 profile、UA、脚本注入 |
| `CastReader/Services/WebReaderBridge.swift` | 共享朗读/解读/预加载/翻页协调器 |
| `WebReader/src/kobo.ts` | Kobo 当前页、预览、signature、翻页和手势 adapter |
| `WebReader/src/cr-bridge.ts` | DOM Range、高亮和 marks 的 owner-document 渲染 |
| `WebReader/src/entry.ts` | Kobo 顶层安装与共享 bridge 启动 |
| `WebReader/kobo-fixture-test.mjs` | 真实浏览器 Kobo DOM fixture |
| `CastReaderTests/KoboContractTests.swift` | URL、书架、账号、会话和 DOM 扫描合同 |

Kobo 当前暂时复用成熟 Google Books 私有 wire 名称：

```text
googleBooksTurnRequested
googleBooksTurnFailed
googleBooksPageChanging
googleBooksPagePreview
googleBooksSpeechPreview
googleBooksPreviewDiagnostic
googleBooksLocation

CR.gbNextPage / gbPrevPage / gbRefresh
```

每个 payload 都必须带 `source: "kobo"`。这是迁移兼容层，不代表 Android 应复制一套
Google 专有协调器；Android 应抽象平台 profile 或在现有 Google 协调器上增加 Kobo adapter。

## 6. 网页会话和导航

### 6.1 会话

iOS：

```text
KoboWebSession.websiteDataStore
  → GoogleWebSession.websiteDataStore
  → CommercialWebSession.websiteDataStore
```

绑定、书架、阅读器和登录 popup 使用同一持久 `WKWebsiteDataStore`。WebKit 仍按 origin
隔离 Cookie，但使用 Google 登录的不同平台可以复用已经建立的 Google 网页会话。

Android：

- 绑定、书架和阅读器使用同一 App WebView profile；
- 使用同一 `CookieManager`、DOM storage 和持久数据库；
- 不在 Kobo 解绑时调用 `removeAllCookies()`；
- 若提供“清除共享网页登录”，必须是单独的全局高风险操作，并提示影响平台。

### 6.2 UA 和 viewport

绑定页：

- 使用完整 Mobile Safari / Android Chrome mobile UA；
- 保留手机端官方登录排版。

阅读器：

- iOS 当前使用 desktop Safari UA，使 Kobo 暴露已验证的阅读器语义；
- `preferredContentMode` 仍为 mobile，CSS viewport 等于手机真实宽度；
- `pageZoom = 1`；
- 章节 iframe 内注入：

```css
html, body {
  -webkit-text-size-adjust: 100% !important;
  text-size-adjust: 100% !important;
}
```

Android 必须把“浏览器身份”和“视口大小”分开处理。若使用 desktop UA，不得同时制造
约 980px 的桌面 CSS viewport，再把整页缩小进手机。

### 6.3 URL 白名单

书架：

```text
https://kobo.com/library/books
https://www.kobo.com/library/books
https://www.kobo.com/<market>/<language>/library/books
```

绑定可经过：

- `*.kobo.com`
- `*.kobobooks.com`
- `*.rakuten.com`
- `*.rakuten.co.jp`
- `accounts.google.com`
- `appleid.apple.com`

阅读器只允许：

```text
https://readnow.kobo.com/<canonical-uuid>
```

拒绝：

- 非 HTTPS；
- user/password authority；
- 非 443 端口；
- `readnow.kobo.com.evil.example`；
- 缺 UUID、非法 UUID、额外 path segment；
- 编码后的 slash/braces；
- 另一本书 UUID 冒充恢复地址。

规范阅读 URL 丢弃 query 和 fragment，以 UUID 作为稳定书籍身份：

```text
stableID = "kobo:" + lowercaseCanonicalUUID
readerURL = "https://readnow.kobo.com/" + lowercaseCanonicalUUID
```

Kobo 当前主要从账号恢复阅读位置。本地 `pageFingerprint` 只用于恢复意图和诊断，不能作为
绕过 Kobo 官方进度的定位令牌。

## 7. 书架同步

### 7.1 可信证据

一次扫描至少返回：

```text
authRequired
authenticated
hasAccountEvidence
isShelfContext
isCompleteSnapshot
accountIdentitySource
books[]
```

`authenticated` 只有在以下条件同时成立时才为真：

```text
有可信账号菜单/退出入口
AND 当前是 /library/books
AND 页面不要求登录
```

账号原始证据在 native/store 前做 SHA-256：

```text
sha256:<64 hex>
```

邮箱原文不得保存。UI 最多保存非识别性的 `Kobo · example.com`；解析失败但像邮箱时只显示
`Kobo account`。

### 7.2 扫描

书卡定位不能只拿“Read Now”按钮的父节点。应向上寻找同时包含以下证据的最小书卡：

- 唯一 Kobo UUID；
- 可信书名；
- 作者；
- 封面；
- 书卡/列表项语义。

需处理：

- `readnow.kobo.com/<uuid>`；
- `/ReadNow/<uuid>`；
- `data-content-id` / `data-book-id`；
- `src` / `currentSrc` / `srcset` / `data-src` / `<picture><source>`；
- CSS `background-image`；
- `Read Now: Title`、`Continue Reading: Title` 等动作前缀；
- “Unknown author”等占位数据。

封面只接受 HTTPS，拒绝 `data:`、`blob:`、透明图、spacer、blank、pixel。

### 7.3 虚拟列表和稳定门槛

扫描脚本寻找页面或书卡祖先中的真实滚动容器，每轮向下滚动约 `max(82% viewport, 520px)`。

完整快照必须同时满足：

```text
已认证
AND 当前是书架
AND document.readyState != loading
AND 滚动到末尾
AND 没有 aria-busy / skeleton / loading
AND 书籍数量连续稳定
```

iOS 当前稳定门槛：

- 非空书架：4 次稳定末尾扫描；
- 空书架：10 次稳定末尾扫描。

空书架门槛更高，防止页面 hydration 期间误报“找到 0 本书”。

合并规则：

| 快照 | 新增/更新 | 删除旧书 |
|---|---:|---:|
| 未认证/非书架 | 否 | 否 |
| 部分快照 | 是 | 否 |
| 到末尾但未稳定 | 是（暂存） | 否 |
| 同账号完整快照 | 是 | 是 |
| 可信账号变化 | 重建新账号 Kobo 数据 | 清旧账号 Kobo 数据 |

如果原始扫描非空，但 URL/标题校验后变成空，不得视为可信空书架。

### 7.4 启动时机

不要等待十几秒才显示同步状态：

1. 主 WebView 导航开始/commit 到书架时立即显示“正在同步”；
2. `didCommit` / Android `onPageCommitVisible` 后约 80–120ms 开始 session probe；
3. 初期可每 250ms 探测，直到账号证据出现；
4. 进入真实扫描后每约 350ms 扫描并推进虚拟列表；
5. 超时显示可重试状态，不清旧书架、不自动解绑。

## 8. Kobo DOM 和当前页

### 8.1 页面结构

```text
readnow.kobo.com/<book-uuid>       ← 顶层 shell
  ├─ srcdoc iframe: 当前章节      ← 同源，可包含多页 CSS columns
  ├─ srcdoc iframe: 下一章节预载  ← DOM 有内容但通常在屏外
  ├─ 其他预载章节 iframe
  └─ reader footer / controls
```

只在顶层安装 Kobo adapter。不要向每个 srcdoc iframe 安装完整 native bridge，否则预加载
章节会争夺播放 owner。顶层可以直接访问同源 iframe DOM，并为其 owner document 创建 Range。

Android 若使用 document-start 注入：

- reader 主文档允许 Kobo bridge；
- 登录/书架页面不得暴露 reader native 能力；
- srcdoc iframe 不重复安装完整 adapter；
- native 消息通道只接受 `https://readnow.kobo.com/<同一本 UUID>` 的顶层消息。

### 8.2 可见 iframe

选择逻辑：

1. 枚举可访问且确实有段落文本的 iframe；
2. 排除 `display:none`、`visibility:hidden`、近乎透明和尺寸过小的 frame；
3. 求 iframe 外层矩形与顶层 `visualViewport` 的交集；
4. 把交集按 iframe scale/client border 映射回 iframe 内部坐标；
5. 只保留有意义的可见面积；
6. 双页展开时保留两个真正可见 frame，并按 LTR/RTL 阅读顺序排序；
7. 屏外预加载 iframe 不进入当前页。

不能使用“第一个有文本 iframe”“当前 iframe 和后面所有 iframe”或“DOM 文本最多的 iframe”。

### 8.3 可见字符

章节常见段落选择器：

```text
h1.element-title
h2.element-title
h3.element-title
.text p
[id$="-text"] p
section[role="doc-chapter"] p
section[role="doc-part"] p
body p
```

每个元素必须用字符 Range fragment 与 iframe 内 clip 求交，得到：

```text
sourceParagraphIndex
sourceStartUTF16
sourceEndUTF16
visibleText
```

规则：

- CSS column 屏外 fragment 不进入当前页；
- block 轴至少约 98% 可见才算当前页；
- 底部被裁掉的半行整体留到下一页；
- 前后空白只在明确的 source offset 计算后裁剪；
- 当前页必须读**精确可见切片**；
- 不把当前末段向屏外延伸几百字符，否则 TTS 会变慢且翻页延迟。

Kobo 同源 iframe 仍属于不同 JavaScript realm：

- 不能用顶层 `node instanceof HTMLElement`；
- 用 `node.nodeType` 和方法能力判断；
- `Range` 来自 `element.ownerDocument.createRange()`；
- 样式来自 `element.ownerDocument.defaultView.getComputedStyle()`；
- overlay/SVG/动画帧属于 Range 的 owner document。

### 8.4 稳定源 ID

`sourceParagraphIndex` 不能用当前数组下标。iOS 对以下信息做稳定哈希：

```text
章节逻辑属性
章节第一/最后 .koboSpan[id]
章节 heading 摘要
段落 ordinal
段落第一/最后 .koboSpan[id]
段落逻辑属性
段落文本首尾摘要
```

源坐标统一使用 UTF-16，和 JS 字符索引、native 高亮协议保持一致。

### 8.5 页面身份

页面 signature 只来自当前可见源切片：

```text
sourceParagraphIndex:sourceStartUTF16:sourceEndUTF16
```

不包含：

- 像素坐标；
- transform 动画值；
- URL；
- footer 页码；
- iframe 数组序号本身。

iOS 格式示例：

```text
kpg-<stable-hash>-<visible-paragraph-count>
```

signature 是不透明 wire identity。native 不得 trim、改大小写或重新编码。

## 9. 高亮和解读 marks

朗读和解读必须使用与提取相同的：

```text
sourceParagraphIndex
sourceStartUTF16
sourceEndUTF16
ownerDocument
```

高亮可见性也使用约 98% block coverage，防止把同一段屏外 column 的词画出来。

视觉所有权：

1. 最后一个音频 item 尚未结束时，保留当前最后词高亮。
2. 自动翻页请求发出但页面尚未改变时，不立即清高亮。
3. signature 第一次离开基线、Kobo 真正开始展示另一页时，清旧高亮和 marks。
4. 新页稳定提交后重新建立 DOM Range 映射。
5. 手动翻页 intent 出现时立即清旧视觉并暂停；回弹则恢复原页映射和音频位置。
6. 模式切换、WebView 销毁、frame 替换必须取消迟到绘制。

## 10. 预加载

Kobo 有两级预加载：

### 10.1 相邻视觉页预览

对当前可见 frame 的 clip 按 writing mode、direction、column width/gap 推进一个视觉页，
只读该预测 clip；若得到的 source range 确实位于当前页之后，生成 `PagePreview`。

该操作只读，不点击、不滚动、不改变 Kobo 当前分页状态。

### 10.2 下一句预览

若无法从几何证明下一整页：

1. 先取当前最后段落中尚未朗读的第一句；
2. 再查当前章节后续段落；
3. 最多检查紧邻的一个预加载章节；
4. 只返回一句，禁止把后续章节全部加入朗读队列。

缓存必须绑定：

```text
sourceSignature
predicted contentFingerprint
sourceParagraphIndex + UTF16 range
voice
speed generation parameters
language
mode/depth
request epoch
```

只有新页稳定提交且全部匹配后才能消费。预加载失败只影响首音延迟，不能阻止正确翻页。

## 11. 自动翻页

### 11.1 页尾时机

正常页尾顺序：

```text
最后音频 media item 真实 ENDED
  → UI 进入 pageTurning（不是 finished）
  → 保留最后词高亮
  → 发起一次 Kobo 物理翻页
  → signature 离开基线时清旧视觉
  → 新 signature 稳定提交
  → 消费匹配预加载或生成新页
  → 继续播放
```

禁止用：

- TTS 已生成完成；
- ExoPlayer 已缓冲完成；
- 字符比例估算；
- `duration - 0.65s` 等固定提前量；
- 下一页已有缓存；

作为正常页提前翻页依据。

### 11.2 翻页身份

每次自动 turn：

```text
turnID
baselineSignature
originFrameSessionID
direction
modeEpoch
```

每个语义 turn 只允许一种物理方法、一次调用。调用未抛错不是成功；只有新可见页稳定
signature 才能提交。

iOS 当前参数：

- signature 轮询：250ms；
- 稳定性采样：180ms；
- 最小稳定时间：420ms；
- 物理动作确认：5.2s；
- 慢动画迟到 tombstone：30s。

Android 可以按设备性能调整轮询间隔，但不能降低身份和 exactly-once 约束。

### 11.3 物理翻页优先级

当前 iOS 优先级：

```text
1. Kobo UR engine 精确页码 API
2. Kobo footer progress slider 精确位置事件
3. 明确的上一页/下一页 page button
4. 无可用动作则失败；不在同一 turn 中轮换重试
```

#### A. UR engine

从当前页面已经声明且同源的 module script 中发现服务 registry，优先取得：

```text
service: "UR/engine"
api.getCurrentReadingRange()
api.goToPageByBookPercentage(number)
```

读取：

```text
percentageOfBook
pagesOfBook
begin.pageIndexInBook
end.pageIndexInBook
```

若当前是单页：

```text
targetPage = currentPage ± 1
targetPercentage = (targetPage + 1) / pagesOfBook
```

Kobo 内部使用近似：

```text
floor((pagesOfBook - 1) * percentage)
```

上述 target percentage 可精确落到目标页。

拒绝精确进度翻页：

- 页数缺失、非整数、<= 1；
- percentage 非有限或不在 0...1；
- begin/end 指向不同页，即双页 spread；
- 目标越界；
- API 不存在或调用失败。

若精确进度不可用但 UR engine 有 `turnLeft/turnRight`，可按阅读方向调用方向语义。

#### B. footer progress slider

稳定选择器：

```text
[data-test-id="reader-footerBar-slider"]
[data-testid="reader-footerBar-slider"]
[data-test-id="reader-footerBar-slider-bar"]
[data-testid="reader-footerBar-slider-bar"]
[data-test-id="reader-footerBar-pageNumber"]
[data-testid="reader-footerBar-pageNumber"]
```

Kobo slider 是 React `div`，不是原生 `input[type=range]`。它用 click 的 `clientX` 计算
全书百分比并调用 Kobo 自己的 `goToPageByBookPercentage`。

必须：

1. 从 UR range 或单页标签 `7 of 15` 得到精确目标；
2. 拒绝 `7–8 of 15` 这类 spread；
3. 获取 slider bar 的真实 rect；
4. LTR 使用 `left + width * targetPercentage`；
5. RTL 从 `right` 反向计算；
6. 向 slider 根节点派发**一次**带 `clientX/clientY` 的 `MouseEvent("click")`；
7. 最终仍用页面 signature 验证。

绝不能直接调用 DOM `.click()`：无坐标 click 可能等价于 `clientX = 0`，跳回书首。

#### C. page button

搜索多语言上一页/下一页 label，并显式排除：

```text
next chapter
previous chapter
下一章
上一章
```

页面按钮只作为单次 fallback。不可在超时后再补按键或热区，否则慢动画可能导致双翻页。

### 11.4 迟到结果

物理动作 5.2s 未换页时可以向 native 报失败，但保留短期 tombstone。若随后页面真的改变：

- 只允许原 `turnID + baselineSignature + frameSessionID` 接收；
- 仍按原自动语义提交；
- 其他 frame、模式或新 turn 不得抢占；
- native 接收后完成/清除 tombstone。

## 12. 手动翻页

监听范围：

- 顶层 document；
- 当前和可访问章节 iframe document；
- 可信 touch swipe；
- footer progress slider 的可信点击或小幅拖动；
- 左右边缘点击；
- 明确 page button；
- Arrow/PageUp/PageDown；
- 事件可能被 Kobo 吞掉时的 signature 变化兜底。

iOS 当前 swipe 判定：

```text
水平距离 >= max(44px, viewportWidth * 11%)
AND 水平距离 >= 垂直距离 * 1.25
```

手动协议：

1. 可信 intent 立刻暂停旧页，记录播放位置和“之前是否在播”；
2. 创建 `manualIntentID + baselineSignature + frameSessionID`；
3. 用户仍按住时不能被短 watchdog 恢复；
4. 只有新 signature 稳定后提交；
5. 回到严格 baseline 时发 `cancelled`，恢复原音频位置和高亮；
6. A → B → C 连滑只在最终稳定 C 页重启；
7. 若未捕获触摸但观察到非自动 signature departure，补发 detected manual intent；
8. 手势前暂停则新页保持暂停；手势前播放才续播。

footer slider 是小距离高精度手势，不能套用普通横滑的 44px 门槛。应按稳定 test ID
识别 slider，在 pointer/touch down 或约 2–3px 位移时发送手动 intent；只接受
`isTrusted == true` 的用户事件。自动翻页派发的合成 slider click 是 untrusted，不能反过来
被识别为手动翻页。

Android 还需处理系统返回手势、Compose 手势和 WebView 横滑的仲裁，不得让系统返回与阅读翻页
同时触发。

## 13. 解读复用

Android Kobo 必须复用 Android Google Books 已有：

- 当前页 snapshot → Explain 输入；
- LLM block 生成；
- TTS 时间线；
- marks source range；
- 播放器 callback lease/单一所有权；
- 页结束后自动 turn；
- 手动翻页暂停/恢复；
- pageTurning UI；
- 预取失效和 epoch。

不得新建 `KoboAudioPlayer`、`KoboExplainPlayer` 或独立底部控制条。

解读当前页完成时：

```text
当前 Explain media item ENDED
  → isPageTurning = true
  → requestTurn(next, explain epoch)
  → 新页稳定提交
  → 重新生成或消费完全匹配的下一页 Explain 预取
```

翻页失败且确认无法继续时，才进入真正的 Explain finished 状态。

## 14. Android 实施建议

### 14.1 先抽平台共享层

目标 Android 任务已经有 Google Play Books 适配。Kobo 应在其基础上抽出或扩展：

```text
CommercialWebPlatformProfile
CommercialWebSession
CommercialLibrarySnapshotContract
PaginatedWebReaderCoordinator
VisiblePageSnapshot
TurnIdentity / ManualIntentIdentity
PagePrefetchGate
PlaybackCallbackLease
```

Kobo 新增：

```text
KoboPlatformProfile
KoboBook / KoboReadingAnchor
KoboLibraryStore / Repository
KoboLibraryScanner
KoboReaderAdapter JS
Kobo binding/shelf thin UI
Kobo contract and browser fixture
```

命名可根据 Android 现有架构调整，职责边界不能改变。

### 14.2 WebView

建议：

- 绑定和阅读器共用同一 Cookie/DOM storage profile；
- 绑定页只注入最小书架 scanner，不暴露 reader bridge；
- 阅读器只对白名单 `readnow.kobo.com/<同书 UUID>` 暴露最小 WebMessage channel；
- 优先使用 AndroidX WebKit origin 限定的 message listener；
- 若必须使用 `JavascriptInterface`，导航离开白名单前移除，且接口只接收版本化 JSON；
- document-start 只给 Kobo 顶层安装 adapter；
- 顶层 adapter 直接访问同源 srcdoc iframe；
- 页面/Activity 销毁时移除 listener/interface/client、取消 coroutine，并调用
  `WebView.destroy()`。

不要依赖：

- `evaluateJavascript` 可以直接进入任意 frame；
- `onPageFinished` 等于 Kobo SPA 正文就绪；
- URL 改变等于页面提交；
- `dispatchEvent` 没抛异常等于 Kobo 已翻页。

### 14.3 共享脚本

`WebReader/src/kobo.ts` 是 iOS 已验证的算法参考。Android 可：

1. 抽取平台无关 TypeScript 到共享源码；
2. 在 Android web bundle 中复用；
3. 只替换 native message transport；
4. 保持字段和 identity 语义不变。

必须保留：

- UTF-16 offset；
- owner-document Range；
- iframe clip 映射；
- 98% 半行过滤；
- 当前页与预加载 frame 隔离；
- source ID/signature；
- exact progress turn；
- exactly-once；
- 手动 intent/changed/cancelled；
- 预加载绑定。

### 14.4 播放器

Android 页尾权威信号是 ExoPlayer 当前 media item 的真实 `STATE_ENDED`/media item transition，
不是 TTS 请求完成或 buffered position。

自动续页期间：

- 保持用户的播放意图；
- UI 显示 pageTurning；
- 不发 finished/replay；
- 新页提交后续播；
- 翻页明确失败才结束。

## 15. 日志

日志必须能用同一组 ID 串起：

```text
KOBO adapter version
reader instance / book hash / frame session
page signature / content fingerprint
TTS segment start/end/currentTime/duration
mode + modeEpoch + callback owner
prefetch start/ready/hit/reject
turnID + baseline + method
UR current/target page and percentage
slider current/target page and percentage
manualIntentID + intent/changed/cancelled
old visual clear / new page commit
explicit destroy
```

iOS 当前适配器版本标记：

```text
2026-07-30-progress-v1
```

典型成功翻页日志应包含：

```text
audio item ended
turn requested method=semantic transport=ur-progress
currentPage=N targetPage=N+1 pagesOfBook=M
signature departed
page committed
prefetch hit/rejected
next audio started
```

禁止记录密码、Cookie、token、邮箱原文、完整正文或完整解读。

## 16. 测试

### 16.1 纯合同

- Kobo UUID/URL 严格规范化和恶意 authority/path 拒绝；
- stable ID 与 UUID/URL 同一本书；
- resume URL 不能切换到另一 UUID；
- 账号只保存 SHA-256；
- 公共商店/预览页不能修改书架；
- 部分快照只能新增/更新；
- 完整同账号快照才删除；
- 账号切换只清 Kobo 数据和 Kobo 历史；
- 解绑保留共享网页 Cookie；
- 封面/标题/作者清洗；
- 空书架 10 次、非空 4 次稳定门槛；
- identity 逐字节匹配；
- 每个 turn 一次物理动作；
- pageTurning 不闪 finished。

### 16.2 浏览器 fixture

- 多个同源 srcdoc iframe；
- 当前 frame + 屏外预加载 frame；
- iframe 内多页 CSS columns；
- 3.5 行可见，半行留到下一页；
- 双页展开；
- LTR/RTL/竖排；
- owner-document Range 高亮；
- 旧页 marks 清除；
- 相邻页预览与一句 fallback；
- UR exact progress；
- footer slider 精确 `clientX`；
- spread 拒绝；
- `.click()` 不得使用；
- chapter button 排除；
- semantic Promise rejection；
- 5.2s 超时后不补另一动作；
- 迟到页面只由原 turn 接收；
- 手动滑页、回弹、A → B → C；
- fixed-layout 明确拒绝。

### 16.3 Android UI/集成

- Kobo 入口和书架；
- 登录卡在认证页隐藏；
- popup/主页登录返回；
- 同步状态立即出现；
- 旧书架不被空扫描删除；
- 封面、作者、标题；
- 从书架开书；
- 真实页面不被 CastReader loading/error 全屏盖住；
- 紧凑播放器；
- loading 在橙色按钮内；
- 自动续页不闪“完成”；
- 模式切换回调所有权；
- 前后台和 WebView 恢复；
- 连续开五本书无残留实例。

### 16.4 固定真人门禁

```text
https://readnow.kobo.com/b849f0ce-d6b3-42f6-bcb6-e6774d00d132?backref_url=https%3A%2F%2Fwww.kobo.com%2Fsg%2Fen%2Flibrary%2Fbooks&locale=en-US
```

验收顺序：

1. 使用现有持久网页 profile 登录；
2. 登录完成自动进入书架，立即显示同步状态；
3. 正确找到书名、作者、封面；
4. 从 CastReader Kobo 书架开书；
5. 正文尺寸和宽高正常，底部无不可达文字；
6. 朗读首音和词级高亮；
7. 当前页所有可见文本完整播放；
8. 最后词高亮不提前消失；
9. 自动翻到精确下一页，不跳页；
10. 新页继续播放且不闪 finished；
11. 手动翻页立即暂停并只重启最终页；
12. 手势回弹恢复原位置；
13. 解读字幕、marks 和解读自动翻页；
14. 朗读/解读连续切换；
15. 前后台、断网恢复、关闭重开；
16. 解绑后共享网页登录仍存在。

## 17. 已踩过的坑

| 现象 | 根因 | 最终处理 |
|---|---|---|
| 登录按钮只关闭弹层 | 原生 CTA 未执行官方入口 | 找当前登录 URL或点击真实节点 |
| 密码页被底部卡遮挡 | 认证阶段未隐藏绑定卡 | credential page 使用完整空间 |
| 登录后十几秒无同步 | 只等 `didFinish` 或延迟轮询 | commit 后立即显示状态并 probe |
| 页面未稳定就显示 0 本书 | 第一次空 DOM 当完整快照 | 账号+书架+末尾+稳定门槛 |
| 封面/作者全是占位 | 从动作按钮而非完整书卡取值 | UUID 约束的 ancestor 评分 |
| Kobo 字体特别大 | WebKit text autosizing | iframe 内 `text-size-adjust:100%` |
| 页面右侧留白/宽度不对 | 缩放整个 WebView 而未重新分页 | pageZoom=1，修 iframe typography |
| 底部文字被切 | 任意交集 fragment 都算可见 | 98% block coverage |
| 从章节开头开始读 | 只选 iframe，未裁 iframe 内 columns | Range fragment + clip |
| 把后续章节一起读 | 遍历预加载 iframe | 当前页只保留可见 frame |
| TTS 特别慢 | 当前末段延伸进未来 columns | 当前页只读精确可见切片 |
| 自动翻页完全不触发 | 手机壳没有可点击 page button | 发现 UR engine 精确页码 API |
| slider 直接点回书首 | `.click()` 没有 clientX | 精确坐标 MouseEvent |
| 自动跳两页 | 超时后轮换另一动作 | 每个 turn 只执行一次物理动作 |
| 下一章而非下一页 | 误中 chapter control | 多语言 label + 排除 chapter |
| 页面变了但 native 不认 | URL/iframe 内容不变 | 当前可见 source slice signature |
| 旧页高亮残留 | 没有 owner-document 清理交接 | departure 时清旧视觉 |
| 最后一句高亮提前消失 | 请求 turn 时立即 clear | 音频结束前保留，页面 departure 再 clear |
| 自动续页闪“完成” | ENDED 先写 finished，再异步 turn | 原子进入 pageTurning |
| 体感没有预加载 | 预加载了屏外错误内容或无法消费 | 相邻页证明/一句 fallback + 严格 gate |
| fixed-layout 朗读工具栏 | 没有可靠 DOM 仍运行通用提取 | 明确 unsupported |
| 真机仍运行旧逻辑 | 构建资源未实际进入 App/APK | adapter version + 包内 hash/marker 校验 |

## 18. 当前 iOS 自动化基线

截至 2026-07-30：

- Kobo 绑定、书架、打开书、朗读/解读共享链路已接入；
- 当前页 iframe/column 可见裁剪已接入；
- owner-document 高亮和 marks 已接入；
- 相邻页/下一句预览已接入；
- 自动/手动翻页 identity 和稳定提交已接入；
- 自动翻页优先使用 UR exact progress，footer slider 为安全 fallback；
- App 包内 adapter marker 为 `2026-07-30-progress-v1`；
- `npm run test:kobo` 通过；
- iOS 真机 Kobo 合同和书架扫描共 20 项测试通过；
- 构建后的 App 内 `bundle.js` 与源码构建产物 SHA-256 一致。

这只表示代码和自动化基线通过；Android 仍必须独立完成自己的实现和真机/模拟器门禁，
不能用 iOS 测试替代 Android 验收。

## 19. Android 执行顺序

建议按以下顺序自主推进：

1. 阅读本规范、实时网页平台总规范、Android `AGENTS.md`；
2. 审计 Android Google Play Books 当前共享能力；
3. 先抽平台 profile 和共享 paginated coordinator，避免复制；
4. 完成 Kobo URL/model/store/可信书架合同；
5. 完成绑定、popup、共享会话和即时扫描 UI；
6. 移植 Kobo DOM adapter 和浏览器 fixture；
7. 接入当前页 snapshot、高亮和 marks；
8. 接入 UR exact progress 和 slider fallback；
9. 接入自动/手动 turn identity；
10. 接入朗读/解读、预加载和 pageTurning UI；
11. 补生命周期和显式 destroy；
12. 跑 JVM/浏览器/Compose 测试；
13. 构建安装并做模拟器/真机门禁；
14. 把 Android 专有架构、差异、限制和测试结果写入 Android `docs/`；
15. 只有确实需要账号本人操作时，直接在 Android 任务中请用户配合。

Android 任务自行完成实现、测试、迭代和验收；iOS 任务不负责过程监管。

## 20. Definition of Done

- [ ] Kobo 入口、绑定、书架、设置解绑完整；
- [ ] 登录 popup 和共享持久会话正确；
- [ ] 认证页没有底部遮挡；
- [ ] 同步状态及时，可信快照才显示 0 本书；
- [ ] 书名、作者、封面、UUID 正确；
- [ ] 从书架进入同一本书；
- [ ] 当前可见页提取准确，不读屏外章节、控件或半行；
- [ ] 字号、宽度、高度和底部可见区域正确；
- [ ] 词级高亮使用相同 UTF-16 source range；
- [ ] old owner-document 高亮/marks 正确清理；
- [ ] 朗读最后一句完整结束后才翻页；
- [ ] UR exact progress 精确相邻页；
- [ ] slider fallback 不跳书首、不跳多页；
- [ ] 每个 turn exactly once；
- [ ] 手动翻页、回弹、连续滑页正确；
- [ ] 手动点击/拖动 footer slider 能立即暂停并只提交最终页；
- [ ] 预加载可观测、可失效、不越权；
- [ ] 解读字幕、marks 和自动翻页正确；
- [ ] 自动续页不闪 finished；
- [ ] 紧凑播放器和 loading 防抖正确；
- [ ] 前后台、断网、重启可恢复；
- [ ] 解绑不清共享网页登录；
- [ ] 显式销毁，无 WebView/协程/回调泄漏；
- [ ] Android 契约、浏览器 fixture、UI 和设备门禁通过；
- [ ] Android 专有文档和测试结果已沉淀。
