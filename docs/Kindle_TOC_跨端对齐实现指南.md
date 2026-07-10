# Kindle TOC 跨端对齐实现指南

更新时间：2026-07-08

适用范围：CastReader iOS / Android Kindle 阅读页。本文沉淀 iOS 已验证通过的 Kindle 目录入口方案，Android 侧按同样产品口径和链路实现。

## 1. 产品需求

### 1.1 入口

- 在 Kindle 阅读页底部播放器增加三横杠目录按钮。
- 点击后显示 CastReader 自定义目录面板，标题为 Table of Contents / 目录，支持关闭。
- 目录面板不使用 Kindle 原生 UI 让用户直接操作，避免原生弹层受 WebView scale/crop 影响。

### 1.2 目录内容

- 目录条目必须来自 Kindle 原生 TOC。
- 需要完整扫描目录，支持滚动到底，不能只拿当前可见的几条。
- 每个条目至少包含：
  - `index`
  - `text`
  - `level`
  - `active`
  - `path/sourcePath/actionPath`
  - `href`
  - `role/aria/actionSummary`

### 1.3 当前章节选中态

- 打开目录时，当前章节选中态必须和 Kindle 原生 TOC 一致。
- 不要自己计算 selected。
- 不要用 OCR 推断章节。
- 不要用“上次点击的章节”作为 selected fallback。
- 只同步 Kindle 原生 TOC DOM/组件上已经存在的 selected/current/highlight 状态。

### 1.4 点击跳转

- 点击 CastReader 自定义目录项后，应跳转到 Kindle 对应章节。
- 跳转方式不能用屏幕坐标模拟点击。
- 必须在隐藏的 Kindle 原生 TOC 里按稳定的 `index/path/text/actionPath` 找到对应条目，再调用 Kindle 自己的 DOM/React/Ionic click 链路。
- 跳转成功后关闭原生 TOC 和 CastReader 自定义面板，等待真实可见页稳定。

### 1.5 播放状态

- 如果跳转前正在朗读或解读：
  - 先取消旧 TTS/QuickRead/OCR/预加载任务。
  - 跳转稳定后，从新章节当前页按原模式继续播放。
- 如果跳转前是暂停/停止：
  - 只跳转，不自动播放。
- 快速连续点击章节时：
  - 用 generation/epoch 取消旧任务。
  - 只保留最后一次点击。

## 2. 最终架构

iOS 最终采用“隐藏 Kindle 原生 TOC + CastReader 自定义 TOC 面板”。

### 2.1 为什么不直接用 Kindle 原生 TOC

当前 Kindle 阅读页为 blob/OCR/highlight 对齐做了 WebView 可视窗口适配。直接展示 Kindle 原生 TOC 会遇到：

- 原生 TOC 被 scale/crop 后显示不全。
- 滚动到底不稳定。
- 点击坐标可能偏移。
- 关闭困难。
- 打开/关闭目录可能改变底层正文页位置。

因此不要让用户直接操作 Kindle 原生 TOC。

### 2.2 核心链路

1. 用户点击底部三横杠。
2. App 显示 SwiftUI/原生自定义目录面板，进入 loading。
3. WebView 后台打开 Kindle 原生 TOC。
4. 立刻用 CSS 隐藏 Kindle 原生 TOC，但不要 `display:none`。
5. 通过 JS 扫描 Kindle 原生 TOC 的真实 scroll container。
6. 分段设置 `scrollTop`，收集完整目录。
7. 读取 Kindle 原生条目的 active/current/selected/highlight 状态。
8. 用扫描结果渲染 CastReader 自定义目录。
9. 点击自定义条目时，后台重新定位原生 TOC 条目并触发 Kindle 自己的跳转。
10. 跳转完成后关闭原生 TOC，锁回 Kindle page mode，按播放规则继续或停止。

## 3. iOS 当前实现位置

### 3.1 Swift

文件：

- `/Users/xuxuheng/Documents/CastReader/CastReader/Views/Kindle/KindleBookView.swift`

关键类型/函数：

- `KindleTOCEntry`
- `KindleNativeTOCPanel`
- `toggleTOCProbeFromButton()`
- `presentNativeTOC(reason:epoch:)`
- `scanNativeTOCEntries(reason:)`
- `makeTOCEntries(_:)`
- `selectNativeTOCEntry(_:)`
- `jumpToNativeTOCEntry(_:epoch:)`
- `dismissNativeTOCPanel()`
- `closeTOCIfVisible(reason:)`
- `setNativeKindleTOCHidden(_:reason:)`
- `setNativeKindleTOCSheetStyled(_:reason:)`

### 3.2 WebScript

文件：

- `/Users/xuxuheng/Documents/CastReader/CastReader/Services/KindleWebScripts.swift`

关键脚本：

- `tocProbe`
- `hideNativeTOCOverlay`
- `showNativeTOCOverlay`
- `nativeTOCScanStep`
- `nativeTOCJumpStep`
- `closeTOCOverlay`

## 4. TOC 打开与扫描细节

### 4.1 打开

iOS `presentNativeTOC` 的顺序：

1. 设置 `isNativeTOCPresented = true`、`isNativeTOCLoading = true`。
2. 清理历史 TOC 样式。
3. 注入/确认 Kindle 捕获脚本。
4. `hideNativeTOCOverlay(true)`，让原生 TOC 不可见但仍渲染。
5. `setKindlePageModeLocked(false)`，避免 TOC 打开/滚动被阅读页 page lock 拦截。
6. 循环调用 `tocProbe`，直到 `stage == toc-visible` 或 `count > 0`。
7. 调用 `scanNativeTOCEntries`。
8. 扫描完成后 `setKindlePageModeLocked(true)`。

### 4.2 扫描

扫描由 `nativeTOCScanStep(reset:)` 分步完成：

- `reset=true` 时初始化：
  - `entries`
  - `byKey`
  - `activeByKey`
  - `stable`
  - `lastScrollTop`
  - `lastCount`
  - `started`
- 通过 `findContainers()` 找到最像 TOC 的 root 和 scroll container。
- 第一次扫描时必须先调用 `rememberVisibleActive(container)`，再把 scrollTop 设到 0。

这一点非常关键：

Kindle 原生 TOC 打开时通常会滚到当前章节附近，并且当前章节在这一刻有 `highlighted/selected/current` 状态。如果我们一开始就 `scrollTop = 0`，可能会把当前章节滚出可见区，导致后续全量扫描拿不到 selected 状态。

正确顺序：

```text
open Kindle native TOC
hide native TOC visually
find TOC container
remember visible active entry
scrollTop = 0
scan from top to bottom
merge activeByKey back to final entries
```

### 4.3 active 状态来源

`activeState(el)` 需要读取这些字段：

- `id`
- `class`
- `aria-current`
- `aria-selected`
- `selected`
- `data-selected`
- `data-active`
- `data-current`

匹配关键字：

- `current`
- `selected`
- `active`
- `checked`
- `highlight`
- `is-active`
- `is-selected`
- `page`
- `true`

iOS 实测 Kindle 当前章节可能表现为：

- `id=highlighted-entry`
- `class` 包含 `toc-item-highlighted`

### 4.4 Swift 侧 selected 规则

`makeTOCEntries(_:)` 必须直接使用 JS 返回的 `entry["active"]`：

```swift
active: boolValue(entry["active"])
```

禁止加入这些 fallback：

- OCR 当前页标题推断。
- 按 CHAPTER 数字推断。
- 使用上次点击章节作为 selected。
- 使用 pageKey/order 计算当前章节。

原因：用户明确要求 TOC 同步就是同步 Kindle 原生 TOC，selected 一定来自 Kindle 原生字段。计算型 selected 容易在章节正文中间、快速翻页、章节跨度不均时出错。

## 5. 点击章节跳转细节

### 5.1 跳转入口

点击自定义目录项调用：

- iOS：`selectNativeTOCEntry(_:)`
- 内部进入：`jumpToNativeTOCEntry(_:epoch:)`

### 5.2 跳转前处理

跳转前需要：

- 记录当前 visible page key。
- 根据当前播放状态决定是否跳转后继续播放。
- `resetLiveSession(clearPlaybackCenter:false)`。
- `cancelInFlightProcessingForManualPageTurn(reason:"toc-jump")`。
- 清掉 `pendingCaptureKey` 和 external mismatch。
- 如果正在播放，设置 `isPageTurnResuming = true`。
- 暂时 `setKindlePageModeLocked(false)`。
- 确保 Kindle 原生 TOC 打开但隐藏。

### 5.3 原生条目定位

不要做屏幕坐标点击。使用 `nativeTOCJumpStep`：

- 优先用扫描得到的 index/path/actionPath/text/href 定位条目。
- 如条目未在当前可见区域，滚动原生 TOC 到目标附近。
- 找到目标后触发原生 click。
- click 要兼容 React/Ionic：
  - React fiber props 的 `onClick`
  - DOM `onclick`
  - pointer/mouse/touch/click 事件
  - 可点击父节点 `ion-item/button/a/[role]`

### 5.4 跳转成功判断

不要只看 click 是否成功。必须等待 Kindle 当前 visible page key 变化：

- 旧 key：点击前 `currentVisibleKindlePageKey()`
- 新 key：`waitForNavigationTargetKey(oldKey:)`

只有 page key 变化，才认为章节跳转成功。

当前 iOS 策略：

- 第一种 click 策略后较短轮询。
- 如果没有导航，换下一种 click 策略。
- 对部分章节，第一次 handler 可能只聚焦/展开，不跳转；第二种策略才会导航。

### 5.5 跳转后处理

成功后：

- 关闭 Kindle 原生 TOC。
- 取消隐藏 native TOC。
- 锁回 Kindle page mode。
- 关闭 CastReader 自定义 TOC 面板。
- 如果跳转前在播放，调度从新 visible page 继续朗读/解读。
- 如果跳转前停止，保持停止。

## 6. 已遇到的问题与解决方案

### 6.1 直接展示 Kindle 原生 TOC 显示不全

问题：

- WebView 为阅读页适配了 scale/crop。
- 原生 TOC 被影响，显示、滚动、点击都不稳定。

方案：

- 用户只看 CastReader 自定义 TOC 面板。
- Kindle 原生 TOC 只作为隐藏桥使用。

### 6.2 打开 TOC 导致底层书页变化

问题：

- 打开/关闭 Kindle 原生 TOC 会改变底层正文位置，看起来像重新加载或翻到别的内容。

方案：

- 隐藏原生 TOC，避免用户直接操作其浮层。
- 打开 TOC 前后不要重设阅读 WebView 外框、scale、crop。
- TOC 扫描只滚动 TOC 自己的 scroll container，不滚动正文。
- 关闭 TOC 后恢复 page mode lock。

### 6.3 目录能扫全，但点击不跳转

问题：

- 初版只在自定义面板里拿到了 title/index，但没有正确触发 Kindle 内部跳转。
- 坐标点击会被 hidden overlay/scale/crop 干扰。

方案：

- 后台打开/定位原生 TOC DOM。
- 用 index/path/text 找到原生条目。
- 触发 React/Ionic/DOM 多层 click。
- 以 visible page key 是否变化作为成功标准。

### 6.4 某些章节跳转正确，某些章节不正确

问题：

- 中间章节有时需要先滚动到目标附近。
- 有些 TOC 条目第一次 click 只会让状态变化，不会真正导航。

方案：

- `nativeTOCJumpStep` 分步执行：
  - 找 container。
  - 滚动到目标范围。
  - 定位条目。
  - 多策略触发 click。
  - 未导航时换下一策略重试。

### 6.5 跳转后卡几秒

问题：

- 轮询等待导航 key 太保守。

方案：

- 点击后立即开始检查 visible key。
- 初期使用更短间隔轮询。
- 对第一种策略使用较短 timeout，失败快速进入下一策略。

### 6.6 当前章节 selected 不同步

问题：

- 用户从 CHAPTER 39 手动翻到 CHAPTER 37 后再打开 TOC，37 没有选中。
- 初版尝试 OCR/章节号/上次点击 fallback，仍不可靠。

最终方案：

- 完全取消计算型 selected。
- 打开 Kindle 原生 TOC 后，先读取当前可见 TOC 区域的原生 active/highlight 状态。
- 再滚动到顶部扫完整目录。
- 扫描过程中用 `activeByKey` 保存已发现的 active。
- 最终自定义面板只展示 Kindle 原生 `active`。

验收日志：

```text
KINDLE native toc scan ... activeHint=CHAPTER 37
KINDLE native toc scan complete ... source=native active=CHAPTER 37
```

## 7. 日志要求

Android 侧请对齐这些日志字段，方便跨端排查：

```text
KINDLE tocOpen requested source=playback-bar epoch=...
KINDLE tocOpen panelFound=... attempt=... stage=... count=...
KINDLE native toc hidden reason=... hidden=true/false ok=...
KINDLE native toc scan reason=... pass=... stage=... count=... added=... scrollTop=.../... activeHint=...
KINDLE native toc scan complete reason=... entries=... source=native active=... first=... last=...
KINDLE toc select begin index=... text=... resume=... mode=...
KINDLE native toc jump open attempt=... stage=... count=... target=...
KINDLE native toc jump step=... ok=... stage=... target=... text=... actionPath=... framework=...
KINDLE navigation target key=... waitedMs=...
KINDLE native toc jump navigation-ok index=... old=... new=... text=...
KINDLE toc close reason=... ok=... clicked=...
```

## 8. Android 落地 Checklist

### 8.1 UI

- 底部播放器增加三横杠菜单按钮。
- 点击显示 Android 原生自定义 BottomSheet/Dialog 目录面板。
- 面板支持：
  - loading
  - error
  - empty
  - close
  - active 条目视觉标识
  - 点击条目

### 8.2 WebView JS

复刻 iOS 的核心脚本能力：

- `tocProbe`
- `hideNativeTOCOverlay`
- `showNativeTOCOverlay`
- `nativeTOCScanStep`
- `nativeTOCJumpStep`
- `closeTOCOverlay`

重点：

- 原生 TOC 只隐藏，不 `display:none`。
- 扫描只滚 TOC scroll container，不滚正文。
- 第一次扫描必须先 `rememberVisibleActive(container)`，再 `scrollTop=0`。
- `activeState` 必须读取 `id/class/aria-current/aria-selected/selected/data-*`。
- 自定义面板 selected 只取 `entry.active`。

### 8.3 线程/取消

- 所有 TOC open/scan/jump 使用 generation/epoch。
- 快速连续点击章节，旧任务取消。
- 跳转时取消旧播放任务、预加载任务、QuickRead/TTS/OCR 任务。

### 8.4 跳转

- 不做屏幕坐标点击。
- 用 entry 的 `index/path/text/actionPath` 回到 Kindle 原生 TOC DOM 找条目。
- 触发 Kindle 自己的 click 链路。
- 用 visible page key 变化判断跳转成功。
- 成功后关闭原生 TOC，恢复阅读页锁定。

### 8.5 播放恢复

- 跳转前正在朗读或解读：新章节页稳定后继续原模式播放。
- 跳转前停止：只跳转，不播放。

## 9. Android 验收用例

1. 打开 Kindle 书籍，点击底部三横杠，目录完整显示。
2. 目录能滚到底，最后一章显示正确。
3. 点击 CHAPTER 1，跳到第 1 章。
4. 点击中间章节，例如 CHAPTER 14/20/36，跳转正确。
5. 点击最后章节，例如 CHAPTER 44，跳转正确。
6. 点击 39 后，手动翻页到 37，再打开 TOC，37 有选中标识。
7. 朗读中点击章节，旧播放停止，新章节页稳定后继续朗读。
8. 解读中点击章节，旧解读/预取取消，新章节页稳定后继续解读。
9. 停止状态点击章节，只跳转不播放。
10. 快速连续点击多个章节，只执行最后一次。

## 10. 禁止回退的点

- 不要让用户直接操作 Kindle 原生 TOC。
- 不要用 OCR 推断 selected。
- 不要用上次点击章节推断 selected。
- 不要用屏幕坐标模拟章节点击。
- 不要为了 TOC 改变阅读 WebView 的外框、scale、crop。
- 不要让 TOC 扫描滚动正文页面。
- 不要让预加载/播放任务污染 TOC 跳转后的当前页。

