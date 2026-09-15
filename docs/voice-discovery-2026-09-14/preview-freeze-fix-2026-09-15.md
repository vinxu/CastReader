# 专题试听卡死修复 · 2026-09-15

用户路径：Voice → Find your everyday voice → 点击试听。修复包已安装，真机人工复测结果待回读。

## 已取得的故障证据

- 原包 1.2.40 (61)，源码 271cf3b，安装目录 735B25DB-CA9D-436F-8F06-15744B74360A，PID 9552。
- `CastReader.cpu_resource-2026-09-15-111612.ips`：125 秒内消耗 90 秒 CPU，footprint 107.69 MB → 414.44 MB。
- 新取得的 `CastReader-2026-09-15-112905.ips` 确认同一安装目录、PID 于 11:29 被 scene-update watchdog 终止，10 秒无响应，EXC_CRASH / SIGKILL / 0x8BADF00D。
- 主线程具体链路：`UINavigationParallaxTransition` → `layoutBelowIfNeeded` → `HostingScrollView.PlatformContainer._updateSafeAreaInsets` → `UIScrollView.setSafeAreaInsets` → `setContentOffset` → `UINavigationController._observeScrollViewDidScroll` → 导航栏重新布局。此前 CPU 报告中的主要偏移也对应这些符号。
- 不是音频文件几百 MB：该专题 8 个样本 HTTP HEAD 为 86,829–107,949 bytes。没有把虚拟地址空间当作实际驻留内存，也没有声称定位了一个 AVPlayer 永久泄漏。
- 模拟器 iOS 26.5 原实现也能完成同路径；不能用它的正常结果否认真机 iOS 26.7 的 watchdog。

## 修复范围

1. 根音色页和专题页使用内容中的搜索框，移除两层原生 searchable 控制器。音色页的迷你播放器留白使用 scroll-content margins，不在每个导航页面再叠加 safeAreaInset。主 Tab 和阅读器代码保持当前基线。
2. 发现导航外层的错误提示原先观察整个 VoiceSamplePlayer。现在只订阅去重后的错误字段；头像和专题试听按钮只订阅该音色的播放状态。加载→播放采用一次状态变更，固定试听按钮尺寸。
3. 公开样本使用后台 actor 和 64 KiB 写入块；传输中检查 12 MiB 上限，检查 HTTP / MIME / 空响应。请求超时 15 秒、资源超时 30 秒。
4. URL 散列磁盘缓存，24 小时有效，完成文件预算 32 MiB；重复试听复用文件。取消、下载错误清理部分文件。保留现有区域 URL 解析、无 Cookie 身份及重定向规则。
5. 播放器有 10 秒准备超时；停止取消任务、观察者和 AVPlayerItem。旧请求及完成事件受 loadID 保护。离开专题时停止试听，现有正文播放所有权与恢复流程继续使用原协调器。
6. 仅 Debug 且启动参数 `-CastReaderVoicePreviewDiagnostics` 开启时，记录 CPU、physical footprint 和主线程心跳，最后一次试听操作 20 秒后结束。默认启动与发布构建不启用采样。

这些修改针对有证据的导航布局链路及不必要的刷新范围。没有声称通过逐个开关 A/B 实验唯一锁定了某一个 UIKit 控件。

## 验证

- `fix-tests.xcresult`：52 passed，0 failed，1 skipped。覆盖音色目录、发现推荐、试听缓存/取消/超限、中文搜索、精选克隆试听、收藏、多语言身份、1,606 音色搜索。
- `final-regressions.xcresult`：94 passed，0 failed。包括 KindleNavigationPositionTests、KindleReadingSettingsOwnershipTests、ReadingResumeTests，以及加强后的 everyday 专题测试（3 轮；切换、停止、播放中返回、回到推荐页确认停止，最后保留 5 秒空闲段）。
- 最后一轮模拟器诊断：32 次采样，约 31 秒；footprint 91.0 → 峰值 109.1 → 107.4 MiB；最后 4 次 CPU 为 0.7%、0.6%、0.7%、0.6%；心跳延迟最高约 0.01 秒。该数值仅代表本机模拟器，不是 iPhone 验收结果。
- `scripts/build-reader-more-integration.sh --check` 与 `--device` 通过。保留 64c2dbd、b6dd4d7 发布祖先，使用独立 DerivedData `/tmp/CastReaderVoicePreviewFixDevice20260915`。
- 修复包由 devicectl 于 11:53:55 安装到 iPhone 15 Pro Max；安装目录 **7D0145FA-90C7-4A1F-9503-06FF2F9FE75F**；Debug dylib UUID **BE88707F-CBFB-30CA-8B60-25366D716CF4**。
- 手机自动化未执行用例：Runner 9645 在建立 XCTest 连接前退出，code 74；随后 CoreDevice 调试连接中断、设备 unavailable。已向用户请求已安装版本的原路径人工复测，不能标记真机性能验收通过。

## 证据与回滚

本机诊断目录：`/tmp/castreader-preview-freeze-20260915`。包含原始 ips、构建日志、三个模拟器 xcresult、失败的手机 XCTest 日志、安装回执、模拟器性能日志及截图。

修复前应用源码：271cf3b。修复前真机包：`/tmp/CastReaderVoiceRegularPrimaryDevice20260915/Build/Products/Debug-iphoneos/CastReader.app`。尚未上传 App Store；本修复没有改变后台运营、目录 API、权益或计费规则。试听仍为已生成样本 GET，不调用生成 API、不扣生成额度。
