# 需求规范：朗读高亮 与 解读 mark 颜色统一跟随「设置高亮色」

> 状态：**iOS 已实现**（commit `10edd4c「mark 颜色统一深浅适配」`）。本文档为**跨端对齐规范**，供 Android / Chrome 扩展(readout-desktop) / readout-web 跟进。
> 最后更新：2026-06-25

## 1. 需求一句话

App 里有**唯一一个**用户可调的「高亮颜色」设置。**朗读（Read Aloud）的词/句高亮**与**解读（Explain）的手写 mark 标注**，二者颜色**都从这一个设置取值**。用户在设置里改了高亮色，朗读高亮和 mark 的颜色**同时**跟着变。

- mark 颜色**不再按 action 类型分色**（不是"高亮黄、圈红、下划线蓝"）。
- 所有 mark（highlight / underline / circle / number / strike / star / …）用**同一个基色**，只靠**透明度 + 笔触样式**区分视觉层次。
- 朗读高亮与 mark **同基色**，保证视觉一致（"这套笔记是同一支笔画的"）。

## 2. 单一事实源（Single Source of Truth）

| 项 | 值 |
|---|---|
| 字段 | `highlightColorHex`（hex 字符串，如 `"#FD5F01"`） |
| 默认值 | `#FD5F01`（橙） |
| 持久化 key | iOS `UserDefaults: "highlight_color_hex"`（各端用各自等价存储） |
| 调色板（设置页 6 选 1） | `#FD5F01`(橙) · `#FFD400`(黄) · `#34C759`(绿) · `#0A84FF`(蓝) · `#FF2D55`(红) · `#AF52DE`(紫) |

> iOS 参考：`Models/AppSettings.swift:26`、`Views/Settings/SettingsView.swift:23,204`。

**关键约束**：朗读高亮和 mark **都只读这一个字段**，不得各自维护独立颜色常量。

## 3. 渲染规范：基色 + 分元素透明度

所有元素 = **基色（同一 hex）+ 该元素的透明度/笔宽**。颜色（色相）恒为 `highlightColorHex`，**只有透明度与笔触随元素类型变**。

### 3.1 朗读高亮（半透明背景/荧光，让文字透出）

| 渲染源 | 透明度 | 备注 |
|---|---|---|
| 原生文本 / EPUB | 基色 α **0.40** | 词高亮背景，4px 圆角（`ReadAloudViewModel.highlightUIColor`） |
| 拍摄（photo OCR） | 基色 α **0.38** | 盖在 OCR 词 bbox 上 |
| PDF（词级 / 句级） | 词 α **0.33** / 句 α **0.50** | |
| Web（WKWebView/扩展 DOM） | 基色 α **0.34**，`mix-blend-mode: multiply` | `hexToRgba(color, 0.34)` |

### 3.2 解读 mark（手写体标注）

**所有 mark 用同一基色**，按 action 分透明度与笔触（**非分色**）：

| action | 透明度 | 笔宽 | 形状 |
|---|---|---|---|
| `highlight`（荧光笔） | **0.28–0.35** | ≈ 行高 × 0.85（粗） | 沿文字中下部一条粗半透明线，**不用 multiply**（深色背景 × 橙会变黑、荧光消失；仅 PDF 平台特例用 multiply α 0.28） |
| `underline`（下划线） | **0.85–0.95** | ≈ 2.2–2.5 | 文字底部手绘线 |
| `circle`（圈） | **0.85–0.95** | ≈ 2.4–2.5 | 包住整段并集 bbox 的手绘椭圆 |
| `number`（序号圈） | 圈同 circle；数字徽标用**基色不透明** | 2.4 | 圈 + 角标数字 |
| `strike` / `star` / `question` / `exclaim`（web 已有） | **0.95** | 2.5 | 删除线 / 星 / 问号 / 叹号，均同基色 |

> 透明度区间给出范围是因为各端历史值略有差异（native 荧光 0.35、PDF 0.28；native 墨笔 0.85、web 0.95）。**跨端对齐时取**：荧光 `0.30`、墨笔类 `0.90` 作为统一目标值，允许 ±0.05 平台微调。

> iOS 参考：`Views/Reader/MarkOverlay.swift:50-68`（native）、`Views/Reader/PDFReaderView.swift:109-140,319-338`（PDF）、`WebReader/src/mark-renderer.ts:120-156`（web）。

## 4. 数据流（颜色如何到达每个 mark）

mark 的数据结构**不带颜色字段**（`ResolvedMark{id, paragraphIndex, charRange, action, n, seed}`）。颜色在**渲染时**统一注入：

- **原生**：渲染 mark 时直接读 `highlightColorHex` 转 UIColor 传入（`MarkInkView(inkColor:highlightColor:)`）。
- **Web/扩展**：`CR.init({color: highlightColorHex})` 时 `markRenderer.setColor(color)`；之后 `showMark` payload **不带颜色**，渲染器用已设的 `color`。设置变更可调 `CR.setColor({hex})` 热更新。

**给别的端的实现要点**：mark 渲染层持有一个"当前颜色"，由 init/setColor 注入；mark 指令本身不携带颜色。**不要**在协议里给每个 mark 塞颜色——颜色是全局态。

## 5. 跨端跟进清单（别的端照此对齐）

- [ ] 移除 mark 渲染里**按 action 类型写死的颜色**（如圈用红、高亮用黄），改为统一读「设置高亮色」。
- [ ] 朗读高亮与 mark **复用同一个颜色字段**，不得各持一份常量。
- [ ] 按 §3 的透明度/笔宽表区分元素层次（**只调 α 和笔触，不调色相**）。
- [ ] 设置页调色板与 §2 的 6 色一致；改色后朗读高亮 + mark 同时生效。
- [ ] 渲染协议：颜色走全局态（init/setColor 注入），mark 指令不带颜色。

## 6. iOS 现状结论

iOS 全部渲染层（原生文本 / EPUB / 拍摄 / PDF / Web JS）**已全部跟随 `highlightColorHex`**，朗读高亮与 mark 同基色，改设置即同时变化。**iOS 端无需新增改动**，本规范用于让其余端对齐到与 iOS 一致的行为。
