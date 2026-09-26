# 移动 Safari 高亮残留修复与复测

## 当前结论：新增修复已安装，真机播放验收待完成

更新：2026-09-27 00:14（北京时间）。以下最新记录取代此前“新增修复尚未构建/安装”的状态；下方旧版验收保留为历史。

### 最新版本与运行中的扩展

- 源码：扩展工作树 `codex/safari-iphone-adaptation-20260926`，HEAD `c8095c2` 加本地高亮修改；原生工作树 `codex/ios-safari-iphone-20260926`，HEAD `3e07e2b` 加同步资源。发布基线 `ffc7c8f` / `b6dd4d7` 祖先校验和增量集成检查通过，未覆盖原生阅读子系统。
- 原生 App/扩展 1.2.45（68），WebExtension manifest 1.2.46。按同一候选版规则复用版本号，以脚本哈希区分本次修复。
- 普通 `content.js` SHA-256：`192e07f0e15b8ce27ec088b2e62e17ecdb5a9491235e8b2243153e523d333a75`。WXT iOS 产物、原生同步资源、模拟器包、真机包四处一致；无临时 QA 探针。
- 23:47:41 成功安装 `com.same.castreader` 到用户 iPhone；devicectl 回读确认 1.2.45（68），新容器 `0AD06E56-4B50-4CC7-A7DF-FC9D47FF4E08`。23:48:47 重启 Safari 并导航至新的 Wikipedia Reading URL，避免旧标签页继续持有旧脚本。
- 后续进程回读确认 `CastReader Safari Extension` PID 20854 来自**这个新容器**。这是最新安装包身份和运行来源的证据，不能替代页面逐词播放验收。
- 手机另一个同名 App 是 `com.same.castreader.releasechecks1244` 1.2.44（66），它是独立旧检查包；没有删除用户应用。
- 完整记录：[安装及哈希](evidence/safari-highlight-visibility-20260926/build-install-verification.json)。

### 本次定位及修复

1. **浅色网页上的高亮不可见。** 原 WebKit 绘制方式仅依赖系统主题；系统深色但网页白底时 `screen` 混合不能产生可见色块。现解析正文及祖先实际背景（含透明度合成），透明画布再检查 `color-scheme`。
2. **维基百科折叠章节导致有声无高亮。** 真正的 iPhone 模拟器 Safari 中复现：恢复进度进入 `hidden="until-found"` 的正文后，音频继续，锚点检查清空高亮并提前返回，自动滚动也没有执行。现先按 HTML ancestor revealing 顺序派发 `beforematch`，展开可查找章节，再检查锚点、绘制、滚动；普通 `[hidden]` 内容不主动展开。

新增浏览器回归 `scripts/test-highlight-findable-section-browser.mjs` 覆盖嵌套展开事件顺序、已保存段落定位/高亮/滚动、普通隐藏内容保持隐藏及停止清理；通过。

### 新增修复的验证范围

| 验证 | 本次结果 |
| --- | --- |
| 类型检查、折叠章节回归、视口恢复回归、完整像素回归 | PASS |
| 实际 iPad Safari WebKit：网页浅/深 × 系统浅/深 × 词/句 | 8/8 PASS；连续推进与直接定位像素一致；停止恢复干净画面 |
| Safari / Chrome 静态一致性门禁 | 180 / 263 PASS |
| 普通模拟器包、签名真机包 | BUILD SUCCEEDED；资源哈希相同 |
| iPhone 模拟器实际 Wikipedia + 真实云端音频，临时诊断包 | PASS：暂停/恢复、跨段、滚动、停止；16/16 playing 采样有词 Range，锚点丢失/脱离和 TTS 错误均为 0 |
| 最新普通包 iPad 实际 UI 回归 | PASS：真实 Wikipedia，Heart→Bella，暂停/恢复、跨段滚动、停止；速度菜单选择 1x（原本为 1x，不计作变速验证） |
| 最新普通包 iPhone 实际 UI 回归 | PASS：1x→0.75x、Bella→Heart、稳定正文暂停/恢复、跨段、停止清理；使用同篇文章的 `/w/index.php?title=Reading&useskin=minerva` 地址从开头复测 |
| 用户真机最新包连续朗读/高亮/滚动/换音色 | NOT_RUN，尚未完成视觉与音频同步验收 |

修复前同样的真实 Wikipedia 测试 16 次 playing 采样仅 1 次有词 Range，lost=7，scrollY 始终为 0；修复后 scrollY 从 3380 推进到 4596，暂停前后媒体时钟均为 11.06318252974996，停止状态 idle。一个采样的词矩形部分触及视口底边，不能据此宣称所有采样完全位于舒适区。证据：[前后对照](evidence/safari-highlight-visibility-20260926/wikipedia-before-after.json)、[实际 WebKit 像素矩阵](evidence/safari-highlight-visibility-20260926/webkit-pixels.json)、[修复后截图](evidence/safari-highlight-visibility-20260926/iphone-reveal-resumed.png)、[普通包高亮截图](evidence/safari-highlight-visibility-20260926/iphone-production-highlight.png)。采样压缩文件同目录。

普通包 iPad 结果 `/tmp/SafariFinalIPadUI2.xcresult`，测试于 2026-09-27 00:04:15 通过。已检查[换音色后朗读](evidence/safari-highlight-visibility-20260926/ipad-safari-resumed-5.png)与[停止清理](evidence/safari-highlight-visibility-20260926/ipad-safari-stopped.png)：活动词可见，前段链接没有旧高亮，停止后橙色段落/词层均清理。期间 iPad 维基百科权限由当前网站的“Allow for One Day”正常授予，未授予全部网站。普通 UI 用例只断言控制状态，视觉判断另据截图，不把按钮断言当作像素证明。

初次普通包测试失败已保留：iPhone 在跨段缓冲时检查暂停按钮立即失败；另一轮新音色准备超过测试 10 秒上限；iPad 初次未授予当前网站权限；速度菜单在 Safari AX 中是 Other/MenuItem，测试的 Button 查询无法定位。没有删除产品错误或伪造 PASS，先检查实际状态，再修正对应测试前置和定位方式。[iPhone 10 秒超时后恢复截图](evidence/safari-highlight-visibility-20260926/iphone-voice-recovered.png)。

普通包 iPhone 最终结果 `/tmp/SafariFinalProductionUI6.xcresult`，2026-09-27 00:13:26 通过；[恢复后逐词高亮](evidence/safari-highlight-visibility-20260926/iphone-safari-resumed-2.png)、[停止后清理](evidence/safari-highlight-visibility-20260926/iphone-safari-stopped.png)。该普通控件复测用的是同文章非 canonical 路径，因此走通用提取、也读到了 Article/Talk 等导航文字；这项测试证明控件和绘制流程，不证明该非 canonical 路径的正文去噪质量。用户原始 `/wiki/Reading` 的折叠章节问题由上文 QA 前后对照与普通包截图单独验证。

额外记录：一次从旧进度末尾开始的控件用例遇到文章自然结束，暂停检查失败；一次短说明末尾的点击发生在主按钮切为 loading 时，按现有 `handlePrimaryClick` 规则执行停止。最终在持续播放正文上检查暂停，并继续变速/换音色/恢复/停止。没有更改产品的“加载中点击取消”规则；缓冲瞬间主按钮语义切换仍应按这一行为理解。各次失败日志、最终通过日志及[结果摘要](evidence/safari-highlight-visibility-20260926/final-ui-results.json)均保留。

临时 QA 包仅用于模拟器内容进程诊断，源码 `content.ts` 已恢复，随后重新构建普通包才安装手机。未录制外放音频或做声学逐字对齐；不声称这些计时和像素检查已经覆盖听感。

### 当前真实限制与发布门禁

主机重启后编译与模拟器工具已恢复，先前工具启动卡死不再是构建阻塞。当前会话没有电脑控制工具，配置显示该 MCP 已禁用；没有修改工具配置或系统安全服务。真机 XCTest 两次在方法开始前因 `dtxproxy:XCTestDriverInterface:XCTestManager_IDEInterface` 连接被拒退出；SafariDriver 无法连接此无线真机。用户已锁屏，尚需恢复镜像控制或用户完成这次新包的实际播放验收。

本轮未提交 git、未上传 App Store。用户要求核心服务验证后才提交，故继续保持发布门禁关闭；正式提审还需按 iOS 核心服务规范完成对应 Read/Explain 与账户/额度验收。

## 历史：新增可见性修复之前的残留修复验收

下列记录来自较早的绘制层候选。它们覆盖混合格式残留与完整控件流程，但不能自动证明本次新增修复已在真机验收通过。

## 对上一轮验收的更正

上一轮纯文本测试和 DOM Range 采样证明了播放、定位与滚动状态，但没有充分覆盖链接、斜体和粗体混排的实际像素清理。用户反馈的残留确实存在，不能用正确的 CSS Highlight registry 状态推断画面已清理。

本轮先复现维基百科 Reading 的旧词残留，再用包含 `a/em/strong` 的实际 HighlightSync fixture 缩小范围。第一版改为同一个 Highlight 对象 `clear/add`，消除了完整旧词，但真实朗读仍留下链接下方的橙色细条，用户再次截图指出。这一版**没有通过最终视觉验收**。

## 最终实现

- WebKit 使用单独、可移除的词/句绘制层，根据真实 Range 的 `getClientRects()` 画矩形。保留定位与时间同步，原文不拆包、不改写；原生 Custom Highlight 的背景设为透明，避免其旧渲染器残留。Chrome 保持原生高亮。
- 绘制层放在隔离的 ShadowRoot，穿透点击；随滚动和重排更新几何；换词、换段、停止分别清理对应矩形，停止销毁绘制层和动画回调。浅色页面混合绘制保留黑字、蓝色链接的可读性。
- 另修复实际回归发现的缓存跳读问题：从后面的已保存进度跳回缓存短标题时，重新打开“仍在生成”队列状态，避免标题先结束、下一段尚未返回就错误结束整篇。保留克隆额度终止状态的门控。

上游参考：[WebKit 321567](https://bugs.webkit.org/show_bug.cgi?id=321567)。本地结果表明单用 clear/add 仍不足以解决这里的细条残留，因此最终没有依赖这一做法绘制 Safari 高亮。

## 实际测试

环境：iPhone 15 Pro Max / iPad Air 11-inch M4 模拟器，iOS/iPadOS 26.5；App 1.2.45（68），扩展 manifest 1.2.46。调用真实 TTS，以实际媒体时钟和画面验收；未做外放录音或逐字听感审校。

合成文章含标题、12 个正文段落，每段混合链接、斜体和粗体。最终 run 为 `iphone-overlay-final`、`ipad-overlay-final`。`inline-final` 等早期 run 是未通过的 clear/add 版本，不能作为最终成功证据。

| 项目 | iPhone | iPad |
|---|---|---|
| 从标题读到第 12 段、自动续播 | 通过，标题结束时缓冲后自动进入第 1 段 | 通过，同样覆盖标题缓冲 |
| 逐词清理、自动滚动 | 通过，未再观察到旧词或链接细条 | 通过，未再观察到旧词或链接细条 |
| 暂停、倍速、换音色、恢复 | 1→1.25，Bella→Heart | 1.25→0.75，Bella→Heart |
| 暂停时媒体时钟保持 | 10.2667 秒，换音色前保持 | 6.958 秒，换音色前保持 |
| 换音色后的播放 | 保持同段，使用新音色从该段重新生成后恢复 | 同左 |
| 竖屏到横屏朗读 | 430→814 CSS px | 820→1180 CSS px |
| 自然结束 | 末段进入 idle，高亮清空 | 末段进入 idle，高亮清空 |
| 重启后手动停止 | 队列及高亮清空，连续 309 秒无复播 | 队列及高亮清空，连续 77 秒无复播 |

主流程采样窗口及完整数据见 [summary.json](evidence/safari-highlight-repaint-20260926/summary.json)、[samples.jsonl.gz](evidence/safari-highlight-repaint-20260926/samples.jsonl.gz)。iPhone 474 个 playing 采样，其中 467 个有词 Range；iPad 636 / 631，少量处于词或段落边界。两者屏外词采样、TTS 错误和锚点丢失均为 0。高亮时间戳区间到音频时钟的 P95 距离分别 64.13 / 57.21 ms；这是客户端同步指标，不是语音逐字声学对齐精度。

### 普通构建回归

验收后重新关闭测试探针并构建普通资源。普通构建已分别安装到 iPhone、iPad 模拟器：

- iPhone 打开真实维基百科 Reading，实际朗读用户截图中的 `recognition / orthography / punctuation / alphabetics / phonics` 段落并续播后文。读到末词时早先所有链接均无残留，停止后页面清空。
- iPad 普通构建实际播放含混合格式的文章，逐词推进和自动滚动可用。
- [维基百科段落中途](evidence/safari-highlight-repaint-20260926/iphone-wikipedia-active.png)、[读到段落末词时](evidence/safari-highlight-repaint-20260926/iphone-wikipedia-next.png)、[停止后](evidence/safari-highlight-repaint-20260926/iphone-wikipedia-stopped.png)。
- [iPad 自然结束](evidence/safari-highlight-repaint-20260926/ipad-overlay-ended.png)、[停止并旋转后](evidence/safari-highlight-repaint-20260926/ipad-overlay-stopped.png)、[普通构建截图](evidence/safari-highlight-repaint-20260926/ipad-production-final.png)。

## 回归与构建门禁

以下本轮均通过：

```text
node scripts/test-highlight-repaint-browser.mjs
node scripts/test-cached-seek-continuation.mjs
node scripts/test-word-highlight-source-browser.mjs
pnpm test:highlight:viewport
pnpm test:player-buffering
pnpm test:voice-clone:typecheck
pnpm build
pnpm build:safari
check:safari — 180 checks
check:safari:chrome-parity — 263 checks
native baseline check / simulator build / device build / codesign verification
```

新增像素回归用生产 HighlightSync，比较连续经过 inline 元素后的最终像素与直接高亮末词/末句的像素，且停止后必须精确恢复初始像素、移除绘制层。自动化覆盖 Chrome 原生及 Safari UA 绘制分支；**Safari UA 在 Chrome 中运行不等于 WebKit**，真实 WebKit 的补充证据来自上面的两台模拟器与维基百科录屏。

## 真机与发布状态

原生候选工作树 `codex/ios-safari-iphone-20260926`，已确认发布基线 `ffc7c8f` 是祖先。本次只同步扩展生成资源，未覆盖原生阅读子系统。

2026-09-26 20:03（北京时间）成功安装 `com.same.castreader` 1.2.45（68）到连接的 iPhone，随后通过 devicectl 回读版本。普通模拟器包与真机包 content.js SHA-256 一致，详见 [builds.json](evidence/safari-highlight-repaint-20260926/builds.json)。安装后手机自动锁屏，自动启动被系统拒绝，因此不把“安装成功”记为真机 Safari 验收通过。后续镜像一度恢复并进入 Safari、刷新了现有维基百科页面，但控制连接反复变为 Connection Paused / Computer Use is not active，重建会话后仍复发，未完成稳定的真机朗读回归。

发布门禁保持未放行：仍需最新版真机 Safari 回归，以及正式提审工作流的原生 Read/Explain、账号/订阅等检查。本轮没有重新证明所有语言、克隆音色、复杂嵌套滚动/iframe、PDF、iPad 分屏、后台锁屏和弱网场景，也不宣称与 Chrome/Mac Safari 的全部网页行为完全一致。

历史临时录屏路径（主机重启后可能已不存在，保留的仓库截图/采样才是可回溯证据）：`/tmp/safari-highlight-repaint-20260926/iphone-overlay-final.mp4`、`ipad-overlay-final.mp4`、`iphone-wikipedia-production-final.mp4`；原始失败录屏保留在同目录用于对照。
