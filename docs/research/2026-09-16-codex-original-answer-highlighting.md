# CastReader：Codex 原回答同步高亮可行性

日期：2026-09-16。性质：技术核查，尚未完成 Codex 真实回答上的播放与高亮验收。

## 已确认的用户要求

- 用户安装 CastReader 后，使用 CastReader 账号及会员权益朗读、解读 Codex 回答。
- 首版由用户手动要求“朗读刚才的回答”触发。
- 高亮必须位于 Codex 原回答；用户明确不接受将回答复制到独立阅读面板来代替。
- 会员属于用户账号。现有开发者 Voice API 钱包、应用 Pro 权益以及前端绘制权限是三个独立问题，不能因为会员有效便假定主界面注入可用。

## 结论与证据范围

| 环境 | 原回答高亮路径 | 当前判断 |
| --- | --- | --- |
| 浏览器中的对话页面 | CastReader 浏览器扩展读取可见回答 DOM，以 Range + CSS Custom Highlight API 绘制 | 技术路径成立，已有可复用代码；本次未在登录后的 Codex 回答上验收 |
| Codex 桌面 App，仅安装普通 Codex 插件 | 技能/MCP 返回音频或组件 | 所核查的公开接口没有提供主回答 DOM 操作能力，不能承诺仅安装即可原位高亮 |
| Codex 桌面 App，加 CastReader 桌面组件 | 辅助功能文本/字符范围定位 + 透明、点击穿透的原位高亮窗口 | 本地仓库已有相关基础实现；Codex 的字符坐标、滚动跟随尚待专项实测 |
| Codex 桌面 App，调试注入 | 在允许调试且获得对应 renderer 访问能力时执行 DOM/CSS 脚本 | 渲染机制上存在可能，未执行注入；不能作为已支持的商店插件能力 |

## 网页端

Chrome 官方文档明确允许扩展 content script 读取及修改获准页面 DOM。CSS Custom Highlight API 能在不改变 DOM 结构的情况下高亮文本范围。因此优先复用 Range 高亮，而不是覆写 React 管理的 innerHTML 或反复包裹文本节点。

已读取本地 `readout-desktop` 仓库：

- `src/extractors/chatgpt.ts`：按 assistant 消息及 Markdown 容器提取内容，保留原 DOM 元素引用。
- `src/ui/llm-button-injector.ts:64`：已有 ChatGPT 回答选择器、按钮锚点及输出完成探针。
- `src/highlight/highlight-sync.ts:1336` 起：词级高亮使用音频时间戳、原文字段映射、DOM Range 与 `CSS.highlights`；已有 DOM 变化时清理缓存的处理。

这些证明代码基础存在，不证明当前 Codex 网页选择器已经适配。仓库文档提及 Codex，但本次读取的配置只明确确认 ChatGPT 入口，不据此宣称 Codex 专项测试通过。

待验收：真实回答容器定位；流式完成判定；中英及代码/列表/表格文本偏移；播放、暂停、变速、跳转；重渲染、长回答虚拟化、切换任务和自动滚动；停止后清理高亮。朗读需将真实音频时间戳映射回可见原文；解读音频是另一份讲解文本，须另建“讲解时间点 → 原回答片段”锚点，不能按字数匀速模拟词级同步。

浏览器扩展和 Codex 插件是不同安装载体。即使同品牌提供引导，也不能假定安装 Codex 插件会自动获得浏览器页面访问权限。

## 桌面端

只读检查本机安装包 `/Applications/ChatGPT.app/Contents/Resources/app.asar`：

- Bundle ID 为 `com.openai.codex`，版本 `26.908.70816`。
- 内部 package name 为 `openai-codex-electron`。
- 存在 `webview/index.html`、conversation Markdown 渲染资源及 preload 文件。

所以该版本确实具有 HTML/DOM 渲染层。未在检查的 preload 及公开插件文档中发现给第三方插件高亮主回答的接口。这只是所核查范围内的结论，不能反推所有内部能力不存在。

Electron 的 `webContents.executeJavaScript` 和扩展加载机制属于宿主应用能力，不会自动赋予 CastReader Codex 插件。OpenAI 的自定义插件 UI 文档描述的是隔离 iframe 及消息桥，并非对父级聊天 DOM 的自由访问。

桌面伴随组件的可复用基础：`readout-desktop/castreader-desktop/Sources/CastReaderDesktop/Overlay/HighlightOverlay.swift` 已实现透明、点击穿透窗口、文本矩形及窗口/滚动跟随；相关 Accessibility 模块存在字符范围定位。可按此路线验证“用户仍看着 Codex 原回答，高亮落在原文字上”，但它是外部绘制，不是修改 Codex 原回答 HTML。需验证 Codex 暴露的辅助功能精度；截图/OCR 只能作为经授权、能准确定位时的补充，无法定位时应停止原位高亮而非伪造同步。

本轮不修改 Codex 安装包、不启用调试端口、不削弱应用隔离；未生成付费音频。

## 实测限制

- Brave 访问 `https://chatgpt.com/codex` 后显示产品介绍及登录入口，没有进入可检查的真实回答页面。
- Computer Use 在选择 `com.openai.codex` 时明确返回禁止操作该 App。未改用其他方式绕过此限制，也未完成桌面端动态注入/字符定位验证。

## 桌面端专项复核与最新范围

用户后续明确要求：先探索 **Codex 桌面 App 直接操作原回答 DOM** 的路径，不做网页版替代验证；核心验收是 TTS + 原回答同步高亮指读。下面原先的网页优先建议已被该要求取代。

本轮完成的是只读结构检查，不是桌面动态播放测试：

- 主窗口创建配置明确出现 `contextIsolation: true`、`nodeIntegration: false`，并加载应用自己的 preload。
- 已检查的 preload bridge 提供宿主消息、拖放、主题等接口，未发现面向第三方技能的主回答 Range/高亮接口。桥对象本身属于宿主页面，不能假定技能/MCP 组件可直接调用。
- 存在 `browserExtensions` 功能及 session extension 工具栏管理代码；找到的直接 `loadExtension` 调用用于 React DevTools。以上不足以证明普通 CastReader 插件能向聊天主 renderer 注入 content script。
- MCP 组件采用隔离页面及消息桥，不能据此推定具有父聊天页面的 DOM 权限。
- 未修改安装包、启动调试端口、关闭隔离或进行 UI 注入。此前 Computer Use 拒绝操作 Codex 自身的边界继续保留。

复核版本 `26.908.70816`，bundle 内主 JS SHA-256：`0765260be74e8843630d5a92e30bca574783892688e67180c119a5c58679bb61`；preload SHA-256：`9dba229e0b3cfa1cc9a7e78925b5f168b7f7385e1c18d785d13ce8e823e65207`。

当前判断：**主界面在技术上具有 DOM，但没有核实到可由市场插件使用的宿主注入入口。动态测试仍未完成，不能宣称不可能，也不能宣称已打通。** 后续只有获得受支持的主 renderer 接口或获准的宿主集成测试环境，才能进入真实 TTS + Range 高亮验收。仅增加 skill 文案、MCP 工具或会员登录不解决此缺口。

未发布的 `read-answer` 技能已增加“先验证桌面 DOM 适配器，再生成音频”的能力门槛；没有适配器时不产生指读任务的费用。这是工作流约束更新，不是 TTS + 高亮功能已经实现，也不作为新版本提交依据。

## 原产品推进建议（已被桌面优先要求取代）

1. 优先在登录后的真实网页回答上复用浏览器扩展完成原位高亮验收，再接统一会员权益。
2. 桌面路线单独做原位覆盖层可行性验证，重点验证字符范围与滚动；通过后才定义“Codex 插件 + CastReader 桌面组件”的交付方式。
3. 若要求严格限定为“仅安装市场插件，且直接修改桌面主回答 DOM”，当前没有核实的可交付路径；保留待宿主接口支持状态。
4. 开发者版 0.1.2 的已发布状态不等于上述会员听读功能已上线。未发布的 read-answer 技能亦不能宣传成已实现原回答高亮。

## 后续独立桌面同步实验

同日已建立 `/Users/xuxuheng/plugins/castreader-marketplace/experiments/desktop-dom-sync/`：独立 Electron 44.4.1 程序，使用既有真实 CastReader WAV（4.968 秒、8 个词的 API 时间戳），完成 4/4 映射测试及 14/14 Electron 播放/DOM 高亮测试。

实测覆盖逐词 Range、跨标签文字、暂停、2× 播放、前后跳转、滚动/缩放、DOM 重渲染/移除、停止/结束清理。实验原文 HTML 保持不变，通过 CSS Custom Highlight 绘制。已查看实验截图并保留可交互窗口。新增音频费用为 $0；复用的是此前真实生成素材，不是新生成。

这证明已获得 DOM 时同步机制成立，**不证明可以取得 Codex 主回答 DOM**。Codex 主窗口仍未操作，动态注入仍未完成。完整实验记录见上述目录 `RESULTS.md`，结构化结果和截图在仓库 `.local/desktop-dom-lab/`。

随后增加的 3 项测试先复现了“释放后音频继续播放”“停止后的异步 seek 重新高亮零秒起始词”“媒体错误未清理”三个缺陷，再修复同步内核并通过测试。零秒边界与媒体错误属于明确标识的测试夹具/故障注入，不冒充新增真实 TTS 对齐素材。既有插件 12 项、应用样例 18 项离线回归也通过。人工测试说明与本机实验启动入口已放入实验目录；当前依旧不满足 Codex 原回答功能的发布条件，新版没有提交市场。

## 参考资料

## 2026-09-17：右侧阅读页面已实测

用户进一步询问可否改在 Codex 右侧工具栏打开的页面中高亮。同一真实英文音频实验现已通过受支持的 Codex In-app Browser 工具打开，并通过页面按钮运行了 14/14 项同步测试；截图确认播放时间 3.550 秒时高亮 `ideas`。为浏览器环境增加了支持 HTTP Range 的只读本地服务，解决初始服务导致音频不可跳转的问题。

该结果证明“右侧 CastReader 自有页面内 TTS＋同步高亮”可行，不需要访问被限制的主回答 DOM。现有页面仍是固定英文样例，尚未接入选中/上一条回复的自动传入、中文对齐、会员和完整生成流程。详细证据与剩余工作见插件仓库 `experiments/desktop-dom-sync/IN-APP-RESULTS.md`。此项没有提交市场更新。

## 参考资料链接

- [Chrome content scripts](https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts)
- [CSS Custom Highlight API](https://developer.mozilla.org/en-US/docs/Web/API/CSS_Custom_Highlight_API)
- [OpenAI 插件打包与能力](https://developers.openai.com/plugins/build/plugins)
- [OpenAI 自定义 UI 的 iframe 与消息桥](https://developers.openai.com/plugins/build/chatgpt-ui#overview)
- [Electron Chrome extension support](https://www.electronjs.org/docs/latest/api/extensions)
- [Electron webContents](https://www.electronjs.org/docs/latest/api/web-contents)
