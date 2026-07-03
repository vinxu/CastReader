# 六场景解读适配 —— Android 落地指引

> iOS 已实现并验证、后端已实现并评测（详见 `场景解读适配规范.md`、`readout-desktop/.../场景化解读-效果评估验收.md`）。本文给 Android 做同样的适配，让 6 个场景的解读在安卓上达到与 iOS 一致的差异化体验。
> 阅读顺序：先读 `场景解读适配规范.md`（正交模型 + 工具语义），本文是它的 Android 落地版。
> 版本：2026-06-28。

---

## 0. 一句话目标

让安卓的解读按用户选的**场景**（6 选 1）调整「划什么 / 怎么批 / 语气」，同时**深度（3 档）始终由用户设置决定**。差异化逻辑在后端 prompt（已实现）；客户端只负责：**① 把 `content_type` 传到位、② 别让场景动 depth、③ 渲染后端发来的分层标注（weight/role + 新 mark 类型）**。

> Android 在 P0 已接入 `content_type` 全链路 + 6 场景首页 + 导航。本文重点是 **P0 之后的对齐项**：深度解耦（修正）+ P1 分层渲染（新增）+ 发送契约校验。第 1、4 节是必改，第 2、3 节是核对。

---

## 1. 正交模型铁律（必须遵守）

**`content_type`（6 场景）与 `depth`（3 档）是两条独立的轴：**

| 轴 | 控制什么 | 取值 | 来源 |
|---|---|---|---|
| `content_type` | 划什么 / 批注侧重 / 语气 / 用哪种标注 | `paper` `book` `report` `contract` `study` `manual`（或 null=通用） | 场景入口 → `DocSession.scenario` |
| `depth` | 详略 / 长度 / mark 密度 | `overview` `standard` `deep` | 用户设置（设置页「讲解深度」） |

**铁律：场景绝不改 depth。** depth 永远等于用户设置的 3 档。

> ⚠️ **P0 修正点（最重要）**：早期 PRD 曾让场景「预设 depth 并覆盖用户设置」（论文/合同→deep，其余→standard）。**该设计已废除**。iOS 删除了 `ExplainContentType.suggestedDepth` 与 `effectiveDepth` 覆盖逻辑。**Android 若在 P0 写了「场景覆盖深度」，必须删掉**，改成永远发用户设置的 depth。

---

## 2. content_type 全链路发送（P0 已做，核对）

### 2.1 场景枚举（Kotlin）

与 iOS `ExplainContentType` 一一对应，`rawValue` = 后端约定 id（**snake_case 不变**）：

```kotlin
enum class ExplainContentType(val id: String) {
    PAPER("paper"), BOOK("book"), REPORT("report"),
    CONTRACT("contract"), STUDY("study"), MANUAL("manual");

    // 首页入口展示用（中英文案走 strings.xml / i18n）
    val displayNameRes: Int get() = when (this) { /* 论文 / 学术、书籍 / 长篇 … */ }
    val subtitleRes: Int get() = when (this) { /* 研究问题·方法·结论·贡献 … */ }
    // ⚠️ 不要有 suggestedDepth —— 场景不决定深度
    companion object { fun fromId(id: String?) = entries.firstOrNull { it.id == id } }
}
```

6 场景的「划什么 / 批注侧重」文案对照（与 iOS 一致，来自 PRD §1）：

| id | 入口名 | 划什么（副标题） |
|---|---|---|
| `paper` | 论文 / 学术 | 研究问题 · 方法 · 结论 · 贡献 |
| `book` | 书籍 / 长篇 | 核心观点 · 金句 · 概念 · 转折 |
| `report` | 报告 / 研报 | 核心结论 · 关键数据 · 风险 |
| `contract` | 合同 / 条款 | 权利义务 · 金额期限 · 风险条款 |
| `study` | 教材 / 学习 | 知识点 · 定义 · 易考点 |
| `manual` | 说明书 / 文档 | 关键步骤 · 警告 · 参数 |

### 2.2 请求体加 content_type

`QuickReadApi.kt` 的 **extract-plan** 与 **fast-block0** 请求体加字段（snake_case）：

```kotlin
data class ExtractPlanRequest(
    val source_url: String, val title: String, val lang: String?,
    val depth: String,                 // = 用户设置的 3 档（见 §3）
    val text: String, val fullText: String,
    val paragraphs: List<QrParagraph>,
    val prev_summary: String? = null,
    val content_type: String? = null,  // ← 6 场景 id 或 null；通用导入/扩展端为 null
)

data class FastBlock0Request(
    val title: String, val openingParas: List<QrOpeningPara>,
    val lang: String?, val depth: String,
    val prev_summary: String? = null,
    val content_type: String? = null,  // ← 同上
)
```

> **向后兼容**：`content_type` 为 null 时后端走通用解读、零回归（后端已对此加白名单：非 6 值即降级通用）。Android 只管「有场景填 id、没场景填 null」。

---

## 3. depth 解耦（必改）—— 永远发用户设置

ViewModel 构造请求时，`depth` **直接取用户全局设置**，与 scenario 无关：

```kotlin
// 任何 reader VM 的 startExplain / 构造 ExtractPlanRequest 处
val depth = settings.explainDepth          // "overview" | "standard" | "deep"，用户在设置页选
val req = ExtractPlanRequest(
    ...,
    depth = depth,                         // ← 永远用户设置，场景不改它
    content_type = docSession.scenario,    // ← 场景 id 或 null
)
```

**自检**：设「讲解深度=速览」，从「论文」场景进入 → 抓包请求体应是 `"depth":"overview","content_type":"paper"`（旧逻辑会错成 `deep`）。改深度为「深入」重进 → `"depth":"deep"`。depth 永远跟随设置。

---

## 4. 场景入口 + 落地即解读（P0 已做，核对 auto-explain）

- **`DocSession.scenario: String?`**：用户从某场景入口导入内容 → 写入该场景 id；通用 ➕ 导入 → null；换文档/清理会话时复位。
- 拍照来源（OCR 路径）的会话同样要能携带 scenario。
- **从场景入口进入 → 落地后自动进解读模式**（auto-explain）。iOS 各 reader 渲染完成后若是场景进入则自动 `startExplain`。
  - **Android 注意**（来自 PRD §2.3）：`autoExplain` 此前只有 WebReader 处理；**PDF / EPUB / Photo reader 需补齐「渲染完成后若 autoExplain 则自动 startExplain」**。
  - web/DOCX 源段落是 WebView 异步提取的，auto-explain 必须在「段落已提取」之后触发（否则空内容请求）。

---

## 5. P1 分层标注渲染（新增，必做）—— 渲染后端发来的 weight/role/新 mark

后端按场景会发出**分层信息**，客户端要能渲染出层次，否则场景化「划得准·分层」在安卓上看不出来。

### 5.1 数据模型加字段

`QuickreadEvent`（mark）加 `weight` / `role`（透传，可空，零回归）：

```kotlin
data class QuickreadEvent(
    val at: Double?,
    val action: String,      // highlight | underline | circle | number | wave | strike | star
    val text: String?,
    val n: Int? = null,
    val role: String? = null,    // key | caution | term | example —— 语义角色（透传）
    val weight: String? = null,  // primary | secondary | tertiary —— 重要度分层 → 笔触粗细
    val note: String? = null,
)
```

### 5.2 weight → 笔触粗细倍率（与 iOS 完全一致）

```kotlin
// 对齐 iOS HandwrittenMark.weightMultiplier —— 倍率必须一致，跨端视觉统一
fun weightMultiplier(weight: String?): Float = when (weight) {
    "primary", "high" -> 1.6f
    "tertiary", "low" -> 0.65f
    else -> 1.0f                 // secondary / null → 普通（缺省零回归）
}
// 各 mark 的描边宽度 = 基础宽度 × weightMultiplier(weight)
```

### 5.3 新增 mark 类型（与 iOS 对齐）

iOS 在标注语言里新增了 3 种手绘形态，Android 需支持（缺省回退到下划线即可，不崩）：

| action | 语义 | 画法 |
|---|---|---|
| `wave` | 风险 · 警示 | 文字底部正弦波浪线 |
| `strike` | 删除/否定 | 文字中线横线 |
| `star` | 亮点 · 金句 | 文字右侧手绘五角星 |

（原有 `highlight`/`underline`/`circle`/`number` 不变。）

> **诚实说明**：后端 prompt 当前主要发 `highlight/underline/circle/number`；`wave/star/strike` 是为「标注语言丰富」预留的客户端能力，后端按场景逐步放开后即生效。Android 现在就把渲染能力补齐，到时零改动直接出效果。

### 5.4 颜色统一（别按场景/role 改色相）

mark 颜色**统一跟随设置里的高亮色**（`highlightColorHex`），不按场景或 role 改色相——只用透明度/笔触/形状区分层次。详见 `高亮与mark颜色统一规范.md`。role 仅作语义透传（可选轻微着重），默认不改色。

---

## 6. 后端契约（已实现，Android 无需改后端）

- 后端 `extract-plan` / `fast-block0` 已读 `content_type`（6 值白名单），按场景注入「目标 + 工具箱」透镜（`scenarioLens`），让 LLM 自主决定划哪/用什么笔/怎么批；`depth` 仅调详略。
- **未知 / 缺省 content_type → 后端降级通用解读、绝不报错**。
- 字段名 `content_type`（snake_case）。
- 部署状态：后端改动尚未上线 `quickread.castreader.ai:8444`；上线后 Android 发 content_type 即生效（上线前 Android 发了也只是被忽略=通用，零风险）。

---

## 7. 验收清单（Android 自检，与 iOS 对齐）

- [ ] **删除任何「场景覆盖 depth」逻辑**；抓包确认 depth 永远等于用户设置（速览/标准/深入），与场景无关。
- [ ] extract-plan 与 fast-block0 请求体都带 `content_type`：场景进入填对应 id，➕ 通用导入填 null。
- [ ] 6 场景入口文案（划什么）与 §2.1 表一致；中英 i18n 补齐。
- [ ] 场景进入 → 落地**自动进解读**；PDF/EPUB/Photo reader 的 auto-explain 已补齐；web 源在段落提取后才触发。
- [ ] `QuickreadEvent` 解析 `weight`/`role`（缺省可空、不崩）。
- [ ] mark 渲染按 `weight` 调笔触粗细（倍率 primary 1.6 / 普通 1.0 / tertiary 0.65，与 iOS 一致）。
- [ ] 渲染支持 `wave`/`strike`/`star`（未知 action 回退下划线）。
- [ ] mark 颜色统一跟随 `highlightColorHex`，不按场景/role 改色相。
- [ ] **后端上线后**：同一篇分别以 `paper` vs `contract` 进入，划重点/批注侧重明显不同；改 depth 只改详略、不改划什么。

---

## 8. 效果基准（后端已评测，Android 对齐后应一致）

后端 6 场景 × 3 真材料 × 3 重复 A/B 评测（详见验收报告）：场景版相对通用基线，goal-fit / genre-emphasis 两轴均 ≥ 4.84/5 且 Δ ≥ 0，盲评约 80% 判场景版更贴。**最直观差异**：教材版主动点「易考点 / 记忆锚」，合同版站在签约人一边点破「对你不利的陷阱条款」并整句圈出。Android 渲染对齐后，相同 content_type 下应呈现同等差异（解读文本由后端生成，跨端一致；客户端只负责把分层标注画对）。
