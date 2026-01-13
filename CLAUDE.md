# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Auto Run on Simulator

当用户要求启动/运行项目时，自动执行以下步骤：

1. 编译项目并推送到模拟器运行
2. 如果遇到编译错误，直接阅读 Xcode 的报错信息并自行修复代码
3. 重复编译直到运行成功

```bash
# 完整的编译和运行流程
xcodebuild -workspace CastReader.xcworkspace -scheme CastReader -destination 'platform=iOS Simulator,name=iPhone 13 Pro' -derivedDataPath build clean build
xcrun simctl boot "iPhone 13 Pro"
open -a Simulator
xcrun simctl install "iPhone 13 Pro" build/Build/Products/Debug-iphonesimulator/CastReader.app
xcrun simctl launch "iPhone 13 Pro" com.same.CastReader
```

## Build Commands

This is a native iOS SwiftUI project using Xcode.

```bash
# Build the project
xcodebuild -scheme CastReader -destination 'platform=iOS Simulator,name=iPhone 13' build

# Run tests (unit + UI tests)
xcodebuild test -scheme CastReader -destination 'platform=iOS Simulator,name=iPhone 13'

# Clean build
xcodebuild clean -scheme CastReader
```

Or use Xcode directly: ⌘B (build), ⌘R (run), ⌘U (test).

## Architecture

- **SwiftUI app** targeting iOS 15.5+
- **Entry point:** `CastReader/CastReaderApp.swift`
- **Pattern:** MVVM + @EnvironmentObject for global state
- **Tests:** XCTest framework (`CastReaderTests/`, `CastReaderUITests/`)
- **Assets:** `CastReader/Assets.xcassets/`

### Project Structure

```
CastReader/
├── Models/          # Data models (Book, Document, TTSTimestamp, etc.)
├── Services/        # API, Audio, TTS, Visitor services
├── ViewModels/      # MVVM view models
├── Views/
│   ├── Explore/     # Book browsing
│   ├── Library/     # User documents
│   ├── Import/      # File/text import
│   ├── Player/      # TTS player with highlighting
│   └── Shared/      # Reusable components
└── Utils/           # Constants, Extensions
```

No external dependencies (CocoaPods, SPM, or Carthage) are currently configured.

## 避坑指南 (iOS 15.5 Best Practices)

### 1. Enum with Associated Values 需要手动实现 Equatable

```swift
// ❌ 错误：带关联值的 enum 不能直接用 == 比较
enum TTSStatus {
    case error(String)
}
if status != .loading { } // 编译错误

// ✅ 正确：添加 Equatable 协议
enum TTSStatus: Equatable {
    case error(String)
}
if status != .loading { } // 正常工作
```

### 2. CGFloat 需要 import SwiftUI 或 CoreGraphics

```swift
// ❌ 错误：仅 import Foundation 无法使用 CGFloat
import Foundation
static let height: CGFloat = 64  // Cannot find type 'CGFloat'

// ✅ 正确：使用 SwiftUI（推荐）或 CoreGraphics
import SwiftUI
static let height: CGFloat = 64
```

### 3. Layout 协议是 iOS 16+，用 AttributedString 替代

```swift
// ❌ 错误：Layout 协议需要 iOS 16+
struct FlowLayout: Layout {  // Cannot find type 'Layout'
    func sizeThatFits(proposal: ProposedViewSize, ...) { }
}

// ✅ 正确：用 AttributedString 实现文字高亮（iOS 15+）
func buildAttributedText() -> AttributedString {
    var result = AttributedString()
    for (index, word) in words.enumerated() {
        var attr = AttributedString(word)
        if index == highlightedIndex {
            attr.backgroundColor = .green
        }
        result.append(attr)
    }
    return result
}
```

### 4. presentationDetents 是 iOS 16+

```swift
// ❌ 错误：iOS 16+ only
.sheet(isPresented: $show) {
    MySheet()
        .presentationDetents([.medium])  // 编译错误
}

// ✅ 正确：移除或用 @available 条件编译
.sheet(isPresented: $show) {
    MySheet()
}
```

### 5. 复杂 SwiftUI View 需要拆分以避免类型检查超时

```swift
// ❌ 错误：body 过于复杂导致 "unable to type-check in reasonable time"
var body: some View {
    NavigationView {
        List { /* 大量嵌套 */ }
            .modifier1()
            .modifier2()
            // ... 20+ 链式调用
    }
    .sheet { }
    .alert { }
    .overlay { }
}

// ✅ 正确：拆分为独立的 computed properties 或子 View
var body: some View {
    NavigationView {
        contentList
    }
    .sheet { textInputSheet }
    .alert { errorAlert }
    .overlay { loadingOverlay }
}

private var contentList: some View {
    List {
        ImportOptionRow(...)
        ImportOptionRow(...)
    }
}

@ViewBuilder
private var loadingOverlay: some View {
    if isLoading {
        LoadingView()
    }
}
```

### 6. fileImporter 的 UTType 需要安全处理

```swift
// ❌ 错误：某些 UTType 可能不存在
allowedContentTypes: [.pdf, .epub]  // .epub 可能未定义

// ✅ 正确：用 UTType(identifier:) 安全创建
private var supportedFileTypes: [UTType] {
    var types: [UTType] = [.pdf, .plainText]
    if let epub = UTType("org.idpf.epub-container") {
        types.append(epub)
    }
    return types
}
```

### 7. API 返回数据类型不一致 - 必须使用自定义解码器

后端 API 可能对同一字段返回不同类型（String/Array/Number），必须在 Model 中处理：

```swift
// ❌ 错误：假设 API 返回固定类型
struct BookMetadata: Codable {
    let genre: String?      // API 有时返回 String，有时返回 [String]
    let rating: String?     // API 有时返回 "4.5"，有时返回 4.5
}

// ✅ 正确：自定义解码器处理多类型
struct BookMetadata: Codable {
    let genre: [String]?    // 统一转为数组
    let rating: Double?     // 统一转为 Double

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // genre: 可能是 String 或 [String]
        if let arr = try? container.decodeIfPresent([String].self, forKey: .genre) {
            genre = arr
        } else if let str = try? container.decodeIfPresent(String.self, forKey: .genre) {
            genre = str.components(separatedBy: ", ")
        } else {
            genre = nil
        }

        // rating: 可能是 Double 或 String
        if let d = try? container.decodeIfPresent(Double.self, forKey: .rating) {
            rating = d
        } else if let s = try? container.decodeIfPresent(String.self, forKey: .rating) {
            rating = Double(s)
        } else {
            rating = nil
        }
    }
}
```

### 8. API 字段可能为 null - 所有非必需字段都用可选类型

```swift
// ❌ 错误：假设字段一定存在
struct BookIndex: Codable {
    let href: String    // API 可能返回 null
    let text: String
}

// ✅ 正确：除非确定必有值，否则用可选类型
struct BookIndex: Codable {
    let href: String?
    let text: String?
}
```

### 9. 调试 API 解码错误 - 打印原始响应和详细错误

```swift
do {
    return try decoder.decode(T.self, from: data)
} catch {
    // 必须打印这两项才能定位问题
    if let json = String(data: data, encoding: .utf8) {
        print("🔴 Raw response: \(json.prefix(1500))")
    }
    print("🔴 Decoding error: \(error)")  // 包含 codingPath
    throw error
}
```

### 10. 新增 API Model 前先用实际数据测试

1. 先用 curl 或 Postman 调用 API
2. 检查所有字段的实际类型（不要只看文档）
3. 注意相同字段在不同记录中类型可能不同
4. 所有非核心字段默认用可选类型

### 11. API 返回的 URL 可能包含空格 - 必须 URL 编码

后端返回的 URL 路径可能包含空格（如书名），`URL(string:)` 对含空格的字符串返回 nil：

```swift
// ❌ 错误：URL 含空格会返回 nil
let urlString = "https://...com/books/1_The Declaration of Independence/book.html"
let url = URL(string: urlString)  // nil！

// ✅ 正确：先 URL 编码
guard let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
      let url = URL(string: encoded) else {
    throw APIError.invalidURL
}
```

**受影响的场景：**
- 封面图片 URL (`cover`, `metadata.cover`)
- 书籍内容 URL (`content`)
- 任何文件路径类 URL

## TTS 播放器自动滚动功能规格

### 1. 功能概述

TTS 阅读器需要在播放时自动滚动，让当前朗读的段落保持在用户可视区域内。同时需要尊重用户的手动滚动行为——当用户主动滚动时，暂停自动滚动并显示"回到播放位置"按钮。

**核心原则：以段落为滚动单位**（不是句子/segment），避免长段落内频繁滚动造成的冲突。

### 2. 两种模式

| 模式 | 状态 | 行为 |
|------|------|------|
| **自动模式** | `autoScrollEnabled = true` | 段落切换时自动滚动到新段落 |
| **手动模式** | `autoScrollEnabled = false` | 不自动滚动，显示回弹按钮 |

### 3. 舒适区定义

```
屏幕高度
┌─────────────────────────┐ ← 0%
│                         │
│ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─│ ← 15% (comfortTop)
│                         │
│      舒适区域            │  ← 段落顶部应在此区域内
│      (Comfort Zone)     │
│                         │
│ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─│ ← 70% (comfortBottom)
│                         │
│      播放控制栏区域       │
└─────────────────────────┘ ← 100%
```

- **舒适区上边界**: 屏幕高度的 15%
- **舒适区下边界**: 屏幕高度的 70%
- 段落顶部 (`minY`) 在此区间内视为"可见"，无需滚动

### 4. 自动滚动触发逻辑

#### 触发条件（全部满足）
1. `autoScrollEnabled == true`
2. `currentParagraphIndex >= 0`（有正在播放的段落）
3. 当前段落**不在舒适区内**

#### 可见性判断
```
isParagraphVisible(index):
    frame = paragraphFrames[index]
    if frame 未知: return false  // 未渲染，需要滚动

    comfortTop = screenHeight * 0.15
    comfortBottom = screenHeight * 0.70

    // 第一段不检查上边界（允许在最顶部）
    if index == 0:
        return frame.minY <= comfortBottom

    // 其他段落：顶部必须在舒适区内
    return frame.minY >= comfortTop && frame.minY <= comfortBottom
```

#### 滚动目标位置
```
// 第一段：滚动到顶部
if index == 0:
    scrollTo(index, anchor: TOP)

// 其他段落：滚动到 15% 位置（留出舒适边距）
else:
    scrollTo(index, anchor: 15% from top)
```

### 5. 模式切换

#### 自动 → 手动（用户打断）
**触发方式**: 检测到用户滚动手势
```
ScrollView.onDragGesture {
    autoScrollEnabled = false  // 立即切换到手动模式
}
```

#### 手动 → 自动（用户恢复）
**触发方式**:
1. 点击"回到播放位置"按钮
2. 点击某个段落跳转播放

**执行顺序**:
```
1. 先滚动到目标段落（带动画，约 0.3s）
2. 等待滚动动画完成（延迟 0.35s）
3. 再启用 autoScrollEnabled = true
```

**为什么要延迟启用？**
如果立即启用，滚动动画进行中可能触发新的滚动检测，造成冲突。

### 6. "回到播放位置"按钮

#### 显示条件
```
!autoScrollEnabled && currentParagraphIndex >= 0
```

#### UI 规格
- **位置**: 播放控制栏上方，右下角
- **尺寸**: 36x36pt 圆形
- **样式**: 半透明毛玻璃背景 + 阴影
- **图标**: 定位图标（如 iOS 的 `scope`）

#### 点击行为
```
1. 计算目标 anchor（第一段用 TOP，其他用 15%）
2. 执行滚动动画（0.3s）
3. 延迟 0.35s 后设置 autoScrollEnabled = true
```

### 7. 状态流转图

```
┌──────────────────────────────────────────────────────────┐
│                                                          │
│   ┌─────────────┐     用户滚动      ┌─────────────┐     │
│   │  自动模式    │ ───────────────→ │  手动模式    │     │
│   │ auto=true   │                   │ auto=false  │     │
│   └─────────────┘                   └─────────────┘     │
│         │                                  │            │
│         │ 段落切换                          │            │
│         ↓                                  │            │
│   ┌─────────────┐                          │            │
│   │ 检查可见性   │                          │            │
│   └─────────────┘                   显示回弹按钮         │
│         │                                  │            │
│    ┌────┴────┐                             │            │
│    ↓         ↓                             │            │
│  可见     不可见                            │            │
│  (不滚动)  (滚动)                           │            │
│                                            │            │
│         ←───────── 点击按钮/点击段落 ────────┘            │
│         (滚动 + 延迟启用 auto)                           │
└──────────────────────────────────────────────────────────┘
```

### 8. 实现要点

#### 段落位置追踪
使用 PreferenceKey 收集每个段落的 frame：
```swift
// iOS (SwiftUI)
ParagraphView(...)
    .id(index)
    .background(
        GeometryReader { geo in
            Color.clear.preference(
                key: ParagraphFramePreferenceKey.self,
                value: [index: geo.frame(in: .named("scrollArea"))]
            )
        }
    )
```

```kotlin
// Android (Compose)
LazyColumn {
    itemsIndexed(paragraphs) { index, para ->
        ParagraphItem(
            modifier = Modifier.onGloballyPositioned { coordinates ->
                paragraphPositions[index] = coordinates.positionInParent()
            }
        )
    }
}
```

#### 滚动执行
```swift
// iOS
withAnimation(.easeInOut(duration: 0.3)) {
    proxy.scrollTo(index, anchor: anchor)
}

// Android
coroutineScope.launch {
    listState.animateScrollToItem(index)
}
```

#### 用户滚动检测
```swift
// iOS
.simultaneousGesture(
    DragGesture().onChanged { _ in
        viewModel.onUserScroll()  // 设置 autoScrollEnabled = false
    }
)

// Android
val nestedScrollConnection = remember {
    object : NestedScrollConnection {
        override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
            if (source == NestedScrollSource.Drag) {
                viewModel.onUserScroll()
            }
            return Offset.Zero
        }
    }
}
```

### 9. 注意事项

1. **以段落为单位**：不要追踪每个句子/segment 的位置，会导致滚动冲突
2. **延迟检测**：段落切换后等待 50ms 再检查位置，给 LazyList 渲染时间
3. **防重复滚动**：检查时确认仍是当前段落，避免快速切换时堆积多个滚动
4. **动画时长**：滚动动画 0.3s，启用自动模式延迟 0.35s（略大于动画时长）

## 本地 TTS 后台播放 - GPU/CPU 动态切换

### 问题背景

- **Kokoro CoreML 模型**内部使用 Metal Performance Shaders (MPS)
- **iOS 禁止后台 App 使用 GPU**，违反则进程被终止
- 即使设置 `.cpuAndNeuralEngine`，某些算子仍会回退到 GPU，导致后台合成失败

### 解决方案

**前台**：使用 `.cpuAndGPU` 模式，享受 GPU 加速（快）
**后台**：销毁 GPU 实例，重载 `.cpuOnly` 实例（慢但能工作）

```
App willResignActive → cleanup() → loadModel(.cpuOnly) → 后台继续合成
App didBecomeActive  → cleanup() → loadModel(.cpuAndGPU) → 前台恢复快速
```

### FluidAudioTTS 库关键 API

```swift
// ❌ TtsModels.download() 硬编码了 computeUnits，无法自定义
let models = try await TtsModels.download(.kokoro)  // 内部写死 .cpuAndNeuralEngine

// ✅ 绕过方案：直接用底层 API（都是 public 的）
let modelDict = try await DownloadUtils.loadModels(
    .kokoro,
    modelNames: ["kokoro_21_5s.mlmodelc", "kokoro_21_15s.mlmodelc"],
    directory: modelsDirectory,
    computeUnits: .cpuOnly  // ← 关键：可自定义！
)

// 包装成 TtsModels
var loaded: [ModelNames.TTS.Variant: MLModel] = [:]
loaded[.fiveSecond] = modelDict["kokoro_21_5s.mlmodelc"]
loaded[.fifteenSecond] = modelDict["kokoro_21_15s.mlmodelc"]
let ttsModels = TtsModels(models: loaded)  // ← 也是 public 的

// 初始化 TtSManager
let manager = TtSManager(defaultVoice: "af_heart")
try await manager.initialize(models: ttsModels)
```

### 实现要点

**LocalTTSService.swift**：
```swift
actor LocalTTSService {
    private var currentComputeUnits: MLComputeUnits = .cpuAndGPU
    private var isSwitchingMode = false

    func switchToBackgroundMode() async throws {
        guard currentComputeUnits != .cpuOnly else { return }
        cancelCurrentRequest()
        unloadModel()
        currentComputeUnits = .cpuOnly
        try await loadModelWithComputeUnits(.cpuOnly)
    }

    func switchToForegroundMode() async throws {
        guard currentComputeUnits != .cpuAndGPU else { return }
        unloadModel()
        currentComputeUnits = .cpuAndGPU
        try await loadModelWithComputeUnits(.cpuAndGPU)
    }
}
```

**PlayerViewModel.swift** - 生命周期监听：
```swift
NotificationCenter.default.addObserver(
    forName: UIApplication.willResignActiveNotification,
    object: nil, queue: .main
) { _ in
    Task { try? await LocalTTSService.shared.switchToBackgroundMode() }
}

NotificationCenter.default.addObserver(
    forName: UIApplication.didBecomeActiveNotification,
    object: nil, queue: .main
) { _ in
    Task { try? await LocalTTSService.shared.switchToForegroundMode() }
}
```

### 遇到的坑

1. **TtsModels.download() 不可用**：硬编码了 `computeUnits`，必须绕过
2. **模型路径**：FluidAudio 默认下载到 `~/.cache/fluidaudio/Models/kokoro`
3. **切换耗时**：模型重新编译需要 1-3 秒，进入后台时有足够时间
4. **状态管理**：切换时需先取消当前合成任务，避免冲突
5. **CPU-only 性能**：比 GPU 慢 3-5 倍，但后台播放可接受
