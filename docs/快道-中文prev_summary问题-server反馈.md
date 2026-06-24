# 解读快道（Fast-Lane）—— 中文衔接：排查与解决记录

> ✅ **已解决**。文档 `quickread-fast-lane.md` §0.5 明确责任划分:
> - **覆盖层（不漏/不重）= 客户端** split-at-N（只喂 rest + idxBase 顺延）——iOS 已正确实现（下方 code review 验证）。
> - **连贯层（不复述/不跳）= 后端**质道承接 prompt（**已改目标驱动 + 部署上线**，中英文各 2 篇验证「接 rest[0] 顺序讲、不复述、不跳」）。
>
> iOS 按 §0.5 回归纯实现:**① split-at-N + ② 传 `prev_summary` = 快道 narration**，并**删掉**之前基于旧 server 行为加的客户端 mark 过滤 workaround（连贯不该客户端兜）。本文档保留 code review 验证（证明客户端实现正确）+ 历史排查（旧 server 的「复述↔跳」两难，现已由后端修复）。

---

## 一、iOS 客户端实现验证（两个 code review 关键点，均已确认正确）

### Q1：传给质道 extract-plan 的 paragraphs = rest（不是整篇）✓

```swift
setupQuoteScope(rest):  pdfScopedParagraphs = rest.重索引为0-based   // 只存 rest
buildPlanRequest():     paras = pdfScopedParagraphs ?? doc.paragraphs // 快道激活时 = rest
```
- **log 佐证**：整篇 98 段（opening 2 + rest 96），质道请求 `batchParas=96` = rest，不是 98。

### Q2：质道块 emit index `+idxBase` 顺延，不丢质道 block_0 ✓

```swift
handlePlan:   totalBlocks = idxBase + plan.total_blocks   // 快道占 idxBase + 质道总数
prepareBlock: qIdx = idx - idxBase                        // iOS index → 质道内部 index
              extractBlock(blockIdx: qIdx)                // 拉块用质道内部 qIdx
```
- 快道占 iOS block_0；质道 block_0（plan section0）= iOS block_1（**没丢**）；质道 block_i → iOS block_(i+1)。
- 两个索引空间没混：extract-block / compose 用质道内部 `qIdx`，只有 emit 给渲染器的 index `+idxBase`。
- **log 佐证**：`idxBase=1`，质道首块作为 iOS block_1 播出。

> 结论：分割（split-at-N、只传 rest）、拼接（idxBase 顺延、block_0 不丢、两索引空间分离）完全对齐文档 §4.7/§4.8。

---

## 二、问题：中文长文上 `prev_summary` 的「复述 ↔ 跳」两难

测试页：一篇中文长文（Sand.ai 创始人曹越访谈，98 段 6785 字）。开头 para 0~5 都在讲「Sand.ai / 曹越 / 融资 / 非共识」（引子 + 展开，**主题横跨切分点 para 2**）。

快道 opening = para 0,1（Sand.ai 获融资 + 「每一代模型押注非共识」）。质道吃 rest = para 2~97。

### 情况 A：质道**带** `prev_summary = 快道 narration`（文档 §4.7 要求）

→ 质道 block_0 的 mark 跨整篇乱跳：

```
质道 block_1 mark: para 6 → 26 → 28 → 9 → 10 → 15 → 29 → 33 → 35 → 37 → 40 → 41
```

质道把 `prev_summary` 理解成「**开头这些都讲过了，跳过**」，直接跳到 para 26（视频技术细节），**跳过 para 2~25**（曹越/非共识/融资细节）。= 漏讲一大段。

### 情况 B：质道**不带** `prev_summary`

→ 质道老实从 rest 开头顺序讲（mark para 6→7→8→9 递增 ✓），但**第一块重新引入背景**：

```
质道 block_1 mark: para 6 [自回归] ... 同时 narration 念 "Sand.ai 是一家…超亿美元融资…"
                   → 这句 mark 锚回 para 0（快道讲过的）
```

质道把重索引的 rest 当成「一篇从 0 开始的新文章」，开头先交代背景「Sand.ai 是…刚融资…」——而这正是**快道刚讲过的**。= 听觉上和快道重复。

（iOS 已加 mark 过滤：质道锚回 opening 范围的 mark 丢弃，所以**画面**不跳回开头；但 **narration 念的内容**客户端挡不住。）

---

## 三、根因 + 解决（已修复）

**根因**：旧版质道 prompt 把中文 `prev_summary` 处理成「这些内容跳过」，而非「背景已交代，**从 rest 第一段顺序接讲、不复述、不跳**」。中文文章主题连续，旧 prompt 就暴露「复述（不传 prev_summary）↔ 跳（传 prev_summary）」两难。

**解决**：后端质道承接 prompt 已改为**目标驱动**并部署上线，中英文各 2 篇验证「接 rest[0] 顺序讲、不复述背景、不跳」。iOS 按文档 §0.5 只需**传 `prev_summary` = 快道 narration**，连贯由 server 兜，客户端不写「别复述/别跳」逻辑。

---

## 四、iOS 现状（已对齐文档 §0.5）

- 快道 v1 客户端：门控 / split-at-N（只喂 rest + idxBase 顺延）/ 竞速 / 语言锁定 / marks 均匀 at / **传 prev_summary** —— 全部按文档实现。
- 已**删除**之前基于旧 server 加的客户端 mark 过滤 workaround（`fastOpeningCount`）——连贯交给 server 质道 prompt。
- 关键代码（`ExplainViewModel`）：`setupQuoteScope(rest:)` + `buildPlanRequest{ prev_summary: fastSection?.text }` + `prepareBlock{ qIdx = idx - idxBase }`。
