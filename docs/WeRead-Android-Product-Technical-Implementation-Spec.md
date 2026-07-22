# CastReader 微信读书（WeRead）跨端产品需求与 Android 技术实现规范

> 文档状态：Android 实施权威输入（v1.0）
> 更新日期：2026-07-22
> 适用范围：CastReader Android 的微信读书绑定、书架同步、朗读、解读、高亮、翻页、后台播放与异常恢复
> 参考实现优先级：Chrome 扩展的网页渲染适配 > iOS 的移动端生命周期与播放器合同 > 本文的 Android 映射
> 当前产品决定：微信读书入口对所有用户显示，暂不按语言、国家、地区或时区限制。

---

## 1. 文档目的

本文不是一份页面原型，也不是把 iOS Swift 代码翻译成 Kotlin 的清单。它定义微信读书在 CastReader 中从登录、同步书架到连续朗读和连续解读的完整产品合同，并说明 Android 应如何在微信读书生产页面的 Canvas 渲染机制上实现这套合同。

Android 当前尚无 WeRead 代码，应把本次工作视为一个独立子系统，而不是给通用网页播放器增加若干站点条件分支。实施后，以下链路必须作为一个整体成立：

1. 用户绑定微信读书账号。
2. CastReader 进入“我的书架”，读取真实书名、作者、封面和进度。
3. 用户将书架同步到 CastReader 本地，并能再次增量刷新。
4. 用户打开一本书时，首屏一次性以正确尺寸展示，不经历缩放跳变或二次闪烁。
5. 朗读只读取当前可见页，并让 TTS、高亮、可见页面、自动翻页保持同一状态机。
6. 解读读取当前可见页，手写标注落在原文真实位置，并能预加载下一页解读。
7. 手动翻页、自动翻页、退后台、回前台、进程恢复、音色和倍速切换都不会破坏状态机。

本文同时记录已踩过的坑。Android 不应重新尝试已被证伪的方案，例如直接读取整章隐藏 DOM、按 Canvas 数量判断单双页、创建 WebView 后再缩放、依赖键盘事件翻页、把预取结果未经页面确认直接播放等。

---

## 2. 产品定位与边界

### 2.1 产品定位

CastReader 是工具型 TTS/解读产品，不拥有微信读书内容，也不复制、托管或建立微信读书内容库。微信读书接入的价值是让用户把自己有权访问的内容快速绑定到 CastReader，用 CastReader 的朗读和解读能力消费。

### 2.2 必须支持

- 微信读书账号 Web 登录和持久会话。
- 书架扫描、增量同步、搜索、排序、刷新和解除绑定。
- 书名、作者、封面、阅读进度和稳定书籍标识。
- 从 CastReader 本地书架打开微信读书原书。
- 当前可见页朗读、逐句/逐词高亮、自动翻页、手动翻页后重新朗读。
- 当前可见页解读、手写手绘标注、自动翻页和下一页预加载。
- 前台、后台、Mini Player、全屏播放器之间的状态一致性。
- 浅色/深色整套主题跟随系统。
- 免费额度、Pro、音色、倍速等共用 CastReader 现有统一合同。

### 2.3 明确不做

- 不绕过微信读书登录、付费或访问权限。
- 不破解或持久化受保护的章节接口响应。
- 不下载整本书，不建立内容镜像。
- 不依赖微信读书私有 App、无障碍自动化或模拟用户批量抓取。
- 不把隐藏整章 DOM 当作“当前页”。
- 移动端阅读器暂不支持横屏；WeRead 全屏和 Mini Player 都固定竖屏，防止重排中断播放。
- 不把微信读书内容重复放入首页通用“继续”列表；它只出现在专属微信读书模块和微信读书书架中。

---

## 3. 当前产品决策（不得自行改回）

1. **全球可见**：WeRead 入口当前对全部用户显示，不做中国区、中文语言、SIM、IP、Locale 或时区判断。
2. **专属首页模块**：未绑定时展示绑定卡片；已绑定时展示微信读书书籍横向列表和“查看全部”。
3. **不进入通用 Continue**：微信读书书籍不出现在通用“继续”中，避免同一内容重复展示。
4. **只支持竖屏**：打开微信读书书籍后的全屏播放器锁定竖屏；收起为 Mini Player 后同样不因手机旋转触发页面重排或播放器重建。
5. **系统主题**：微信读书阅读页的背景、正文、弱化文字、分隔线、按钮和高亮必须作为一整套主题跟随系统浅色/深色，而不是只修改背景。
6. **Web 会话持久化**：正常关闭和重开 CastReader 不退出微信读书。只有用户主动“解除微信读书绑定”才清除微信读书域的 Cookie、localStorage、IndexedDB、缓存和本地同步数据。
7. **可见页是事实源**：TTS 和解读的当前页边界必须由可见 Canvas surface 证明，不能由尚未显示的语义数据单独决定。
8. **只有一个翻页动作**：一次自动翻页事务只允许一次微信读书的语义“下一页”动作；禁止 click + tap + keyboard + 坐标等多路重试。

---

## 4. 用户体验与页面流程

### 4.1 首页：未绑定状态

- 所有用户都能看到微信读书模块。
- 展示“连接微信读书/同步你的书架”卡片及简短说明。
- 点击进入连接页。
- 此时不能展示“同步 0 本”“未找到书籍”等同步栏，因为用户尚未登录。

### 4.2 登录与连接页

目标是让微信读书认为当前为桌面浏览器，使网页版登录、书架和阅读器正常工作。

流程：

1. 使用持久化 WebView profile 打开 `https://weread.qq.com/`。
2. 使用经过验证的桌面 Chrome User-Agent。
3. 登录前显示网页自身登录界面；不得用一块空白页面叠加同步按钮。
4. 登录成功后自动导航到 `https://weread.qq.com/web/shelf`。
5. 书架扫描期间底部显示明确进度，例如“正在扫描书架…”。
6. 扫描得到稳定数量后显示“同步 N 本书”。
7. 用户点击同步后，将书籍增量合并到本地数据库，关闭连接窗口并回到首页/书架。

认证判断不能只看“页面存在多少卡片”。应综合：

- 已登录用户头像或账号区域；
- 登录按钮是否消失；
- 微信读书相关 Cookie/本地状态是否存在；
- 当前是否能够访问书架；
- 扫描结果是否含合法 reader URL 或 bookId。

### 4.3 书架同步

同步字段至少包括：

| 字段 | 要求 |
|---|---|
| stableId | 优先 bookId；缺失时用标准化 readerURL/title 的稳定哈希 |
| title | 真实书名，禁止默认成“书籍封面” |
| author | 真实作者；优先 Vue 组件数据，DOM 仅作回退 |
| coverURL | HTTPS 封面地址，支持懒加载属性和 CSS background-image |
| readerURL | 可直接打开该书阅读器的合法 URL |
| progressLabel | 微信读书可见进度；缺失可为空，不伪造 0% |
| lastSyncedAt | 本次同步时间 |
| lastOpenedAt | 用户最后打开时间，由 CastReader 更新 |
| lastPageFingerprint | 最近确认的页面身份，用于恢复 |
| lastReaderURL | 最近确认的阅读 URL，用于恢复 |

微信读书书架是虚拟列表/懒加载页面，不能只扫第一屏。推荐扫描策略：

1. 每轮先读取当前渲染项。
2. 以去重后的 stableId 合并。
3. 向下滚动约 0.8 个视口或固定安全距离。
4. 等待约 500–800 ms 让虚拟列表挂载。
5. 连续若干轮数量不再增长才认为稳定。
6. 设置总轮次与总时限，避免页面异常时无限滚动。

Vue 2 页面中，标题/作者等最可靠信息通常在卡片节点的组件实例或其 `book` 属性中。iOS 实践表明，单看 DOM 文本会出现“封面正确但大量作者 Unknown”的问题。Android 扫描脚本应按以下优先级取值：

1. 节点关联 Vue 组件的结构化 `book` 数据；
2. 卡片内部语义选择器、链接属性、图片属性；
3. 可见文本和 `aria-label`；
4. 不猜测封面上的 OCR 文本。

### 4.4 微信读书本地书架

- 支持按最近阅读、标题、作者排序。
- 支持搜索书名和作者。
- 首屏分页，底部“加载更多”。
- 每行/卡片展示封面、书名、作者、进度。
- 下拉或按钮刷新从远端书架重新增量合并。
- 打开书籍前校验 readerURL，失效时允许回到连接页重新扫描。

### 4.5 设置：解除绑定

设置页提供明确的“解除微信读书绑定”。操作后：

1. 停止当前 WeRead 朗读或解读会话。
2. 清除 `weread.qq.com` 和相关 QQ 登录域的 Cookie/网站数据。
3. 清除本地同步的微信读书书架、账号信息、阅读锚点和预取缓存。
4. 不清除 CastReader 账号、其他网页、Kindle 或上传文件数据。
5. 再次进入连接页必须能正常看到登录页面，不能白屏。
6. 未登录时不显示同步 bar。

---

## 5. 微信读书生产阅读器的真实架构

这是整个实现最关键的前提。

微信读书桌面阅读器不是普通“正文一直存在于 DOM”的网页。生产环境通常包含：

1. **瞬时语义层**：`.preRenderContainer > #preRenderContent`。它短暂包含可读 HTML、段落、文本节点与排版信息，Canvas 绘制完成后可能很快被清空或替换。
2. **可见绘制层**：`.renderTargetContainer .wr_canvasContainer` 内的一个或多个 Canvas。用户真正看到的文字最终由 Canvas 呈现。
3. **翻页控件层**：`.renderTarget_pager` 等节点，包含上一页/下一页语义按钮。
4. **SPA 路由与 Vue 状态**：章节、书籍和阅读位置变化可能不触发传统整页导航。

因此必须区分两个概念：

- **语义来源（semantic source）**：告诉我们字是什么、段落顺序是什么、完整句子如何延伸。
- **可见页面（visible surface）**：告诉我们用户当前真实看到了哪一页、哪些字落在哪些坐标。

二者必须相交才能生成“当前页合同”。只拿语义来源会读到下一页甚至整章；只拿 Canvas 像素会失去可靠文本语义和句子边界。

### 5.1 为什么章节接口不是主路径

扩展端验证过，微信读书章节接口可能加密、结构变化或依赖会话上下文。Android 不应把逆向/解密接口作为上线依赖。章节接口即使偶尔能读，也不能证明哪一页当前可见。

主路径必须是：

`瞬时 DOM/绘制调用捕获 → 可见 Canvas 几何 → 当前页文本切片 → TTS/解读`

### 5.2 三类 Hook

应尽可能在 document start 安装：

1. **DOM 捕获 Hook**
   - MutationObserver 观察 preRender 容器。
   - 回调中同步复制文本、段落关系、DOMRect、字体样式和容器尺寸。
   - 在第一次 `await`、异步 bridge 或下一轮事件循环前完成快照，因为源 DOM 可能瞬间消失。

2. **Canvas Hook**
   - 包装 `CanvasRenderingContext2D.fillText`，记录文字、x/y、字体、变换矩阵和目标 Canvas。
   - 包装 `clearRect`，维护 Canvas generation，剔除已擦除的旧绘制。
   - 包装 `drawImage`，捕获预渲染 Canvas 被复制到可见 Canvas 的列/页关系。

3. **页面/交互 Hook**
   - 监听 SPA URL、章节标识、容器尺寸、翻页按钮和 pointer/touch intent。
   - 采集当前 surface fingerprint、layout fingerprint、column index、canvas generation。
   - 在用户触发手动翻页的按下阶段就向 native 报告，立即停止旧音频。

Android WebView 通常可在页面主世界执行注入脚本，但具体 API 取决于现有 AndroidX WebKit 版本。优先使用支持 document-start 注入的 WebViewCompat 能力；如果设备能力不足，必须证明 fallback 仍能早于第一次关键 preRender 捕获，不能把 `onPageFinished + evaluateJavascript` 当作当然可靠。

---

## 6. Android 子系统建议拆分

不要把所有 JS、播放器和 Compose 状态写进一个 Screen/ViewModel。建议至少拆为：

| 模块 | 职责 |
|---|---|
| `WeReadModels` | 书籍、账号、锚点、页面证据、翻页事务、预取条目等纯模型 |
| `WeReadLibraryStore` | Room/DataStore 持久化、书架合并、断开连接 |
| `WeReadSessionStore` | WebView profile、Cookie/网站数据生命周期 |
| `WeReadScripts` | document-start Hook、书架扫描、reader bridge、主题与 viewport 脚本 |
| `WeReadBridge` | JS 消息解码、事件去重、页面事务和 native 状态机 |
| `WeReadPageEngine` | 当前页合同、指纹、证据确认、手动/自动翻页 |
| `WeReadReadCoordinator` | 当前页 TTS、时间戳验证、高亮、跨页承接、下一页预生成 |
| `WeReadExplainCoordinator` | 当前页解读、marks、下一页解读预取 |
| `WeReadReaderViewModel` | 面向 UI 的单一状态，不拥有底层音频 callback |
| `WeReadWebViewHost` | WebView 一次性几何、加载遮罩、主题、生命周期 |

复用 Android 现有架构：

- 音频继续走 `AudioPlaybackService` + `AudioPlayerManager`/Media3 ExoPlayer。
- 全局 UI 和 Mini Player 继续走 `GlobalPlayerState`。
- TTS 编排可复用 `PlaybackController` 的 API/缓存能力，但 WeRead 页面事务必须由独立 coordinator 管理。
- 本地列表可用 Room；小型账号/开关/最近锚点可用 DataStore。不要把大量书架 JSON 长期塞进单个 Preferences 字符串。
- Compose Navigation 打开 Reader route 时只传 stable book id，具体 URL/锚点从 repository 恢复。

### 6.1 状态机必须单一所有权

朗读与解读共享同一个音频播放器。任意时刻只有当前 active mode 能接收 segment complete、time update 和 page complete。切换模式时旧 coordinator 必须 deactivate，取消 TTS/LLM 请求、预取和回调，避免旧回调触发二次翻页或页面刷新。

建议页面状态：

```
idle
→ loadingWeb
→ waitingStableSurface
→ ready(pageContract)
→ generatingCurrent
→ playingCurrent
→ awaitingPageBoundary
→ turning(actionId)
→ confirmingNewSurface
→ ready(nextPageContract)
```

失败状态应可恢复，但不得通过无界 reload 解决。

---

## 7. WebView 会话、UA 与安全

### 7.1 登录 WebView 与阅读 WebView

- 使用同一持久 Cookie/storage profile，确保连接页登录后阅读页可直接访问。
- 登录/书架页采用桌面 User-Agent 和桌面内容策略，确保出现网页版登录与书架。
- 阅读页继续使用经过验证的桌面 UA，但不要强制 Android WebView 的 desktop viewport 模式造成约 980 CSS px 页面缩小。iOS 实践中“桌面内容模式 + 桌面 UA”会造成正文极小、坐标错位；阅读页应保留适合手机视口的 WebView viewport，再由裁剪/缩放策略呈现桌面阅读器。

### 7.2 JS bridge 安全

- 只在 `weread.qq.com` 可信主机启用 bridge。
- Bridge 暴露窄接口，例如单个 `postMessage(json)`，禁止向网页暴露任意文件、网络、反射或执行能力。
- Native 必须验证消息 schema、类型、长度、bookId、page generation 和 actionId。
- 导航到非允许域时禁用/移除 bridge，外链交给系统浏览器或显式白名单。
- 不把 Cookie、token、正文、TTS key 写入日志。

### 7.3 不可通过 reload 治理状态

以下事件都不允许默认调用 `reload()`：

- 点击朗读或解读；
- 收到 page snapshot；
- TTS/解读状态变化；
- 高亮或手写 mark 更新；
- App 退后台/回前台；
- Mini Player 收起/展开；
- 音色或倍速切换。

只有明确的 WebView render-process termination、认证失效或用户主动刷新才允许受控重建/刷新。

---

## 8. 首屏几何、缩放、主题与加载遮罩

### 8.1 WebView 一次性以最终几何创建

已验证的错误路径是：先创建一个任意大小的 WebView，页面完成一次排版，再根据网页报告尺寸修改 WebView/frame/scale，导致第二次重排、画面拉伸、白屏、TTS 双触发和高亮坐标失效。

正确合同：

1. Compose 完成顶部栏、底部播放器、安全区域与可用 surface 的测量。
2. 计算最终 WebView 像素宽高和 density/CSS viewport。
3. 只有 final surface 非零且稳定后才创建并导航 WebView。
4. WebView 生命周期内保持这个外部 frame；网页报告的内容尺寸只做诊断，不反向 resize WebView。
5. 通过固定的移动端 viewport/crop 策略放大微信读书中央阅读区域，去掉桌面两侧空白。
6. 页面未稳定前显示 CastReader 加载遮罩，不让用户看到未裁剪、超小或拉伸的 provisional Canvas。

iOS 当前紧凑竖屏经验值使用约 `1.19` 的内容放大并居中裁剪，但 Android 不应盲抄常数。应基于目标 CSS viewport、可见 reader root 与 Canvas/pager 几何建立纯函数，然后对典型手机宽度做 fixture 测试。运行期若内容报告与预期略有差异，只记录，不触发二次 resize。

### 8.2 稳定首屏条件

加载遮罩至少等待：

- reader root 存在且宽高非零；
- visible Canvas 已绘制非空内容；
- pager 几何已出现或页面明确为无 pager；
- surface fingerprint 在短窗口内稳定；
- 主题已应用；
- 当前页合同通过校验。

避免固定等待很久，也避免 `onPageFinished` 就立即揭开。`onPageFinished` 只代表主文档导航完成，不代表 Canvas 当前页已排版稳定。

### 8.3 浅色/深色主题

- 创建/导航前写入微信读书当前端使用的主题本地配置，例如浅色 `wr_theme=white`、深色对应值，并在 URL 需要时附带合法 theme 参数。
- 同时用 `prefers-color-scheme`/WebView force-dark 策略与系统保持一致，但不能只靠 CSS 背景覆盖。
- 系统主题变化时，只在 App 前台且阅读器状态可控时进行一次主题切换；如果站点必须重排，按“受控页面重建 + 播放锚点恢复”处理，而不是叠加多次 reload。
- 验收必须检查正文文字颜色、标题、弱化文字、线条、分页按钮、高亮透明度与 mark，不只是背景。

### 8.4 方向

- WeRead 阅读器 route 强制竖屏。
- WeRead 播放形成 Mini Player 后仍锁定竖屏，不监听旋转触发重新创建 Activity/WebView。
- Mini Player 展开到全屏 WeRead 后仍为竖屏。
- 暂时删除/禁用 WeRead 横屏重排分支，避免死代码重新触发播放停止。

---

## 9. 当前页数据合同

### 9.1 PageContract 建议字段

```
bookId
chapterId / chapterFingerprint
pageIndex (若站点可靠提供)
sourceCursorStart / sourceCursorEnd
paragraphs[]
  - stableParagraphId
  - fullText
  - visibleTextSlice
  - sourceUTF16Start / sourceUTF16End
  - visualFragments[]
surfaceFingerprint
layoutFingerprint
columnIndex
canvasGeneration
containerRect
pagerRect
capturedAt
```

`visualFragments` 必须允许同一个逻辑段跨多行、跨多个矩形。不能只存 union bbox；union 会覆盖行间空白、下一列或分页按钮。

### 9.2 可见片段校验

一个 highlight fragment 只有同时满足以下条件才合法：

- 归属当前 generation 的可见 Canvas；
- 与当前 visible surface 相交；
- 位于 pager 上方；
- 宽高为有限正数；
- 没有明显落入页外/另一列；
- 能映射到当前 pageContract 的文本范围。

没有精确几何时应“无高亮但继续音频”还是“停止音频”取决于页面类型。WeRead 当前产品要求朗读必须与页面同步：若整页完全无可验证几何，应停止/等待新 snapshot，不能长期无高亮继续跨页播放。单个句子无法精确定位时可仅该句 fail closed，不绘制错误框。

### 9.3 页面指纹

不要只用 URL 或 pageIndex。推荐组合：

- 可见规范化文本哈希；
- Canvas 像素抽样/绘制调用摘要；
- container/canvas/pager 布局摘要；
- column index；
- canvas generation；
- 章节标识。

页面是否真正变化，要由翻页 actionId 与至少一个有效证据共同确认。Canvas incidental repaint、主题变化或高亮 overlay 变化不能被误判成翻页。

### 9.4 文本规范化

用于匹配，不用于展示：

- Unicode NFKC；
- 中文/西文引号归一化；
- dash/ellipsis 常见变体归一化；
- 空白折叠或忽略；
- 保留从规范化索引到原始 UTF-16 索引的映射；
- 允许有界编辑距离，但必须限制候选窗口，不能在整章中任意找到重复句。

---

## 10. 朗读完整合同

### 10.1 开始朗读

1. 通过统一额度/Pro 闸门。
2. 等待当前 PageContract 稳定。
3. 根据当前书籍/页面语言选择对应音色。
4. 当前可见文本按自然句和服务端安全长度生成 TTS。
5. 每个 AudioSegment 入队前独立验证 timestamps。
6. 播放时只根据当前 segment 相对时间更新高亮。
7. 同时启动下一页候选的安全预生成，但不提前播放。

不得在点击朗读时 reload 页面。不得先读一小段 provisional page，再因第二次页面测量从头读一次。

### 10.2 词级高亮能力由数据决定，不由语言白名单决定

禁止 `language == en || language == es` 之类判断。每个实际 AudioSegment 独立验证：

- timestamp 数量是否足以代表多个词/可高亮单元；
- `word` 与 segment 文本的规范化覆盖率；
- start/end 是否有限、单调、不重叠异常；
- 时间是否位于 segment 音频有效区间；
- 文本顺序是否保持；
- 一个整句只返回一个 timestamp 时，必须识别为句子级，不能显示成“单个词”的词级高亮。

通过就对该 segment 启用词级高亮，与语言无关；失败仅该 segment 回退句子级。这个合同同时适用于微信读书、Kindle、网页、PDF、OCR 图片。

### 10.3 中文等无可靠词时间戳的句子高亮

- 句子边界优先采用接口实际返回 segment/断句，不自行用简单标点重新切出另一套边界。
- 当前 segment 的整句可由一个或多个 visualFragments 绘制。
- segment 切换时旧高亮立即清除，再绘制新句。
- 高亮位置必须使用实际文字绘制 metric。Canvas `fillText` 的 y 通常是 baseline，不是矩形顶边；应结合 `actualBoundingBoxAscent/Descent`、当前 transform 和 font，不能用固定负偏移。曾出现高亮整体比文字高一点，就是把 baseline/line box 当成 top 导致。

### 10.4 跨页自然句：不能断，也不能重复

可见页可能在一个自然句中间截断。正确做法不是把每页文本硬切成独立句，而是建立稳定 source cursor：

1. 当前页最后可见片段如果未到自然句终止符，可使用已捕获的后续语义源把 TTS 文本延伸到完整句末。
2. 记录当前页可见边界在完整句中的 UTF-16/source cursor。
3. 当前页播放到这个完整句时，在精确页面边界时刻触发翻页；音频可以保持连续。
4. 新页确认后，文本提取必须消费 `alreadySpokenPrefix`，从未读 source cursor 开始，不能再读新页顶部已经在上一页音频中读过的片段。
5. carry cursor 只在 book/chapter/相邻页证据一致时有效；手动跳页或章节跳转必须丢弃。

这同时解决两个历史致命问题：

- 当前页读完后页面没翻但音频继续读下一页；
- 翻页后从新页被截断的开头重新读一遍。

### 10.5 下一页预生成与无缝衔接

预加载不是“翻页后才开始请求”。应在播放当前页时：

1. 从保留的顺序语义 source 构造 predicted next slice。
2. 生成下一页候选 TTS，缓存 voiceId、speed-independent audio、source fingerprint、预测文本范围和 request generation。
3. 当前页到边界时发起一次翻页。
4. 新页面必须由真实 Canvas surface 确认。
5. 只有当真实页文本与预测页 exact fingerprint 一致，或满足有界顺序覆盖条件时，才释放预生成音频。
6. 不匹配立即丢弃，仅为真实页重新生成；绝不能为了“无缝”读错页。

当前 iOS 预测匹配经验阈值是预测覆盖约 0.70、可见页覆盖约 0.42，并限制 predicted/visible 最大跳过窗口。Android 可以从这些值开始，但必须由 fixture 和真机日志验证，不要把阈值散落在 UI 中。

### 10.6 自动翻页事务

自动翻页顺序：

```
当前页边界到达
→ 立即清除旧页高亮
→ 创建 actionId，状态 turning
→ 只点击一次精确语义“下一页”按钮
→ 等待与旧 surface 不同且稳定的新页面证据
→ commit actionId
→ 构建新 PageContract
→ 验证/释放预生成音频或现场生成
→ 播放新页
```

禁止：

- 同时 click、tap、keyboard、scrubber 多路尝试；
- 超时后无 actionId 地重复点击；
- 仅凭 DOM mutation 认定翻页；
- 旧 generation 回调再触发第二次翻页；
- 在新页未确认时展示其高亮。

### 10.7 手动翻页

用户按下/触摸翻页控件时立即：

1. 标记 manual-turn intent。
2. 停止旧音频、取消旧 TTS/解读请求和旧预取释放。
3. 清除旧高亮/marks。
4. 等页面变化稳定约 600 ms；A→B→C 的连续操作只处理最终 C。
5. 建立最终页 PageContract。
6. 如果此前正在朗读，则从最终当前页未读位置重新开始一次；若未播放则保持暂停。

### 10.8 音色和倍速

- 切换音色立即取消尚未播放的旧音色生成，保留当前阅读锚点，以新音色从当前逻辑位置重新生成并继续。
- 切换期间显示明确 loading/锁定状态。
- 倍速使用播放器速率，不需要重新加载网页或重新生成相同 TTS。
- 倍速弹层点击必须实际更新 ExoPlayer 和 UI；不得因透明 WebView/overlay 抢事件而失效。

---

## 11. 解读完整合同

### 11.1 产品表现

- TTS 朗读的是 LLM 生成的讲解，不是原文。
- 用户仍看到微信读书原始页面。
- 解读过程中在原文对应位置绘制与 Kindle 一致的手写手绘 marks：高亮、下划线、圈、序号等。
- marks 必须锚定当前真实页面文字几何，不能用截图 OCR 或重排后的隐藏文本坐标。

### 11.2 当前页 job

每一页对应一个不可变 ExplainPageJob：

```
jobId
bookId/chapterId
sourcePageFingerprint
visibleText
anchors/visualFragments
voiceId
depth/scenario
requestGeneration
```

只允许 job 所属的 page fingerprint 更新该页面 marks 和播放队列。页面变化后，旧 job 的晚到回调必须丢弃，不能刷新 WebView、回写上一页或触发二次翻页。

### 11.3 为什么过去会白屏、闪烁和卡死

典型根因是把解读状态更新绑定到 WebView identity/navigation：

- Compose key 随 loading/status/marks 变化导致 AndroidView 重建；
- 每个解读块触发 reload 或重新注入初始化脚本；
- bridge 回调更新整个 reader route，创建第二个 WebView；
- 旧 page job 完成后又将 URL/页面状态写回；
- overlay 高度反过来参与网页尺寸计算，形成测量反馈循环。

正确做法：WebView instance 与页面 job 解耦。marks 只更新复用的 overlay/SVG 节点；原 WebView 不导航、不 resize、不 reload。测量禁止使用会被 overlay 撑大的 `scrollHeight`，优先 reader root 的 `offsetWidth/offsetHeight` 与 Canvas 几何，并防御 0×0。

### 11.4 下一页解读预加载

扩展早期文档曾认为 WeRead 无法预取下一页，因为下一页不可见；iOS 后续已通过“保留瞬时顺序语义源 + 真实页确认”实现安全预取。因此 Android 目标是：

1. 当前页开始解读后，从 retained semantic source 预测紧邻下一页文本。
2. 预取下一页第一解读 block，必要时连同其 TTS。
3. 缓存 source page fingerprint、predicted next text、voiceId、depth、scenario 和 generation。
4. 当前页解读结束，触发一次语义翻页。
5. 真实下一页 Canvas 确认后，用 exact fingerprint 或有界顺序重叠验证预测。
6. 通过后直接消费预取结果；失败丢弃并为真实页请求。
7. marks 只有真实页确认后才能显示；预测数据绝不能画在旧页。

预加载成功要通过日志中的 `prefetch_ready → page_commit → prefetch_hit/consume` 证明，不能用听感推测。

### 11.5 连续页面的完成状态

一页解读结束、正在等待自动翻页时，UI 应显示“继续解读/正在切换下一页”一类进行中状态，不得每页闪一次“解读完成”。只有以下情况才进入 completed：

- 全书/章节确实结束；
- 微信读书明确拒绝下一页；
- 翻页确认最终超时并给出可重试状态；
- 用户主动停止。

---

## 12. 后台、前台、Mini Player 与进程恢复

### 12.1 退后台不应刷新页面

- `onPause/onStop` 不调用 WebView reload，不销毁 WebView，不重建 navigation route。
- TTS 音频由现有前台 `AudioPlaybackService` 持续播放，不能依赖 WebView JS timer 维持音频。
- 页面翻页状态机主要在 native；如果后台 WebView JS 被系统节流，已准备好的当前音频仍可播放，但翻页动作必须按平台能力验证。无法在后台可靠操作 WebView 时，应在边界等待，而不是继续播放不可见下一页内容。
- 回前台做轻量 probe，比较 URL、surface fingerprint 和 bridge heartbeat；probe 失败本身不等于需要 reload。

### 12.2 页面未刷新但 TTS 停止的常见原因

- Activity/Composable `DisposableEffect` 在失去前台时误调用 stop。
- WebView route 被当作播放器 owner，离开可见树即 deactivate。
- AudioPlaybackService 未真正进入 foreground 或音频焦点处理错误。
- app lifecycle listener 把 background 当作用户暂停。
- Mini Player state 没有接管当前 session。

WeRead 播放 session 的 owner 应是全局 PlayerCoordinator/Service，不是 WebView Composable 的可见生命周期。

### 12.3 回前台

若 WebView/Canvas 仍在：

- 不 reload；
- 重新取得当前 surface 证据；
- 若与旧页一致，恢复/继续当前音频和高亮时钟；
- 若页面由站点自行变化，按 manual page change 处理。

若 Android WebView render process 确认终止：

1. 保存当前 stable anchor：book/chapter、readerURL、page fingerprint、source cursor、paragraph/segment/time、mode、voice、speed。
2. 受控重建 WebView。
3. 等稳定 surface。
4. 对齐到旧锚点附近；匹配成功才恢复音频，失败停下并提示重试。
5. 不能无条件从当前页开头重读。

### 12.4 Mini Player 布局

- Mini Player 出现后，各页面的滚动内容必须增加等于 Mini Player + 底部导航 + safe inset 的动态 bottom padding。
- 不允许首页/书架最后一行被 Mini Player 挡住。
- Mini Player 点击展开不重建 WeRead WebView，不触发旋转和 reload。

---

## 13. 本地数据与缓存建议

### 13.1 Room 表

`weread_books`

- stable_id (PK)
- book_id
- title
- author
- cover_url
- reader_url
- progress_label
- last_synced_at
- last_opened_at
- last_page_fingerprint
- last_reader_url

`weread_reading_anchors`

- stable_book_id (PK/FK)
- chapter_fingerprint
- page_fingerprint
- source_cursor
- segment_index
- segment_time_ms
- mode
- voice_id
- speed
- updated_at

### 13.2 内存/磁盘预取缓存

缓存 key 至少包含：

- stableBookId
- sourcePageFingerprint
- predictedNextTextFingerprint
- mode(read/explain)
- voiceId
- explain depth/scenario
- generation

缓存必须有短 TTL、大小上限和离开书籍清理。正文、讲解与音频是否落盘要遵守现有隐私和缓存策略；不能把登录凭据写进数据库。

### 13.3 合并策略

- 相同 stableId 更新非空新字段。
- 新扫描缺作者/进度时保留本地已有非空值，避免瞬时 DOM 不全导致降级。
- readerURL 合法性优先，新 URL 无效时保留旧合法 URL。
- 远端书架暂时没扫到某本时不要立即删除；只有完整稳定扫描明确完成后才可标记缺失，并建议软删除。

---

## 14. 事件与日志合同

所有关键日志必须包含 `sessionId`、`bookId`、`mode`、`pageFingerprint(short)`、`generation`；翻页相关必须另含 `actionId`。

建议事件：

| 事件 | 关键字段 |
|---|---|
| `wr_web_create` | finalPxSize, density, cssViewport, uaMode |
| `wr_navigation` | url, reason, isReload |
| `wr_auth_state` | authenticated, evidenceKinds |
| `wr_shelf_scan_pass` | pass, visibleCount, totalUnique, scrollY |
| `wr_page_snapshot` | sourceChars, visibleChars, fragments, surface/layout fp |
| `wr_page_stable` | stabilityMs, fp |
| `wr_read_start` | chars, voice, carriedPrefixChars |
| `wr_timestamp_quality` | segmentId, count, coverage, monotonic, mode(word/sentence) |
| `wr_highlight` | segmentId, range, fragmentCount, yMetricsSource |
| `wr_prefetch_start/ready/hit/miss/discard` | predictedFp, actualFp, reason, latencyMs |
| `wr_turn_intent` | manual/auto, actionId, oldFp |
| `wr_turn_action` | selector, actionCount=1 |
| `wr_turn_commit/reject/timeout` | oldFp, newFp, changedEvidence |
| `wr_carry_created/consumed/discarded` | sourceCursor, chars, reason |
| `wr_explain_job_*` | jobId, sourceFp, block, status |
| `wr_lifecycle` | foreground/background/processTerminated |
| `wr_resume_anchor` | saved/matched/failed, reason |

日志不得包含全文、Cookie、账号 token、API key 或完整音频数据。文本定位可记录长度、哈希和极短脱敏 preview。

判断预加载是否成功的最小证据链：

```
prefetch_start(oldPage)
prefetch_ready(predictedNext)
turn_action(actionId, count=1)
turn_commit(actualNext)
prefetch_hit + consume
audio_start(nextPage)
```

若 `prefetch_start` 出现在 `turn_commit` 之后，就不叫预加载。

---

## 15. 已知问题目录：症状、根因、正确处理

| 症状 | 常见根因 | 正确处理 |
|---|---|---|
| 解除绑定后白屏 | 清站点数据后仍直达 shelf/reader；同步遮罩挡住登录页 | 回到主页登录 URL；认证前不显示同步栏 |
| 大量作者 Unknown | 只取 DOM 文本，标题误取图片 alt“书籍封面” | 优先 Vue `book` 结构化字段，多级 fallback |
| 打开书长白屏 | 等固定超时、二次排版、注入过晚 | final geometry 后一次创建；document-start hook；稳定条件揭罩 |
| 先拉伸/超小后正常 | 先用错误 viewport 加载，再 resize/zoom | 导航前确定最终 viewport/crop，不运行期 resize |
| 页面刷新两遍、读两次 | WebView identity/size/theme/state变更导致重建或 reload | WebView 稳定 identity；状态和 overlay 增量更新 |
| 点击朗读无反应 | pageContract 尚未建立、bridge 丢消息、透明层抢事件 | 明确 ready gate 和 UI 状态；bridge ack；事件命中测试 |
| 读到整章/下一页但页面不翻 | 把隐藏 DOM 当当前页 | 语义源必须与 visible Canvas 相交 |
| 自动翻过两页 | 多路径翻页或旧回调二次触发 | actionId + 一次语义 click + evidence commit |
| 手动翻页继续读旧页 | 只监听最终 mutation，没在 pointer down 停音 | 捕获 intent 即停音，稳定最终页后重启一次 |
| 翻页后重复新页开头 | 没有 already-spoken source cursor | 跨页 carry cursor，消费已读前缀 |
| 页边把句子截断 | 每页独立标点切句 | 从语义源补到自然句末，精确边界翻页 |
| 高亮比文字略高 | 把 fillText baseline 当 top | 使用实际 ascent/descent + transform |
| 高亮覆盖多行空白/按钮 | 只存 union bbox | 保存 visualFragments 并按 visible/pager 裁剪 |
| 高亮继续画到页外 | 未按 surface/generation 过滤 | fail closed，翻页即清除旧 generation |
| 只有英文词级高亮 | 语言白名单 | 每个 AudioSegment 按 timestamp 质量决定 |
| 中文整句被当作一个单词 | 只判断 timestamp 非空 | 单 timestamp/低覆盖识别为句子级 |
| 解读时不停闪白/刷新 | marks/status 驱动 WebView 重建或 reload | WebView 与 job 解耦，复用 overlay |
| 自动翻页后仍解读上一页 | 旧 job 回调没有 fingerprint/generation 门控 | 不可变 page job，晚到结果丢弃 |
| 每页显示“解读完成” | page complete 与 session complete 混淆 | page continuation 状态，终局才 completed |
| 声称预加载但翻页后才请求 | 没保留下一页语义候选 | retained source 预测，翻页前 ready，真页校验 |
| 退后台音频停但页面没刷新 | 播放 owner 绑在 Composable/WebView lifecycle | 全局前台 Service 持有 session |
| 回前台重置开头 | background 当 reload；无恢复锚点 | 不 reload；process death 才重建并锚点恢复 |
| 深色转浅色后字仍灰白 | 只覆盖 background | 切换微信读书原生完整主题配置 |
| 倍速弹层点不动 | WebView/overlay z-order 或 pointer interception | Compose hit-test/层级测试，状态直达 ExoPlayer |
| Mini Player 挡住底部内容 | 页面未动态增加 bottom inset | 统一 Scaffold/insets 从 player state 派生 |
| Overlay 导致页面越来越高 | 用 scrollHeight 测量自身注入 overlay | 用 reader root/Canvas offset geometry，排除 overlay |

---

## 16. 测试策略

### 16.1 纯 Kotlin 合同测试（先写）

- 书籍 stableId 和增量合并。
- author/title/cover 多来源 fallback。
- 文本 NFKC、引号、dash、空白规范化与原始索引映射。
- page fingerprint 与 incidental repaint 排除。
- PageTurnContract 保证 action count 始终为 1。
- A→B→C 手动翻页 debounce 只提交 C。
- cross-page carry cursor 创建、消费、手动跳页失效。
- timestamp 数量、覆盖率、单调性、区间验证；每 segment 单独回退。
- 单 timestamp 整句不得误判词级。
- explain prefetch 的 voice/depth/source/actual-page 验证。
- 旧 generation/job 晚到结果丢弃。

### 16.2 JS fixture 测试（不依赖真站）

保存去敏后的结构 fixture：

- preRender 瞬间出现后清空；
- 单 Canvas、多个 Canvas、drawImage 列复制；
- clearRect 后重新绘制；
- 段落跨页；
- pager 与正文相邻；
- Vue 书架组件有/无 author；
- SPA 章节切换；
- 0×0 容器过渡态；
- overlay 已存在时重复安装脚本。

验证 hook 幂等、快照同步、旧 generation 排除、visualFragments 与 pager 裁剪。

### 16.3 Android WebView instrumented tests

- 使用本地 fixture 页面加载 JS bridge。
- document-start 注入确实早于 preRender 清理。
- WebView 只创建一次，Compose state 更新不重建。
- final geometry 非零后才导航。
- 浅/深主题整套生效。
- 前后台切换不 reload；Service 音频不中断。
- WebView render process 模拟死亡后走 anchor 恢复。
- Mini Player 出现后所有页面底部可滚到。

### 16.4 真机生产书测试矩阵

至少覆盖：

- 免费书、付费已购书；
- 小说长段落、短句/对话、散文、章节开头/结尾；
- 中文和至少一本含大量西文/数字/标点的书；
- 浅色和深色；
- 不同字体大小/微信读书排版设置；
- 小屏和大屏 Android；
- 弱网、断网恢复；
- 自动翻 10 页以上；
- 快速手动连续翻页；
- 朗读/解读切换；
- 音色切换、倍速切换；
- 退后台 5–15 分钟再返回；
- 锁屏、耳机控制、来电/音频焦点中断；
- 登录过期和主动解除绑定。

---

## 17. Android 分阶段实施计划

### Phase A：纯合同与基础设施

- 建立 `weread` 独立 package。
- 建立 models、normalizer、fingerprint、timestamp validator、page-turn contract、carry cursor。
- 建立上述纯 Kotlin 单元测试。
- 明确 WebView 版本和 document-start 注入能力。

完成标准：核心状态转移无需 WebView 即可测试；一次翻页和 segment 级时间戳判断有回归测试。

### Phase B：绑定、书架、存储

- 首页全球可见模块。
- 桌面 UA 登录、自动进入 shelf。
- 认证判断和未登录状态。
- 多轮书架扫描，优先 Vue book 数据。
- Room 持久化、同步/刷新、搜索/排序。
- 设置解除绑定并定向清站点数据。
- 微信读书不进入通用 Continue。

完成标准：退出绑定后可重新登录；真实书架大部分标题/作者/封面正确；未登录不显示同步栏。

### Phase C：稳定 WebView 宿主

- final geometry 后一次创建。
- desktop UA + mobile-suitable viewport。
- 竖屏锁定。
- 系统主题完整跟随。
- 稳定 loading cover。
- bridge 安全白名单和 schema。
- 状态变化不 reload、不重建。

完成标准：打开同一本书不出现超小/拉伸画面、不闪两次、不双触发朗读。

### Phase D：页面捕获与证据

- document-start DOM/Canvas/page hooks。
- transient semantic snapshot。
- fillText/clearRect/drawImage generation。
- current visible Canvas 合同、visualFragments、pager 裁剪。
- surface/layout fingerprint 与 page evidence。
- SPA route reset。

完成标准：连续手动翻页时每次只产出一个稳定的真实当前页；没有隐藏下一页文本混入。

### Phase E：朗读闭环

- 当前页 TTS。
- segment timestamp capability validation。
- 句子/词级高亮。
- 自动翻页一次动作。
- 手动翻页停音/最终页重启。
- 跨页自然句与 carry cursor。
- 下一页 TTS 预测预生成和真实页校验。
- 音色/倍速/额度统一。

完成标准：自动连续 10 页无跳页、无重复、无断句；手动 A→B→C 只读 C；日志证明 prefetch hit。

### Phase F：解读闭环

- 不可变 ExplainPageJob。
- 当前页 LLM/TTS 与手写 marks。
- marks 锚定真实 visualFragments。
- 下一页第一 block 预取和真页校验。
- 连续页状态不显示完成。
- 旧 job 晚到丢弃。

完成标准：连续解读多页不 reload/白屏；下一页只解读当前页；mark 风格与 Kindle 一致。

### Phase G：生命周期和上线加固

- foreground Service 持有 session。
- 退后台/回前台不 reload。
- Mini Player/全屏无重建和动态 bottom inset。
- render process death 锚点恢复。
- 弱网、登录过期、超时和错误 UI。
- 产品分析与隐私合规。
- 真机矩阵、长稳测试、性能和内存检查。

---

## 18. P0 验收标准（任何一项失败都不能上线）

1. 同一个自动翻页事务绝不执行两次页面动作，不能跳页。
2. 当前页读完必须翻到下一页；不能停在旧页继续读隐藏内容。
3. 翻页后不能重读已在上一页读过的句首。
4. 手动翻页立即停止旧页音频，稳定后只读最终当前页。
5. 高亮必须与实际 TTS segment 同步，不得指向错误句子或页外区域。
6. 词级高亮由 timestamp 质量决定，不按语言写死；失败只回退当前 segment。
7. 解读翻页后使用新页内容，旧 job 不得污染新页。
8. 朗读/解读状态变化不得引发 WebView reload、白屏或闪烁。
9. 打开书只经历一个最终布局，不先超小/拉伸再放大。
10. App 退后台后音频继续；回前台不从页首重读。
11. 主动解除绑定后能重新看到登录页，且未登录不显示同步栏。
12. WebView bridge 只对可信微信读书域开放，不泄露凭据或全文日志。

---

## 19. 性能目标

以下为建议预算，应在真实设备记录 P50/P95：

- WebView create → 首个稳定可见页面：优先 < 2 s（已登录、缓存命中）；弱网单独统计。
- 页面 snapshot bridge 序列化：避免传整章；目标 < 50 ms 主线程阻塞。
- 手动翻页 intent → 旧音频停止：< 100 ms。
- 新 surface 稳定 → 正确高亮/音频开始：缓存命中目标 < 300 ms。
- 自动翻页听感间隙：预取命中时尽量接近自然停顿，不额外增加数秒空白。
- marks 更新不得触发网页 layout；每帧绘制不阻塞 WebView/Compose。
- retained semantic source、Canvas draw records 和预取缓存必须有 generation/容量清理，防止长时间阅读内存增长。

---

## 20. 参考实现与阅读顺序

### 20.1 跨端网页渲染权威：Chrome 扩展

仓库：`/Users/xuxuheng/Documents/MyProject/readout-desktop`

按顺序阅读：

1. `src/extractors/WEREAD-ARCHITECTURE.md`
2. `src/entrypoints/weread-intercept.content.ts`
3. `src/entrypoints/weread-hook.content.ts`
4. `src/extractors/weread.ts`
5. `docs/weread-highlight-arch.md`
6. `docs/quickread-weread-explain-impl.md`

扩展提供网页端事实：main-world Canvas 拦截、transient preRender 捕获、可见页抽取、Range/CSS/SVG overlay、高亮与语义翻页。注意扩展旧文档中“无法预取下一页”的判断是历史状态；移动端现在应采用本文/iOS 的预测 + 真页确认合同。

### 20.2 移动端状态机权威：iOS

仓库：`/Users/xuxuheng/Documents/CastReader`

核心文件：

- `docs/WeRead-iOS-Highlight-Pagination-Contract.md`
- `CastReader/Models/WeReadModels.swift`
- `CastReader/Services/WeReadLibraryStore.swift`
- `CastReader/Services/WeReadWebScripts.swift`
- `CastReader/Services/WebReaderBridge.swift`
- `CastReader/Views/WeRead/WeReadLibraryViews.swift`
- `CastReader/Views/Reader/WebReaderView.swift`
- `CastReader/ViewModels/ReadAloudViewModel.swift`
- `CastReader/ViewModels/ExplainViewModel.swift`
- `CastReader/ViewModels/PlayerCoordinator.swift`
- `CastReader/Services/AudioPlayerService.swift`
- `CastReader/CastReaderApp.swift`
- `scripts/test-weread-ios-contract.mjs`

iOS 提供移动端已验证合同：一次性 viewport、竖屏锁定、后台生命周期、页面证据、跨页 carry、read/explain 预取、系统主题、Mini Player 与 mode callback 所有权。

### 20.3 Android 当前基础

仓库：`/Users/xuxuheng/Documents/CastReader-Android`

- `AGENTS.md`：Kotlin 2.0.21、Compose、minSdk 24、target/compileSdk 35。
- `player/service/AudioPlaybackService`：后台连续播放基础。
- `player/manager/GlobalPlayerState`：全局播放器与 Mini Player UI 状态。
- `player/manager/PlaybackController`：TTS 生成编排。
- `player/manager/AudioPlayerManager`：ExoPlayer segment/word 回调。
- `data/local/VisitorService`：当前 DataStore 身份与本地状态入口。

Android agent 应先确认实际文件路径和当前分支代码，不要仅凭本文路径假设类未变。

---

## 21. 给 Android 实施者的工作原则

1. 先完整读扩展和 iOS 权威文件，再写代码。
2. 先写纯 Kotlin/JS 合同测试，再接生产 WebView。
3. 不把站点 DOM selector 散落到 Compose；集中在版本化 `WeReadScripts`。
4. 不把 WebView reload 当恢复策略。
5. 不以“DOM 中有文本”替代“用户当前看得到”。
6. 不用多个翻页 fallback 掩盖页面证据缺失。
7. 不让旧 generation、旧 job 或取消后的异步回调改变当前页面。
8. 不为追求无缝而在真实页面确认前播放预测数据。
9. 真机日志是阈值调整依据，但不以补丁堆叠替代统一状态机。
10. 每个 Phase 都应提交测试、日志样例和未验证项；遇到微信读书页面变化时先更新 fixture/合同，再改 selector。

---

## 22. 最终交付清单

- [ ] Android WeRead 独立模块与架构说明。
- [ ] 首页全球可见入口、连接态/已连接态。
- [ ] 登录、书架扫描、本地同步、刷新、搜索、排序、解除绑定。
- [ ] 最终几何一次创建、稳定遮罩、系统主题、竖屏锁定。
- [ ] document-start DOM/Canvas hooks 与安全 JS bridge。
- [ ] PageContract、visualFragments、surface evidence、generation。
- [ ] 当前页朗读、segment 级 timestamp 验证、高亮。
- [ ] 单次自动翻页、手动翻页重启、跨页 carry。
- [ ] 下一页 TTS 预生成并经真实页校验。
- [ ] 当前页解读、Kindle 风格手写 marks、下一页预取。
- [ ] 前台 Service、Mini Player、后台/恢复、process death 锚点。
- [ ] 免费额度/Pro/音色/倍速统一。
- [ ] 纯 Kotlin、JS fixture、instrumented 和真机测试。
- [ ] P0 12 项全部通过，附关键日志证据。
