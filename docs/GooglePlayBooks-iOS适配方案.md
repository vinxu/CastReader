# Google Play 图书 iOS 适配 —— 产品与技术方案

> 第三个绑定书库入口，与 **Kindle**、**微信读书** 并列。
> 产品逻辑与另外两家完全一致（绑定 → 书架 → 打开书 → 朗读/解读 → 自动翻页），
> 只有技术实现不同。本文只写「不同的那部分」。
>
> 通用产品合同、登录会话、可见页、页尾音频、高亮、预加载、翻页身份、生命周期、
> 可观测性与跨端验收要求，以
> [`实时网页阅读平台接入标准.md`](./实时网页阅读平台接入标准.md) 为准。

## 1. 为什么它比 Kindle / 微信读书简单

| | Kindle | 微信读书 | **Play 图书** |
|---|---|---|---|
| 正文来源 | 页面渲染图 → tesseract OCR | Canvas 绘制后 DOM 被移除 → document-start 抓瞬时布局 | **DOM 里就是真文本** |
| 定位方式 | 词级 bbox（图像坐标） | Canvas/DOM 几何匹配 | **DOM Range（字符偏移）** |
| 高亮 | 图片叠加层 | 自绘 | **复用扩展同一套 `window.CR`** |
| 手机端适配 | 需要视口/缩放处理 | 需要桌面 UA + 视口裁剪 | **官方移动端排版，直接用** |

结论：Play 图书走的是**已有的 `.web` 渲染路径**（`WebReaderView` + `bundle.js` + `WebReaderBridge`），
不需要 OCR、不需要 Canvas 拦截、不需要方向锁。新增代码集中在「分页」和「跨源 iframe」两件事上。

## 2. 页面结构（唯一必须知道的事实）

```
top: play.google.com/books/reader?id=<volumeID>        ← 只有壳，没有任何正文
 └─ iframe: books.googleusercontent.com/books/reader/frame   ← 跨源，正文在这里
     <reader-app>
       <reader-rendered-page>            ← 一「页」；双栏时同时存在两个
         <div class="gb-segment">        ← **整个 segment（章）的 DOM**
           <p class="para0">…</p>
```

两个坑，都必须处理：

1. **跨源 iframe（且可能多层嵌套）** —— native 的 `evaluateJavaScript` 只作用于主帧。
2. **`<p>.textContent` 是整章，不是当前页** —— Google 把整章渲进容器，靠裁剪分页。
   直接读 `textContent` 会一页把整章读完，翻页与高亮全部错位。

## 3. 架构

```
                    play.google.com（主帧）
  native ──call()──►  window.CR = 转发壳 ──postMessage──┐
                                                        ▼
                    books.googleusercontent.com（阅读帧，跨源）
                      window.CR          ← 真正的高亮/标注桥（bundle.js）
                      window.CastReaderGoogleBooks  ← 翻页 API
                            │
                            └──webkit.messageHandlers──► native
```

- bundle.js 用 `forMainFrameOnly: false` 注入**所有帧**。
- `entry.ts` 按 host 分流：主帧/中间 Google 容器只装逐层转发壳（**绝不提取**，否则会把阅读器 UI 当正文读），
  阅读帧装真正的桥 + Play 图书提取器。
- 每个阅读帧生成不可复用的 `frameSessionID`。native 只接收当前 owner 的事件，并把
  `gbNextPage` / `gbPreviousPage` 定向到该 session；预加载或转场残留 iframe 不能抢走正文或多翻一页。
- 每次自动翻页都携带不可复用的
  `{turnID, baselineSignature, originFrameSessionID}`；手动手势同理使用
  `{manualIntentID, baselineSignature, originFrameSessionID}`。请求、失败、迟到的 rendered
  必须完整匹配这组身份，不能只凭「指纹变了」接管 native 状态。
- Google 可能在 JS 的无变化超时之后才落地页面。JS/native 为该 turn 保留 30 秒
  tombstone；迟到结果仍按原 turn 的自动/手动语义提交，但任意其他 iframe、旧模式或旧请求
  都不能借 tombstone 抢占 owner。
- 子帧回 native 直接走 `webkit.messageHandlers`（子帧可用），不需要反向转发。
- `CR.gbNextPage()` 没有返回值（postMessage 是异步的），所以翻页确认**只看可见区指纹变化**，
  超时**不重试**（重试点击会跳页）。

## 4. 可见区裁剪与跨页断句

`WebReader/src/play-books.ts`：

1. `pickVisiblePages()` —— 用可见交集筛掉 Google 的排版测量副本，
   双栏时按 `left` 排序返回两页。
2. `visibleCharRange(el, clip)` —— 同时按横向列和纵向页的可见矩形裁剪，得到
   `[sourceStart, sourceEnd)`；CSS columns 的屏外列、上下页和排版测量副本都不会进入正文。
3. 末段若停在句中，`extendToSentenceEnd()` 向后补到自然句末（上限 260 字符）→ `speechText`。
4. native 侧 `WebReaderBridge.parseGoogleBooksPage()` 用 `sourceParagraphIndex + sourceStart/End`
   调 **`WeReadCrossPageSpeechContract.consumeAlreadySpokenPrefix`**（与微信读书同一套已验证契约）
   裁掉新页里已经读过的前缀。
5. Read 保留裁剪后的 DOM offset；Explain 则始终使用整张当前可见页及其原始 offset，
   所以切到解读不会漏掉被跨页朗读过的页首文字或把标注画偏。

一次真实的裁剪结果（fixture，390×700）：

```
page0  #3 src=4 [0,74)   "…which in winter meant almost"
       speech += 127     "… a great many opinions about her."   ← 补到句末
page1  #0 src=4 [36,200) → 整段已在 page0 读完 → 裁空，不重复朗读
```

## 5. 分页与播放

| 事件 | 触发 | 行为 |
|---|---|---|
| 首屏 | 阅读帧等到 `reader-rendered-page .gb-segment` 出现 | `rendered(reason: initial)` → `loadWebParagraphs` → 按 autoPlay 设置开播 |
| 自动翻页 | AVPlayer item end / `onDocumentFinished` | 预加载存在时由 queue gate 请求 `CR.gbNextPage()`，否则由文档完成回调请求；新指纹提交后才续播。估算 cue 只用于准备，不能提前移动页面 |
| 手动翻页 | 可信 pointer/touch/key 输入 + 稳定新指纹 | `intent` 时只暂停自动起播，不销毁请求/队列；最终新页提交后，**原本在播才续播** |
| 手势回弹 | 手动位移最终回到原指纹 | `phase=cancelled`，原请求、播放位置和额度会话原样恢复，不重播本页 |
| 翻到书末 / 内容异常 | 空页或超时 | 不提交、不重复执行物理翻页；显示可重试/重新绑定状态 |

翻页会从按钮、方向键或点击热区中选择**一种**物理动作；一次语义请求绝不在超时后
补发第二种动作。成功手段会被记住供后续页使用。新的可见区指纹是唯一提交证据，
同指纹 refresh 只重建 DOM 映射，不重启 TTS/LLM。

手指仍按住时，即使超过手动 intent 的短 watchdog，也不能恢复旧页音频。只有
`cancelled`（回弹到严格基线）、已确认的新页，或更长的变更确认超时才结束该手势。
重复/乱序的 intent、changed、cancelled 事件只在 manual identity 完整匹配时生效。

进入后台时暂停确认计时；如果页尾恰好在后台到达，物理动作延迟到前台只发送一次。
Web 内容进程重载时会保存当前朗读/解读意图，恢复出可读页面后再续播。

## 6. 登录与隐私

- 登录走 Play 图书自己的手机网页（`GoogleBooksLibraryConnectView` 里的 WKWebView），
  **用户自己输入账号密码**，CastReader 不读取、不保存、不转发任何凭据。
- 必须设置**完整的 Mobile Safari UA**（`GoogleBooksWebScripts.mobileSafariUserAgent`）：
  WKWebView 默认 UA 缺 `Version/… Safari/…`，Google 会判定为「不安全的浏览器」而拒绝登录。
- 登录若使用 `target=_blank` / 弹窗，会用 WebKit 提供的同一 configuration 创建临时
  子 WKWebView；密码、Passkey、2FA 全程仍由 Google 页面处理。返回 Play 图书后自动关闭
  子页并刷新书架。
- 绑定页与阅读器共用 App 级的持久化 `GoogleWebSession.websiteDataStore`。固定 UUID
  不得更换；未来需要打开 Google 自有网页的阅读服务也应显式复用这个分区，使用户登录
  一次后可快速确认账号。解除单个平台绑定只清该平台在 CastReader 内的书架、进度与账号
  关联，不清 Google 网页 Cookie；清除共享 Google 网页登录必须是单独、明确的全局操作。
- 本地只持久化：书名 / 作者 / 封面地址 / `volumeID` / 阅读地址 / 进度百分比。
  **不落库正文。** 用于区分 Google 账号的证据先做 SHA-256，再写入本地；不保存或展示邮箱原文。
- 只有「账号证据 + 我的图书上下文 + 滚动到书架末尾」同时成立才是完整快照。
  中途断网/虚拟列表部分扫描只能合并，不能删除旧书；账号变化会清理上一账号的书架与锚点。
- 埋点新增 `content_source = content_format = "google_books"`，禁止字段规则不变。

## 7. 文件清单

| 文件 | 作用 |
|---|---|
| `WebReader/src/play-books.ts` | 可见区裁剪、补句、翻页、指纹监听、跨帧转发 |
| `WebReader/src/entry.ts` | 按 host 分流主帧/阅读帧 |
| `WebReader/src/cr-bridge.ts` | 新增 `exactText` / `charOffset` / `pageMeta` / `disableScroll` |
| `CastReader/Models/GoogleBooksModels.swift` | 地址归一化、书架过滤、翻页与跨页契约 |
| `CastReader/Services/GoogleBooksWebScripts.swift` | UA、地址、书架扫描 JS |
| `CastReader/Services/GoogleBooksLibraryStore.swift` | 书架元数据 + 进度锚点 |
| `CastReader/Views/GoogleBooks/GoogleBooksLibraryViews.swift` | 首页书架条 / 绑定页 / 完整书架 |
| `CastReader/Services/WebReaderBridge.swift` | `googleBooks` 分页循环 |
| `CastReaderTests/GoogleBooksContractTests.swift` | 地址、书架、会话、跨页游标与多页音频时间轴契约 |
| `CastReaderTests/GoogleBooksWebBridgeTests.swift` | 真实 WKWebView fixture：横/竖分页、iframe 定向、慢动画、手势回弹、DOM 高亮/标注 |
| `CastReaderUITests/CastReaderUITests.swift` | 三入口路由；可选真人登录与指定书籍朗读/滑页/解读端到端门禁 |

## 8. 已知风险 / 待真人验收

1. **书架 DOM 选择器**：`GoogleBooksWebScripts.libraryScan` 是按 Play 图书网页常见结构写宽的
   （`a[href*="/books/reader"]` + `data-*` 兜底）。本地 WKWebView fixture 已覆盖登录证据、
   公开预览误判、嵌套虚拟列表滚动和空书架，但仍要在真实登录账号上跑一次。
   若书架为空，先用 Safari 开发者工具看「我的图书」页的实际 markup，再补选择器。
2. **Google 登录**：Mobile Safari UA 通常可以通过「不安全浏览器」检测，但 Google 会不定期收紧。
   若被拒登录，日志里会看到阅读器被重定向到 `accounts.google.com`。
3. **真实书籍差异**：离线 WKWebView fixture 已覆盖横向列、纵向页、慢动画和多 iframe，
   仍需用指定账号与指定书籍完成一次有声朗读、解读标注、手动翻页和跨页续播验收。
4. **页尾视觉提前于音频（已修复，待真机体感验收）**：2026-07-29 真机日志确认，
   固定视觉 lead 曾让最后一句高亮提前清除、页面在音频 item 结束前提交。当前 Google
   Books 已禁用估算边界的主动翻页：预加载由旧 item 结束后的 queue gate 触发，无缓存由
   `onDocumentFinished` 触发；请求阶段保留最后高亮，新页提交才清理。未来只有可靠词级
   时间戳才能恢复句中视觉交接，否则继续等待整个 segment。

真人门禁固定使用：

```
https://play.google.com/books/reader?id=b_40EQAAQBAJ&pg=GBS.PP1.w.1.1.9_250
```

顺序为：全新专属数据分区登录并同步 → 从书架进入该 volume/pg → 朗读首音与词级高亮
→ 自动跨页且不重读 → 手动滑页立即停旧页并在新页续播 → 切换解读且无旧模式串音
→ 解读音频与原文 marks → 前后台 → 关闭重开验证 pg/历史续读。
