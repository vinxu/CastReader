# iOS 播放器 loading 防闪烁修复（2026-10-15）

范围：在现有 bounded-preloading 候选工作树上修复播放器显示层，保留此前预加载、取消、额度和跨页修复。

## 原因与修复

1. Kindle 的 `KindlePlayButtonContent` 直接使用瞬时 loading 状态。每次 AVPlayer 换音频时，短暂等待都会立即显示转圈和提示气泡。现在复用 `ReaderDebouncedWaitingPresentation`，连续等待超过 **500 ms** 才显示；正常换段保持此前稳定图标。
2. 通用防闪烁组件原先分别监听播放状态和等待状态。真实 SwiftUI 挂载测试复现：进入等待时读取前一帧的等待标志，把瞬时 paused 保存为稳定状态，暂停键仍会闪成播放键。改为监听一个包含两个值的 Input，使用回调收到的完整新状态。
3. Kindle 横屏解读复用竖屏控制条的 compact 形态，避免独立路径用裸 ProgressView 替换按钮。
4. 显示延迟不参与播放控制。父级仍按实时状态处理暂停、取消和点击；等待结束立即恢复正确图标，不设强制 loading 最短展示时间。未改动音频生成窗口、请求队列、额度计量或高亮时钟。

## 验证

最终 `xcodebuild test`：**26 通过，0 失败**，包含：

- 真实 UIHostingController 挂载生产按钮：44 / 52 两种尺寸，各连续 3 次 180 ms 换段等待，换段截图和播放截图 PNG 完全一致。
- 初次加载与持续等待：短等待不显示 loading，750 ms 等待显示转圈及提示。
- 恢复与暂停：已显示的 loading 清除；取消的旧计时不会在下一次短跳段中显示。
- 原有播放控制、睡眠定时器、真实 AVPlayer 等待期间暂停、长段快速跳转、暂停后不继续预读、自然换页继续与显式暂停优先。

早期验证保留在报告目录：第一次挂载测试没有关联 UIWindowScene，截图不更新，不能作为有效界面证据；修正测试窗口后，实际截图发现上述第二个状态读取问题。最终测试未放宽截图比较，修复后使用完全相同的 PNG 字节比较通过。

证据：`reports/ios-loading-debounce-20261015/final.xcresult`、`final.log`、`test-results.json`、`attachments/manifest.json`、`pixel-verification.json`。集成基线和 Safari 配置校验通过。

## 本地交付

候选版本 **1.2.50（86）**，仅本地真机测试。测试运行时为 Debug 配置，随后仅提升统一 Build 号并构建 Release。最终应用源文件清单在 `source-manifest.json`，构建后再次逐项校验。之前安装的 85 版保存在 `iphone-install/previous-build-85.app`。

已覆盖安装到 iPhone 15 Pro Max（iPhone 66），回读确认 1.2.50（86），启动及进程存活检查通过，未卸载或清数据。真机安装和启动结果以 `reports/ios-loading-debounce-20261015/iphone-install/delivery-receipt.json` 为准。本轮不替代用户在真实书籍中的主观体验验收，也未提交 App Store。
