# Kindle 手动位置与续播冲突修复（2026-09-10）

## 问题与原因

用户截图中，Kindle 的“Most Recent Page Read”对话框选择完成后，CastReader 仍提示旧位置无法恢复并拒绝播放。

1. `KindleListeningAnchor` 只在确认音频实际播放时写入。暂停时手动翻页没有成为新的恢复依据。
2. 同步弹框原来只有 Yes 放弃旧朗读页面恢复；No 仍可能触发旧页恢复，覆盖用户刚刚选择的当前页。
3. 新页加载的 `ReadAloudViewModel` 会校验旧 History 词级记录。不匹配会生成 `resumeNotice`，Kindle 的 Play 遇到该提示直接返回 deferred，造成没有继续按钮可以解开的阻塞。
4. 本轮补充的真实 WKWebView 延迟翻页测试发现：滑动后只等待两个相同画面，会在 Amazon 仍显示旧图时提前确认位置。两项测试修改前失败，修改后通过。

## 最终行为

- 手动上一页、下一页和横向滑动都先持久化新的导航意图；无需播放音频。
- 新页面有变化并稳定后，保存页面键、像素指纹、可用的进度标签与 URL。OCR 文本 hash 在已有识别结果时补充，不为保存进度额外整页 OCR。
- 导航 UUID 使较早的页面回调与旧朗读回调无法覆盖较新的选择；账号存储代际检查阻止旧阅读器向切换后的账号写入。
- Yes 和 No 都是明确选择：Yes 采用 Kindle 选中的云端页，No 保留当前页；之后不再强行应用旧的 CastReader 词级记录。
- 旧词级记录无法定位时，点击 Play 从当前可见页开始，撤销这一次无效恢复，不再用底部错误提示阻断朗读。其他内容类型的精确恢复行为不变。
- 新页产生真实音频进度后，导航记录由该页的精确朗读记录接替；浏览不会虚构朗读时长。
- 冷启动优先检查尚未播放的导航记录；像素相同即恢复，不依赖每次重开会变化的临时页面键。不同画面时采用有界邻页查找；选择同步弹框或再次手动导航会取消旧恢复。
- Amazon 自己的云端位置冲突框仍可能出现。本修复保证选择完成后能读所选页，不宣称关闭 Amazon 的同步功能。

## 验证

最终模拟器集成与单元测试 94 / 94 通过：

| 测试组 | 数量 | 覆盖 |
| --- | ---: | --- |
| KindleNavigationPositionTests | 7 | 导航持久化、旧回调拒绝、账号边界、Yes/No、先 Play 后选择、旧记录失配仍能实际播放、暂停滑动 |
| KindlePageTurnEvidenceTests | 21 | 双向真实画面证据；新增延迟 900 ms 换页和连续反向滑动事件测试 |
| KindleInitialStartSyncTests | 10 | 同步弹框与初始播放时序 |
| ReadingResumeTests | 56 | 通用续播、精确词级记录及 Kindle 播放所有权 |

结果包：`/tmp/Kindle-Navigation-Position-Final.xcresult`。
新增延迟滑动测试通过 WKWebView 的 touch 事件监听器和生产 JS 运行；属于浏览器事件测试，不代表物理手指滑动已复测。

iPhone 15 Pro Max，实际 Amazon 登录会话，1.2.36 (57.16)：

- No：00:35:35 选择；00:35:37 新位置确认；00:35:52 起生成实际音频进度，屏幕词高亮推进。
- 暂停后下一页：00:36:14 `resume=false`，新位置 UUID `546A882F` 及页面指纹已保存，未自动发声。
- 关闭阅读器、终止进程并重启：未按 Play 前即可看见同一页；00:37:41 确认相同 UUID、`restored steps=0`。临时页面 key 改变不影响定位。随后朗读该页成功。
- 暂停后上一页：00:38:09 `resume=false`，更新导航记录。Amazon 随后出现 1892 → 1906 的真实同步框。
- Yes：00:38:43 选择；00:38:45 确认新位置；00:39:06 为所选页建立朗读会话，实机观察到高亮与后续播放正常。

最新 Debug 1.2.36 (57.17) 包含延迟滑动修正，签名构建及真机安装成功。最终包的实机冒烟结果见报告补充。

## 文件与范围

修改 `KindleModels.swift`、`KindleLibraryStore.swift`、`KindleWebScripts.swift`、`KindleBookView.swift`；新增 `KindleNavigationPositionTests.swift` 并注册 Xcode 工程，扩展 `KindlePageTurnEvidenceTests.swift`。

本 worktree 保留此前 PDF/EPUB 本地解析缓存、统一进度及上一轮 Kindle 音频所有权修复；未覆盖原主目录中其他工作，未执行发布、push 或新的 commit。

## 尚未覆盖的边界

- iPhone 镜像的横向滚动没有可靠地产生原生 touch 手势，因此不把它列作物理手指滑动通过；该链路以真实 WKWebView 事件测试加原生消息测试覆盖。
- 未穷举阅读字号变化、极慢网络超过采样窗口、数十页之外的云端位置分歧；此次实机冷重开验证的是同一字体与同一设备的手动邻页。
- 不将本次 Kindle 修复测试表述为所有书架平台已重测。

## 最终包实机补充

1.2.36 (57.17) 已在 iPhone 再次完成：暂停状态点下一页 → 退出阅读器 → 终止进程并冷启动 → 重新打开，画面仍为刚才手动翻到的页；本次 Amazon 再次出现位置同步框，选择 No 后点击 Play 正常播放该页，词级高亮持续推进，没有旧位置失配提示或播放阻挡。验证后已暂停。对应脱敏事件见 `device-57.17-navigation-events.log`。
