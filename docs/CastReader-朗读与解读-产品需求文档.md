# CastReader 朗读 & 解读 —— 产品需求与技术方案文档

> **文档目的**：供 **Android 端**开发对等功能。涵盖产品定位、功能需求、交互流程、**核心算法（语言无关）**、**完整后端接口契约**、关键技术决策与踩坑清单。
> iOS 端已实现并真机验证；本文把"为什么这么做 / 踩过哪些坑"沉淀下来，Android 直接照做、避免重复踩坑。
> 标注约定：✅ 已实现并验证 · 🟡 已实现待打磨 · ⬜ 规划中。

---

## 一、产品概述

CastReader 是**工具型 TTS 应用**（不是图书 App）。核心价值：**让用户同时用耳朵和眼睛锁定注意力**，像老师指读。两条产品线：

| 产品线 | 一句话 | 听什么 | 看什么 |
|---|---|---|---|
| **朗读 (Read Aloud)** | TTS + 词级高亮 + 自动滚动「三位一体」 | 原文的语音 | 原文，当前词高亮 + 自动滚动跟随 |
| **解读 (Explain / QuickRead)** | TTS 朗读 LLM 生成的**讲解**（非原文） | LLM 讲解的语音 | **原文**，按时间点动画绘制**手写体标注**（高亮/下划线/圈/序号） |

**输入源**（统一抽象，见第三节）：网页 URL · PDF · DOCX · EPUB · 拍摄/相册（端上 OCR）· 纯文本 · **剪贴板快捷入口**（第六节）。

**全局播放**：播放会话脱离阅读界面，退出后**继续播放 + Mini Player**（第七节）。

---

## 二、术语

- **段落 (paragraph)**：阅读与定位的最小单元。一段一条文本；图片源额外带逐词 bbox。
- **块 (block)**：解读后端把内容切成的讲解单元。一个块 = 一段 LLM 讲解文本 + 若干 mark。
- **mark / 标注**：解读时画在原文上的手写体记号（高亮/下划线/圈/序号）。
- **segment / 音频段**：TTS 一次返回的一段音频 + 词级时间戳。一段文本可能流式返回多个 segment。
- **会话 (session)**：一次"文档 + 朗读VM + 解读VM"的播放上下文，全局存活。

---

## 三、统一文档模型（核心抽象，强烈建议 Android 照搬）

让「拍摄照片 + OCR」与「重排纯文本/网页」两类源，在**朗读高亮**与**解读标注的定位**上走**同一套接口**。

```
ReadingDocument {
  sourceKind: photo | text | web | docx | pdf | epub
  language: 语言码 (zh / en / ...)
  paragraphs: [ReadingParagraph]
  imageData?: 图片字节（photo 源）
  imagePixelSize?: 图片像素尺寸（photo 源，OCR 归一化坐标用）
  fileData?: 原始文件字节（pdf / docx / epub 源，本地渲染用）
  sourceURL?: 原始网址（web 源）
}

ReadingParagraph {
  id: 全局连续递增整数（== 数组下标，定位/批次依赖此性质）
  text: 段落文本
  type: paragraph | heading | blockquote | code | list | caption
  words: [OCRWord]          // 仅 photo 源
  pdfPageIndex?: Int        // 仅 pdf 源：所在页
  pdfRange?: 字符范围        // 仅 pdf 源：页内原始字符范围（含换行，高亮定位用）
}

OCRWord { id, text, bboxNorm }   // Vision 归一化包围盒，原点左下
```

**定位解析器接口**（朗读高亮 + 解读标注共用）：

```
ReadingAnchorResolver:
  rectsForWord(paragraphIndex, wordIndex) -> [Rect]      // 朗读：当前词的矩形（可能跨行多个）
  rectsForCharRange(paragraphIndex, range) -> [Rect]     // 解读：字符范围覆盖的矩形（按行）
```

- **photo 源**：用 OCRWord.bboxNorm + 显示几何换算（Vision 归一化原点左下 ↔ 屏幕点原点左上，需翻转 Y）。
- **文本/网页源**：用渲染层（iOS 用 UITextView / WebView DOM Range）的布局信息算矩形。
- **PDF 源**：用 PDF 引擎的文本↔位置映射（iOS 用 PDFKit `findString` + `selectionsByLine`）。

> **为什么要统一**：高亮和标注本质都是"段落 + 词/字符范围 → 屏幕矩形"。统一后，朗读和解读两条线、所有输入源，复用同一套定位代码，只在最底层按源实现 resolver。

---

## 四、朗读 (Read Aloud) ✅

### 4.1 功能需求

1. **三位一体**：逐段 TTS 朗读，**当前词高亮**，**自动滚动**让当前段落保持在视野舒适区。
2. **流式 + 预生成**：边生成边播，段与段之间**无明显停顿**。
3. **多源**：网页/PDF/DOCX/EPUB/照片/文本均可朗读，保留各自原始排版。
4. **播放控制**：播放/暂停、±15s、变速（0.5x–3.0x，免费档 ≤2.0x）、上一段/下一段、点击任意段落跳读。
5. **后台播放**：锁屏/切后台继续播（含系统 Now Playing 控制中心）。

### 4.2 交互流程

```
选择输入源 → 构建 ReadingDocument → 进入阅读器（默认"朗读"）
  → 点播放 → 逐段流式生成+播放
  → 当前词高亮 + 自动滚动跟随
  → 段落播完自动推进下一段
  → 可暂停/变速/±15s/点段落跳读
  → 收起阅读器 → 继续播放（Mini Player，见第七节）
```

### 4.3 核心算法

#### (a) 逐段流式生成 + 预生成下一段（消除段间 gap）✅

```
播放第 i 段时：
  1. 对第 i 段调 TTS（流式，回调返回一个个 AudioSegment）→ 入播放队列
  2. 第 i 段入队后，后台预生成第 i+1 段，结果缓存（prefetched[i+1]）
  3. 第 i 段播完 → 若 prefetched[i+1] 已就绪 → 直接入队"秒接"；否则实时生成
  4. 切段/停止时取消正在进行的生成、清缓存
```

> **关键**：预生成的是"下一段"，在当前段**播放期间**后台完成。只要当前段播放时长 > 下一段生成时长（通常成立），段间就无感。

#### (b) 流式播放竞态 —— "还有后续段"标志 ✅（**重要踩坑**）

流式生成时，音频可能播得比生成快。用一个布尔标志 `moreSegmentsExpected` 解决：

```
生成前：清空队列；moreSegmentsExpected = true
每个 segment 到达：入队（若播放器在等待则立即接上播放）
当前段播完且队列空：
  if moreSegmentsExpected: 进入"等待下一段"态（不结束）
  else: 触发"播放完成"回调（推进下一段 / 整篇结束）
生成完成或出错：moreSegmentsExpected = false（必须复位，否则永远等待）
```

> ❗ Android 必须实现等价机制，否则流式时会"播完一段就误判整篇结束"。

#### (c) 词级高亮定位 —— **直接渲染 TTS 处理后的文本，不要映射回原文** ✅（**重要踩坑**）

TTS 返回的 `processed_text` 与原文有差异（标点/空格规范化）。**不要把时间戳映射回原文**（会找不到/不同步）。

```
朗读当前段：渲染 TTS 返回的 processedText（多个 segment 的 text 拼接）
高亮在 processedText 内按时间定位：
  - 有词级时间戳（通常英文）：按当前播放时间落在哪个词的 [start, end] → 高亮该词字符范围
  - 无词级时间戳（通常中文，云端 TTS 不返回逐词）：句子级高亮，按段内播放进度推进到当前句
photo 源：用"游标"把当前时间映射到 OCR 词序号（线性、单调不减），高亮该词 bbox
未生成的段落：渲染 paragraph.text（原文）
```

> **中文为什么是句级**：云端 TTS 对中文不返回逐词时间戳，所以中文走句子级高亮（对齐 Chrome 扩展）；合成时仍会用音频时长合成字符级时间线，但那只给"解读"用（回填 mark 触发时刻），不用于朗读高亮。

#### (d) 去掉"自动换行/排版换行"造成的停顿 ✅（**重要踩坑**）

PDF/排版文本里的换行多是**视觉换行**（非句子边界）。若不处理，TTS 会在每个换行处停顿、断句。

```
切句只按"句末标点"（。！？；.!?; 等），换行不切句
喂给 TTS 的文本：删除句中的硬换行
  - CJK 字与 CJK 字之间的换行 → 直接删除（中文连续不留空格）
  - 其他（英文等）→ 替换为空格（保留词边界）
但定位用的原始范围要保留换行（高亮/标注按含换行的原文字符定位）
```

#### (e) 自动滚动 ✅

朗读时当前段落变化 → 滚动到该段（居中）。PDF 源滚到当前句的位置；图片源整页可见通常无需滚动。可后续做"舒适区"精细化（当前位置落在屏幕 15%~70% 之间不滚，超出才滚 + 手动打断回弹）。

### 4.4 各输入源渲染（保留原始排版）

| 源 | iOS 实现 | Android 建议 |
|---|---|---|
| 网页 URL | WKWebView 直接 load，注入 JS 提取正文段落 + DOM 高亮/标注 | WebView + JS（同一套注入脚本可复用） |
| DOCX | WebView 内 mammoth.js 转 HTML | WebView + mammoth.js（或服务端转） |
| EPUB | WebView 内 epub.js 渲染章节 | WebView + epub.js |
| PDF | PDFKit 原生渲染（保排版）+ findString 定位高亮/标注 | PdfRenderer / pdfium + 文本层定位，或 pdf.js |
| 照片/拍摄 | 端上 Vision OCR → 图片上叠加高亮/标注，可缩放滚动 | ML Kit / Tesseract OCR → 图片叠加层，ScrollView + 缩放 |
| 纯文本 | UITextView 渲染 | TextView / Compose Text |

> **照片源的显示要求** 🟡：照片要**按屏幕宽度铺满**（fit-width，字才够大）、**上下滚动**、**双指/双击缩放**、朗读/解读时**自动滚动跟随**当前词/标注（已在视野内不滚、超出才滚）。不要用 aspectFit 整张缩小（字太小）。

### 4.5 验收标准

①出声且当前词精确高亮、逐词/逐句推进 ②段间无明显停顿 ③段落切换自动滚动 ④点段落跳读 ⑤暂停/变速即时生效 ⑥锁屏继续播 + 控制中心可控。

---

## 五、解读 (Explain / QuickRead) ✅

### 5.1 功能需求

1. TTS 朗读的是 **LLM 生成的讲解文本**（不是原文）。
2. 播放过程中，在**原文**上按时间点**动画绘制手写体标注**（高亮/下划线/圈/序号）。
3. 底部**字幕**逐句显示当前讲解文本（短句一条条出，不是一大段）。
4. **边生成边播放**：三段式流式，第一块尽快出声，后续块预生成。
5. PDF 等长文档：**连续听完整本**，从当前页起逐"批"推进、批内有衔接。
6. 状态：通读中/讲解中/准备下一段 loading；播完可**重新播放**（复用缓存、不重复请求后端、不耗额度）。

### 5.2 交互流程

```
进入阅读器 → 切"解读" → 点播放
  → [后端 extract-plan(SSE)] 通读 → 返回总块数 + 第一块讲解
  → 第一块：TTS 讲解文本 → 入队播放
  → 播放中按"块时间线"逐个触发 mark（手写动画绘制在原文上）+ 自动滚到 mark 所在段
  → 字幕按播放进度逐句切换
  → 块播完 → 自动取下一块（已预生成则秒接）
  → 所有块播完 → 完成；可"重新播放"（复用缓存）
PDF 长文档：一批（≈一篇文章）的块播完 → 自动续下一批，直到全书末尾
```

### 5.3 三段式后端流程（核心，对接契约见第八节）

```
1. extract-plan  (SSE)   入：全文/段落 + depth   出：job_id + total_blocks + 第0块讲解(block_0)
2. extract-block (JSON)   入：job_id + block_idx  出：第 N 块讲解文本 + 该块的 mark 列表（at 未填）
3. compose-block (JSON)   入：job_id + block_idx + 该块 TTS 的词级时间线 + 总时长
                          出：回填了 at（触发时刻）的 mark 列表
```

- **block_0** 在 plan 阶段就返回（开头块尽快出声），其余块按 `block_idx` 逐个 `extract-block` 拉取。
- mark 的 `at`（触发时刻）需要**客户端**先对讲解文本做 TTS、拿到词级时间线，再回传给 `compose-block` 让后端对齐回填。

### 5.4 核心算法

#### (a) 单块准备流水线 ✅

```
prepareBlock(idx):
  1. 取讲解文本：block 0 用 plan 返回的 block_0；其余调 extract-block(job_id, idx)
  2. 对讲解文本做 TTS（收集所有 AudioSegment）
  3. 拼"块时间线"：把各 segment 的词级时间戳按"前序 segment 总时长"偏移累加
     （中文无词时间戳的 segment → 用音频时长按字数合成字符级时间戳）
  4. compose-block(job_id, idx, 块时间线, 总时长) → 回填 mark.at
  5. 返回 PreparedBlock { segments, marks(at已填), text, sentences(字幕用) }
```

#### (b) 块时间线触发 mark ✅

```
播放回调每个 tick：
  blockElapsed = 已播完的前序 segment 总时长 + 当前 segment 的 currentTime
  for mark in 当前块的 marks（按 at 排序）:
    if mark.at <= blockElapsed 且未触发过:
      标记已触发；锚定 mark 到原文（见 c）；绘制手写动画；滚动到该段
```

#### (c) mark 锚定到原文 —— 模糊匹配 (fuzzyFind) ✅（**关键算法，实测 100% 命中**）

mark 自带"锚文本"（讲解里引用的原文片段，可能带【】或被 LLM 改写）。要把它定位到**某段落的字符范围**。

```
locate(markText, document, near):
  query = normalize(strip【】《》等装饰(markText))   // 见下
  按搜索顺序遍历段落（near 段及邻域优先，再全文）：
    在该段做 match(query, 段落文本)，命中即返回 (段落index, 字符范围)
  全不中 → 返回空（fail-open：跳过这个 mark，宁缺毋错）

normalize(文本):
  只保留 [字母/数字/汉字假名谚文]，标点/装饰/符号一律剔除，空白坍缩为单空格，转小写
  同时记录"归一化字符 → 原始字符下标"的映射（回填原文范围用）
  // 剔标点是命中率关键：容忍 LLM 锚文本里多出的【】引号破折号等差异

match(query, 段落文本):
  ① 归一化后精确子串：query 是否为段落归一化串的子串 → 命中
  ② 首尾窗口（容忍中间改写）：取 query 首 k 字、尾 k 字（k≈query长/3，限 3..10）
     段落里先找到首窗口，再在其后找尾窗口；
     若 [首..尾] 跨度与 query 长度同量级（query/2 .. query*2）→ 命中该跨度
```

> **near 参数**：上一个命中的段落下标。它只影响**搜索顺序**（优先就近），不限制范围（全文都会找）。长文档里**每批解读开始时，把 near 设为当前批首段**，避免 mark 锚到前面批的重复文本而画到屏幕外。

#### (d) 字幕分句 —— 句切 + **长句二次切**（对齐扩展）✅（**踩坑**）

只按句末标点切，中文长句一条字幕就是一大段。必须二次切：

```
splitSentences(讲解文本):
  ① 按句末标点切句（。！？；.!?;… 换行；英文句点仅当后接空格/结尾才切，避免小数/缩写）
  ② 每句若 > chunkLimit(≈24 字) → 再按逗号/分号/顿号(，,；;、) 累积切到 ≤ chunkLimit
  → 得到一条条短字幕

字幕推进：按"块内播放进度"（blockElapsed / 块总时长）选当前句：
  累积字符比例首次 ≥ 进度的那条
```

#### (e) 块预取 ✅

播当前块时，后台预生成"下一块"（extract-block + TTS + compose），结果缓存。块播完若已就绪则秒接，否则显示"准备下一段…" loading。

#### (f) PDF/长文档：**逐批连续解读** ✅（**核心架构决策，见 5.5**）

```
从当前可见页首段起，按字数累积一"批"（pdfBatchCharLimit ≈ 3000 字 ≈ 5 页 ≈ 一篇短文）
对这一批做完整 extract-plan（一个 job_id），批内多个块连续播放
一批播完 → 从下一批首段起再来一遍，直到全书末尾（听完整本）
批间预取：当前批播放时，后台对下一批做 extract-plan（见 5.5 的坑）
```

#### (g) 手写体标注绘制 ✅

- 用**确定性随机种子**（由 段落index+字符范围+action 生成）生成手写抖动 path，**同一 mark 重绘不抖动**。
- 落笔动画：路径 trim 从 0→1（iOS 用 Shape.trim；Android 用 Path + PathMeasure 截取 / 属性动画）。
- 四种 action：`highlight`（荧光笔，半透明压在文字中下部，混合模式 multiply）、`underline`（抖动基线）、`circle`（包络椭圆，不闭合）、`number`（圈 + 序号数字）。
- 墨色：深墨蓝 RGB(0.17,0.24,0.31)；高亮用主题色（橙）+ 0.28 透明 + multiply。
- **各源渲染容器不同但算法同一套**：照片/文本用原生 Path 叠加层；网页/DOCX/EPUB 用注入 JS 画 SVG；PDF 用自定义 PDF 注解在 draw 里画同一套 path（注意 PDF 坐标 y 向上，需翻转）。

### 5.5 关键技术决策（**Android 必读，决定体验**）

#### 决策 1：长文档为什么"逐批"而不是"逐页"也不是"整本一次"

- 后端 `extract-plan` **无状态**（请求体没有"上下文/前文"字段）。
- **逐页**（每页一个独立 plan）→ 每页 LLM 从头讲、页间**没有衔接感**、每页第一块都是"导入"（标注少）。用户实测反馈"每页都是故事开始 xxx"。
- **整本一次** → 超长文本超 LLM 上下文 / 后端拒绝。
- **逐批**（一批 ≈ 一篇文章）→ 批内连贯、批边界才偶尔换口吻，是现实最优。

#### 决策 2：**批大小 = mark 密度的关键旋钮**（实测结论）

- 同一个后端，**喂的内容越多，它切块越粗、标注越稀**。实测：喂 9000 字 → 只切 6 块 / 20 个 mark → PDF 一页才一个 mark。
- 网页解读"mark 很密"是因为网页**一次只喂一篇文章**（~2000–4000 字），后端切小块、标注密。
- 所以把 PDF 批设到**对齐网页体量（≈3000 字）**，mark 密度就回到网页水平。
- 这是 LLM 行为的**补偿**（块数随长度亚线性增长、每块固定几个标注），不是理想形态。**根治在后端**：让标注密度由内容重要性决定、与输入长度解耦（放宽块数上限 / 调 prompt）。
- mark 稀疏 **不是锚定问题**——实测锚定 100% 命中（20/20 HIT，0 MISS），纯粹是批大小。

#### 决策 3：批间预取**只做 plan、不预生成 TTS**（**踩坑**）

- TTS 服务是**单请求模型**（内部只有一个 currentRequestId，新请求会让旧请求作废）。
- 若批间预取在后台对下一批生成 TTS，会和当前正在播放/预取的 TTS **抢占**，导致当前 TTS 被取消 → 报 **"TTS request was cancelled"**。
- 解法：批间预取**只调 extract-plan（网络规划），不碰 TTS**。切批时才生成那批第一块的 TTS（此刻 TTS 空闲、不冲突）。仍省掉了最耗时的"通读"那段 gap。

### 5.6 验收标准

①切解读点播放 → 通读后出声 ②讲解播放中手写标注按时刻出现在原文对应句、跟随滚动 ③字幕短句一条条出 ④块/批之间衔接顺、loading 提示 ⑤长文档连续听完整本、有衔接感 ⑥mark 密度接近网页 ⑦播完可重播不重复扣额度。

---

## 六、剪贴板快捷入口 🟡（网址/文本/图片已实现，文件待续）

### 6.1 需求

每次进入 App / 切到前台时，检测剪贴板内容，若可解析（网址 / 文本 / 图片 / 文件），**弹窗呈现** + 让用户选**朗读**还是**解读**，选完**直接进入对应播放页面**——不必每次手动粘贴再生成，缩短链路。

### 6.2 交互流程

```
App 启动 / 回前台 → 读剪贴板
  → 识别类型：URL / 纯文本 / 图片 / 文件(PDF/DOCX/EPUB/TXT)
  → 若有可解析内容且与"上次已处理的内容"不同 → 弹卡片：
       [内容预览] + 「朗读」「解读」「忽略」
  → 选朗读 → 构建 ReadingDocument → coordinator.open(doc, mode=朗读) → 进朗读页（自动开始）
  → 选解读 → 同上，mode=解读
  → 忽略 / 关闭 → 记住这次内容指纹，不再重复弹
```

### 6.3 要点

- **类型识别**：URL（正则 / 可解析为 http(s)）→ web 源；图片 → OCR 源；文件 URI → 按扩展名走 PDF/DOCX/EPUB/TXT；纯文本 → text 源。
- **去重**：记住"上次已弹过的内容指纹"（URL 字符串 / 文本 hash / 文件名+大小），相同不重复弹。每日或每次冷启动可重置。
- **隐私**：iOS 14+ 读剪贴板会触发系统提示；建议**仅在用户可见的弹窗动作里读**，或用 `UIPasteboard.detectPatterns`（只探测有无 URL 而不读全文）降低打扰。Android 注意 Android 12+ 剪贴板读取也有提示，遵循同样克制原则。
- **落点**：选完直接调用第七节的 `coordinator.open(doc, mode:)`，复用全局播放链路。

---

## 七、Mini Player（全局播放） ✅（阶段一）

### 7.1 需求

进入文章朗读/解读后，**收起阅读界面**，播放**不应中断**，而是缩略成一个**悬浮 Mini Player**（不是完整播放器），浮在首页/其它 Tab 上，除非用户主动关闭。类似 Apple Music：进歌看歌词/播放器，退出到首页仍有 Mini Player。

### 7.2 交互

```
任意入口 open(文档, 模式) → 全屏阅读器展开（完整播放器）
  → 点"收起" → 阅读器关闭，但播放继续，Tab 栏上方出现 Mini Player
Mini Player：[图标 标题 "朗读中/解读中"] [播放/暂停] [✕]
  → 点标题区 → 重新展开完整阅读器
  → 点播放/暂停 → 直接控制播放
  → 点 ✕ → 停止播放 + 清空会话 + Mini Player 消失
切 Tab、回首页 → Mini Player 始终在，播放不断
```

### 7.3 架构（**核心：把播放会话从阅读界面生命周期里抽出来**）

iOS 原来的问题：阅读器（模态）持有两个 VM，模态关闭 → VM 销毁 → 播放停止。

**解法：引入全局 `PlayerCoordinator`（挂在 Tab 容器层级，整个 App 生命周期存活）**：

```
PlayerCoordinator (全局单例 / 顶层状态):
  session: { id, document, readVM, explainVM } | null   // 一次播放会话，含两个 VM
  mode: 朗读 | 解读
  isReaderPresented: Bool                                 // 完整阅读器是否展开
  showsMiniPlayer = (session != null && !isReaderPresented)

  open(doc, mode):
    若 doc 与当前 session 不同 → 停掉旧会话、新建会话（建两个 VM）
    设 mode；isReaderPresented = true（展开完整阅读器）
  minimize(): isReaderPresented = false      // 收起 → Mini Player 接管（不停播放）
  expand():   isReaderPresented = true        // Mini Player → 完整阅读器
  close():    停掉两个 VM、session = null      // ✕ → 真正停止

Tab 容器:
  - TabView 之上叠加 MiniPlayerView（showsMiniPlayer 时显示，浮在 tab bar 上方）
  - 完整阅读器作为全屏 cover，由 isReaderPresented 控制（提到 Tab 层级，才能跨 Tab）
  - 所有入口（首页/文库/剪贴板）不再各自弹阅读器，统一调 coordinator.open(...)
阅读器：
  - 不再自己创建 VM（从 coordinator.session 注入）
  - "收起"按钮 = coordinator.minimize()（不是销毁，不停播放）
  - 不在 onDisappear 里 stop（关键改动：收起≠停止）
播放本身：TTS/播放器都是全局服务（单例），不依赖阅读界面存活——只要 VM 不被销毁、不调 stop，播放就继续
```

> Android 对应：把会话状态放在 Activity/Application 级的 ViewModel / 前台 Service；播放用前台 MediaSession Service；阅读界面是 Fragment/Compose 屏，收起只是返回不销毁会话；Mini Player 是叠在导航容器上的全局组件。

### 7.4 验收标准

①阅读中点收起 → 播放不停 + Mini Player 出现 ②切 Tab/回首页 Mini Player 仍在、播放不断 ③点 Mini Player 重开完整阅读器、状态一致 ④✕ 停止并消失 ⑤换文档 open → 旧会话停、新会话起。

---

## 八、文库 / 本地历史 ✅

### 8.1 需求

中间「文库」Tab = **本地历史记录**（类似浏览器的浏览历史）：把处理 / 朗读 / 解读 / 粘贴过的所有内容（文件、网址、剪贴板）留存，可**重新打开、删除、清除**。

1. **纯本地数据库**，不同步云端。
2. 列表管理：单项**滑动删除**；**「清除全部」不放列表页**（避免误触），下沉到**设置**较深处（带确认）。
3. UI 明示「**仅存本机、不上云**」。
4. **按来源类型（type）分类筛选**：默认「全部」，可切到 网页 / PDF / DOCX / EPUB / 图片 / 文本 单独查看；每类显示计数。
5. **搜索**：按标题 + 网址模糊匹配（大小写不敏感），与分类筛选叠加生效。
6. **时间显示**：每条显示「多久前读过」（基于 `lastOpenedAt` 的相对时间）。

### 8.2 数据模型

```
HistoryRecord {            // 元数据（轻量，列表显示用），存 index.json
  id: String               // = document.id（重开沿用，保证是更新而非新增 → 不产生重复项）
  title, sourceKind, sourceURL?, language
  createdAt, lastOpenedAt
}
原始数据 payload（按 id 存 <id>.payload）：
  web            → 不存（重开用 sourceURL 即可）
  text           → 全文 utf8
  photo          → 图片字节
  pdf/docx/epub  → 原始文件字节
```

### 8.3 行为

- **记录时机**：每次 `coordinator.open(doc)` → `record(doc)`：新文档新增；已存在则更新 `lastOpenedAt` 并置顶。
- **重新打开**：按 `sourceKind` 重建 ReadingDocument（**id 沿用 record.id**）：
  - web → 用 sourceURL 直建
  - text → 读 payload → `fromPlainText`
  - pdf → payload 写临时文件 → `fromPDFNative`
  - docx/epub → payload 字节 → `ReadingDocument(fileData:)`
  - photo → payload 图片 → **重新 OCR**（异步，故重开 photo 有几秒处理）
- **删除 / 清除**：删元数据 + 对应 payload 文件。
- **隐私提示**：列表底部常驻「历史记录仅保存在本机，不会上传或同步到云端」。

### 8.4 列表展示、分类与搜索

- **排序**：按 `lastOpenedAt` 倒序（最近打开置顶）。
- **行内容**：来源类型图标 + 标题 + 副标题「`类型` · `多久前读过`」。
- **分类筛选条**（横向胶囊，列表顶部）：`全部(n)` + 仅展示**实际出现过**的类型，各带计数；选中态高亮。少于 2 种类型时可隐藏整条。
- **搜索**：标题或网址 `localizedCaseInsensitiveContains`，与当前分类**叠加**过滤。
- **相对时间规则**（**勿用平台 RelativeDateTimeFormatter**——差值≈0 或为负时会吐 "in 0 seconds" 等怪串）：按秒差自判 `<60s→刚刚`、`<60min→X 分钟前`、`<24h→X 小时前`、`<48h→昨天`、`<7d→X 天前`、`<1y→M月d日`、`否则→yyyy年M月d日`；**负值（时钟漂移/未来）归「刚刚」**。
- **空态**：区分「整体无历史」与「分类/搜索无结果」（后者提示「该分类暂无记录」/「未找到匹配…」）。

### 8.5 各端本地存储对应

| 端 | 元数据 | 原始数据 |
|---|---|---|
| iOS | `Documents/History/index.json`（Codable 数组）| `Documents/History/<id>.payload` |
| Android | **Room** 数据库（HistoryEntity 表）| app 内部存储 `filesDir/history/<id>` |

> Android 用 **Room**（元数据表 + 查询 / 删除 / 清空）+ 内部存储存原始文件。**不接任何云同步**；重开按 sourceKind 重建（图片重新 OCR、PDF 重新解析）。
> **分类筛选 + 搜索直接用 Room 查询**（不在内存过滤）：
> `@Query("SELECT * FROM history WHERE (:kind IS NULL OR sourceKind = :kind) AND (:q = '' OR title LIKE '%'||:q||'%' OR sourceUrl LIKE '%'||:q||'%') ORDER BY lastOpenedAt DESC")`
> 相对时间**别用 `DateUtils.getRelativeTimeSpanString`**（0/负值附近同样不稳），按 8.4 的秒差规则自写。「清除全部」放 Settings 里（`@Dao deleteAll()` + 清空文件目录）。

### 8.6 验收标准

①处理任意内容后「文库」出现该条并置顶 ②点击重新打开并可播放 ③滑动删除单条、对应文件一并删除 ④**设置**里「清除全部历史」清空全部（带确认）⑤重开同一条不产生重复项（id 沿用）⑥列表明示仅存本机 ⑦切换分类只显示该类型且计数正确 ⑧搜索按标题/网址过滤、与分类叠加 ⑨相对时间正确（刚处理→「刚刚」，不出现英文/异常串）。

---

## 九、后端接口契约（完整，Android 直接对接同一套后端）

### 9.1 云端 TTS

**端点（节点路由，对齐扩展）**：
- **CN 节点**（默认）：`https://uu122431-80b4-9c6a8f65.bjb1.seetacloud.com:8443`（CN 实例轮换，可被远程配置覆盖）
- **US 节点**（默认）：`http://api.castreader.ai:8123`
- **远程配置**（24h 缓存覆盖默认）：`GET https://castreader-config-1323065328.cos.accelerate.myqcloud.com/tts-endpoints.json` → `{ "cn_url": "...", "us_url": "..." }`
- **路由规则**：设备时区属中国大陆（`Asia/Shanghai|Urumqi|Chongqing|Harbin|Kashgar`）→ 主用 **CN**、失败回退 **US**；否则主用 **US**、无回退。

**请求**：
```
POST {base}/api/captioned_speech_partly
Content-Type: application/json

{
  "model": "kokoro",
  "input": "要合成的文本（单次上限 5000 字，超出截断；剩余靠流式续）",
  "voice": "af_heart",        // 音色 id
  "response_format": "mp3",
  "return_timestamps": true,
  "speed": 1.0,               // 生成用 1.0；变速在播放端做（不要改生成 speed）
  "stream": true,
  "language": "en"            // zh / en / ...
}
```

**响应**（一段，"partly"流式：靠 `unprocessed_text` 续请求）：
```json
{
  "audio": "<base64 mp3>",
  "audio_format": "mp3",
  "duration": 3.21,                         // 秒；中文常为 0/缺失 → 用最后一个时间戳兜底
  "processed_text": "本段实际合成的文本",      // 渲染高亮用这个，别用原文
  "unprocessed_text": "本次没处理完、留给下次的文本",  // 非空 → 用它再发一次，直到为空
  "timestamps": [                            // 词级时间戳；中文通常为空数组
    { "word": "Hello", "start_time": 0.0, "end_time": 0.32 }
  ]
}
```

**流式续传逻辑**：`unprocessed_text` 非空 → 以它为 `input` 再发一次，`segmentIndex++`，直到 `unprocessed_text` 为空。每次返回是一个 AudioSegment。

### 9.2 解读 QuickRead（三段式）

**Base**：`https://quickread.castreader.ai:8444`
**鉴权头（所有 QuickRead 请求必带）**：
```
x-api-key: <QUICKREAD_API_KEY>      // 缺失 → 401
x-device-id: <设备唯一 id>           // 复用 visitor id；登录后可附 user
Content-Type: application/json
```

#### (1) extract-plan —— SSE 流式

```
POST /api/quickread/extract-plan
Accept: text/event-stream

请求体:
{
  "source_url": "原始网址 / castreader://doc/<id>",
  "title": "标题",
  "lang": "zh" | null,         // null = 跟随原文
  "depth": "overview" | "standard" | "deep",
  "text": "全文（= fullText）",
  "fullText": "全文",
  "paragraphs": [ { "text": "...", "type": "paragraph|heading|blockquote|code|list|caption" } ]
}
```

**SSE 事件**（事件名在 `event:` 行，数据在 `data:` 行的 JSON）：
```
event: stage
data: {"stage":"extract"}            // 阶段提示（extract=通读全文 / compose=组织讲解）

event: block0
data: {                              // 开头块尽快返回，先出声
  "job_id":"...",
  "output_language":"zh",
  "total_blocks": 0,                 // ⚠ 此处常为 0 占位，真实总数在 done 事件
  "block_0": { "id":"...","text":"讲解文本","cinematic":{"events":[ <mark>... ]} }
}

event: done
data: {"job_id":"...","total_blocks":6,"model_used":"..."}   // ⚠ 用这里的 total_blocks
```

> ❗ **SSE 解析坑**：很多 HTTP 客户端的"按行读"会**吞掉 SSE 事件之间的空行**，不能靠空行判定事件边界。正确做法：**遇到下一个 `event:` 行或空行就 flush 上一个事件**。否则 `block0` 会被后续 `done` 覆盖、报 `noBlock0`。
> ❗ **total_blocks 坑**：`block0` 事件里 `total_blocks` 常是 0 占位；**以 `done` 事件的 `total_blocks` 为准**，否则只播一块就误判完成。

#### (2) extract-block —— 拉第 N 块讲解（JSON）

```
POST /api/quickread/extract-block
{ "job_id": "...", "block_idx": 2 }

响应:
{ "section": { "id":"...","text":"第2块讲解文本","cinematic":{"events":[ <mark>... ]} } }
```

#### (3) compose-block —— 用 TTS 时间线回填 mark.at（JSON）

```
POST /api/quickread/compose-block
{
  "job_id": "...",
  "block_idx": 2,
  "timestamps": [ { "word":"讲","start":0.0,"end":0.2 }, ... ],  // 客户端对讲解文本 TTS 后的词级时间线
  "duration": 12.3                                               // 该块讲解音频总时长（秒）
}

响应:
{ "section": { ..., "cinematic": { "events": [ { "at":3.4, "action":"circle", "text":"锚文本", ... } ] } } }
```

#### mark（QuickreadEvent）结构

```
{
  "at": 3.4,                 // 触发时刻（秒）；compose 回填；缺失时客户端均匀铺开兜底
  "action": "highlight" | "underline" | "circle" | "number" | ...,
  "text": "锚定原文片段（可能带【】或被改写）",   // 用 fuzzyFind 定位（见 5.4c）
  "n": 1,                    // 序号（number action）
  "role": "key" | "caution" | "term" | "example",   // 可选
  "note": "旁注"             // 可选
}
```

### 9.3 额度 / Pro（readout-web 公开端点）

- `GET https://castreader.ai/api/pro/status?device_id=&user_id=&email=&local_date=` → 回 Pro 状态 + 当日额度。登录后必须尽量传 `device_id + user_id + email`，服务端统一归一化 provider id 与后端 user id。
- `POST https://castreader.ai/api/pro/listen-track` `{device_id|user_id, seconds}` → 上报朗读秒数。
- 免费额度（参考 iOS）：每日 20 分钟朗读 / 3 次解读 / 仅基础音色 / 速度 ≤2.0x；本地午夜重置；服务端值优先、出错 fail-open 本地计数。
- **解读 402** = 该 device 免费额度用满 → 弹**付费墙**（不是报错）。

---

## 十、关键踩坑清单（Android 必读）

| # | 现象 | 根因 | 解法 |
|---|---|---|---|
| 1 | 流式时"播完一段就误判整篇结束" | 队列空时无法区分"真结束"还是"在等下一段" | `moreSegmentsExpected` 标志（4.3b） |
| 2 | 高亮找不到 / 不同步 | 把 TTS 时间戳映射回了原文（原文与 processed_text 有差异） | 直接渲染 processed_text，在其中定位（4.3c） |
| 3 | TTS 在每个换行处停顿断句 | 把排版换行当句子边界 | 切句只按句末标点；喂 TTS 删硬换行（4.3d） |
| 4 | 中文没有逐词高亮 | 云端 TTS 对中文不返回词级时间戳 | 中文走句子级高亮（4.3c） |
| 5 | SSE 的 block0 被 done 覆盖、报 noBlock0 | 按行读吞掉事件间空行 | 遇 `event:`/空行就 flush 上个事件（8.2-1） |
| 6 | 只播一块就"完成" | 用了 block0 里占位的 total_blocks=0 | 用 done 事件的 total_blocks（8.2-1） |
| 7 | 解读报 "TTS request was cancelled" | 批间预取的 TTS 和当前播放 TTS 抢单请求 | 批间预取只 plan、不预生成 TTS（5.5-坑3） |
| 8 | PDF 解读"每页重新开始、没衔接" | 逐页独立 plan + 后端无续接上下文 | 逐批（一批≈一篇文章）（5.5-决策1） |
| 9 | PDF 解读"一页才一个 mark" | 批太大、后端切块变粗标注摊薄 | 批≈3000 字对齐网页体量（5.5-决策2） |
| 10 | mark 锚不准 / 锚到屏幕外 | 锚文本带【】被改写 / near 指向前面批 | 归一化剔标点 fuzzyFind + near 设当前批首段（5.4c） |
| 11 | 字幕一条就是一大段 | 只按句末标点切、长句没二次切 | 长句按逗号/分号/顿号切到 ≤24 字（5.4d） |
| 12 | PDF 高亮位置偏移几个字 | PDF 文本"字符串下标"≠"位置下标"（CJK 尤甚） | 用 PDF 引擎的 findString（文本↔位置内部映射），别用纯字符下标 |
| 13 | 收起阅读界面播放就断了 | 阅读界面持有 VM、关闭即销毁 | 会话提升到全局 coordinator、收起≠停止（七节） |
| 14 | 解读/朗读切换出现双重高亮 | 两条线共用一个播放器、回调归属不清 | 播放完成回调单一所有权；切线 deactivate 旧 VM、activate 新 VM |

---

## 十一、上线前配置清单

- **QuickRead `x-api-key`**：解读后端鉴权，缺失全部解读 401。
- **TTS 节点**：远程配置 `tts-endpoints.json` 的 cn_url/us_url；CN 实例会轮换。
- **音色列表**：基础音色 vs Pro 音色。
- **额度参数**：每日朗读分钟数 / 解读次数 / 速度上限（与 iOS 对齐：20min / 3次 / 2.0x）。
- **付费**：Android 用 Google Play Billing（iOS 是 StoreKit）；Web 已付费者经服务端 `serverPro` 同步。
- **剪贴板权限提示**：遵循平台克制读取原则。

---

> 附：iOS 端关键实现文件（供对照）——朗读编排 `ReadAloudViewModel`、解读编排 `ExplainViewModel`、mark 锚定 `MarkAnchoring`、统一文档模型 `ReadingDocument`、全局播放 `PlayerCoordinator`、迷你播放器 `MiniPlayerView`、TTS 路由 `TTSEndpoint`、解读模型 `Quickread`。
