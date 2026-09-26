# 移动 Safari 高亮残留修复与复测

扩展修复源码提交：`534279d`（`codex/safari-iphone-adaptation-20260926`）。

日期：2026-09-26。状态：本地候选已修复并完成下面的模拟器回归；已安装 iPhone 测试包，尚未提交 App Store。

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

完整本地录屏：`/tmp/safari-highlight-repaint-20260926/iphone-overlay-final.mp4`、`ipad-overlay-final.mp4`、`iphone-wikipedia-production-final.mp4`；原始失败录屏保留在同目录用于对照。
