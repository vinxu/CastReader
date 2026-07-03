# Kindle 朗读适配：问题复盘、最终方案与 Android 对齐标准

> 当前版本范围：**只交付 Kindle Read Aloud**。Kindle 书籍页的 `Explain` 入口先隐藏，解读放到后续版本继续适配。本文用于沉淀 iOS 适配过程中踩到的问题、最终架构，以及 Android 实现/验收标准。

## 1. 产品边界

Kindle 是独立内容源，不属于 6 个解读场景。CastReader 只保存用户本机授权 session 下同步到的 Kindle 书籍元数据，不保存 Amazon 密码，不导出整本书内容。

正确的信息架构：

- `Connect Kindle`：只负责打开 `read.amazon.com/kindle-library`、登录、同步书架。
- 原生 `Kindle Library`：展示 CastReader 本地缓存的书架 metadata，包括封面、书名、作者、进度、最近打开/同步。
- `KindleBook`：打开具体书籍的 Kindle 页面；用户在当前可视位置点 Read Aloud，从当前页开始朗读。
- 现阶段 KindleBook 顶部只保留 `Read Aloud`，隐藏 `Explain`。

## 2. 已遇到的核心问题

1. **把登录页、书架页、书页播放页混在一起**
   - 早期在 Connect WebView 里也能点进书、朗读、解读，导致窗口套窗口、播放器/高亮落在底层。
   - 最终原则：Connect 只登录/同步；读书只能从原生 Kindle 书架进入 KindleBook。

2. **误把 Amazon 营销页/提示页识别成书架**
   - 只抓页面中的链接和图片会把“下载 App”“了解 Kindle”等卡片当作书。
   - 最终原则：书架同步必须用 ASIN、reader URL、明确 Kindle book 信号过滤；无真实 book signal 不合并书架。

3. **Kindle 页面不是 DOM 文本，而是图片/blob 渲染**
   - 普通 Web 朗读可以直接定位 DOM 文本；Kindle reader 主要是页面图片。
   - 最终原则：先捕获当前可视 Kindle page bitmap，再 OCR 得到文字、段落、词 bbox，用 bbox 驱动 TTS 高亮。

4. **高亮偏移**
   - 主要原因是截图、OCR bbox、页面显示区域、overlay 坐标之间没有用同一个坐标系；底部播放器高度变化也会触发 Kindle 重排。
   - 最终原则：高亮必须挂在 Kindle 当前页图片所在的页面层级上，overlay 随图片缩放/滚动同步更新；不要把截图拿出来另起一个固定容器播放。

5. **单词高亮跳到相同单词**
   - 全页全局查找单词会命中前面重复词。
   - 最终原则：TTS word 只能在当前 paragraph/utterance 的 OCR word route 里顺序匹配，匹配游标单调向前，不能全页重搜。

6. **播放越往后越偏**
   - 行距、截图缩放、裁剪后的坐标换算只要有一点误差，连续多行后会累积。
   - 最终原则：不对 OCR 图做任意裁剪；OCR bbox 归一化到原始 page bitmap，再由 JS 用当前页面图片的实时 client rect 映射到 overlay。

7. **自动滚动破坏视觉动线**
   - 一开始为了把高亮居中，滚动太频繁、幅度太大，会出现先滚到别处再滚回来。
   - 最终原则：滚动服务于“当前朗读内容保持可见”，不是每个词/段都强制居中；进入下一页时先滚到页顶部，页内只在高亮接近底部舒适区时小幅滚动。

8. **下一页顺序错、回头播放、跳过句子**
   - 如果只按“当前最大图片”或视觉位置找下一张，容易拿到旧图或回头图。
   - 最终原则：每张 Kindle page 必须有稳定 `pageKey/contentKey`；预加载只能以 `afterKey` 为锚找下一页，不能靠最大图片猜测。

9. **跨页断句**
   - 手机 Kindle 每页文本少，若每页独立 TTS，一页末尾经常把句子切断。
   - 最终原则：文本队列层要检查当前页最后 utterance 是否以句末标点结束；未结束时，把下一页开头 paragraph 拼成一个跨页 utterance，同时保留跨页 render route。

10. **播放和翻页耦合过重**
    - TTS 完成一个 paragraph 时才滚动/抓下一页，容易造成声音断一下、高亮停一下。
    - 最终原则：页面缓存、文本队列、播放、渲染四层解耦，播放层永远消费已准备好的队列；页面层负责提前缓存。

11. **后台/锁屏连续播放**
    - 锁屏后音频能继续，但 WebView 滚动/截图能力不稳定。
    - 最终原则：进入后台前至少缓存当前页和下一页音频/文本；后台期间以已有音频队列连续播放，低水位时若无法抓页，要给出可恢复状态，不崩溃。

12. **外部音频打断后状态不一致**
    - 被别的 App 打断后，底部播放器仍显示播放中。
    - 最终原则：播放器必须监听系统音频 session interruption，打断后 UI 回到暂停态，不自动恢复播放。

13. **同一本书重复打开**
    - 播放中再次点击同一本书，如果新建一套 WebView/OCR，会导致页面、音频、高亮错乱。
    - 最终原则：同一本书只有一个 active playback session；点击同一本书直接回到现有 session。

## 3. 最终架构

Kindle 朗读必须拆成四层，禁止继续把逻辑塞到“下一页推进”函数里。

### 3.1 页面缓存层 Page Cache

职责：

- 注入 Kindle WebView bridge。
- 捕获当前可视页 bitmap、pageKey、URL、progress。
- 按 `afterKey` 预抓下一页。
- 维护 `currentPage` / `cachedNextPage`，并保证 pageKey 单调前进。

输入：Kindle WebView 当前状态。

输出：

- `CapturedKindlePage`
- page bitmap / image size
- pageKey/contentKey
- OCR-ready data URL 或 bitmap

### 3.2 文本队列层 Text Queue

职责：

- 对 page bitmap 做 OCR。
- 聚类为 paragraphs、words、bbox。
- 按段落生成 utterances。
- 处理跨页断句，把当前页尾部与下一页头部拼成一个逻辑 utterance。
- 为每个 utterance 生成 render route：每个词属于哪一页、哪个 paragraph、哪个 word bbox。

输出：

- `KindleTextQueue`
- `KindleUtterance`
- `KindleWordRoute`

关键约束：

- word matching 只在当前 utterance 的 OCR words 内单调前进。
- 不允许全页按 word 文本反复搜索。

### 3.3 播放层 Playback

职责：

- 只消费文本队列层给出的 utterances。
- 预生成当前 utterance 和下一 utterance 的 TTS。
- 控制播放、暂停、速度、跳转、系统音频中断。
- 管理 mini player、锁屏 metadata、封面。

关键约束：

- 播放层不直接控制 WebView 抓图。
- 切下一页不能等到音频播完才开始准备。
- 低水位时可以显示 preparing，但不能崩溃或回头播放。

### 3.4 渲染层 Render

职责：

- 把当前 TTS timestamp 映射到 `KindleWordRoute`。
- 调用 WebView bridge 在当前 Kindle 页图片层上绘制高亮。
- 根据高亮位置判断是否需要滚动。

关键约束：

- overlay 必须跟随 Kindle 页图片所在层级和滚动，不是 app 顶层固定蒙版。
- 坐标映射以 page bitmap 原尺寸为基准，JS 根据实时 client rect 换算。
- 滚动只保持高亮可见，不做过度居中。

## 4. 当前 iOS 实现要点

参考文件：

- `CastReader/Views/Kindle/KindleBookView.swift`
- `CastReader/Services/KindleWebScripts.swift`
- `CastReader/Services/KindleLibraryStore.swift`
- `CastReader/Views/Kindle/KindleLibraryConnectView.swift`
- `CastReader/Views/Kindle/KindleHomeSection.swift`

当前 iOS 发版策略：

- KindleBook 顶部隐藏 `Explain`，只展示 `Read Aloud`。
- `selectMode(.explain)` 被保护性拉回 `.read`。
- Kindle 书架同步保留账号绑定信息，设置页支持解绑。
- 解绑会停止 Kindle 播放，清本地书架，清 Amazon WebView website data。
- mini player 显示书籍封面；同一本书重复点击回到现有 session。

## 5. Android 对齐要求

Android 本轮目标：**只完成 Kindle Read Aloud，不开放 Kindle Explain**。

必须实现：

- KindleBook 顶部隐藏 `Explain`。
- KindleBook 底部只保留 Read Aloud 播放入口和现有播放器能力。
- Connect Kindle 不提供朗读/解读入口。
- 原生 Kindle Library 点击书进入唯一 KindleBook session。
- 同一本书播放中再次点击，回到现有 session，不新建第二套 WebView/OCR。
- Read Aloud 从用户当前可视页开始，不跳到别页、不弹二次确认。
- 高亮绘制在当前 Kindle 页图片对应位置，不能固定在页面某个角落。
- 自动滚动与高亮节奏一致，不能闪跳、回滚、跳过内容。
- 页面顺序由 pageKey/afterKey 驱动，不能用“最大图片”猜下一页。
- 至少预加载下一页 OCR/TTS，避免每页之间明显停顿。
- 被系统音频打断后，播放器 UI 回到暂停态。

## 6. 验收标准

1. 首页未绑定 Kindle：显示 Connect Kindle。
2. 登录并点 Sync 后：首页 Kindle 模块展示原生书架，不展示 Amazon 网页。
3. 设置页能看到 Kindle 已绑定账号，解绑后首页清空 Kindle 书架并要求重新登录。
4. 点击一本书进入 KindleBook，顶部没有 `Explain`。
5. 用户手动滚到一页中间，点击播放，从当前可视页顶部/首个可读段开始，不能跳到其它页。
6. 高亮必须贴合单词/短语位置，不能固定在一个坐标，也不能越播越偏。
7. 同一段有重复单词时，高亮不能跳回前面的同词。
8. 播完一页后，下一页必须顺序衔接，不回头、不跳过句子。
9. 页面滚动时，声音不断，高亮不停止；如缓存不足，显示短暂 loading 并恢复，不崩溃。
10. 后台/锁屏播放至少持续播放已缓存音频；回到前台时 UI 状态与真实播放状态一致。

## 7. 下一版本再做 Kindle Explain

Kindle Explain 需要在 Read Aloud 稳定后再做，因为它还多一层 LLM mark 锚定：

- Explain TTS 读讲解，不读原文。
- mark 要画回 Kindle 原文页图片上。
- mark 需要跨页、跨批、预生成和去重。
- 解读入口放开前，必须先确保 Kindle Read Aloud 的页面缓存、文本队列、播放、渲染四层稳定。
