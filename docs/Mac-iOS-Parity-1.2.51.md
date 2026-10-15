# Mac 1.2.51：iOS 迭代对齐与验收

日期：2026-10-16，北京时间。当前为验收中的候选，发布状态以本报告最终回读为准。

## 基线与范围

- 商店 Mac 1.2.48（76）已于本轮只读查询确认为 READY_FOR_SALE；对应源码 `f4bb0464`，发布记录提交 `b0fbc157`。
- 本轮从最新远端 main `7ba153670535ef14ca4c75d237abeced01c0f731` 增量建立 `codex/mac-ios-parity-20261016`，包含已整合的 Mac 适配、iOS 1.2.49 和 1.2.51 修复。
- Mac 正式 App / Share / Widget 为 1.2.51（88）；线上验收候选为 1.2.51（87）；iOS App / Share / Widget / Safari 保持 1.2.51（86）。Mac 仅国际线路，原生 Mac 与 Safari 独立宿主保持各自安装身份。
- 不整文件覆盖旧 Mac 分支。最新主线的应用源图已经包含共享生成控制；本轮实际发现的遗漏是 Mac scheme 没有选中新增关键回归，以及工程保护脚本仍检查旧 iOS 图。

## 审查与对齐

| iOS 已修复的问题 | Mac 候选实现与适配 | 验收入口 |
| --- | --- | --- |
| 暂停时仍持续生成付费音频；多份预读各自占用预算 | 复用 `SpeechGenerationControl`，前台、相邻页、解读待播音频统一计量；暂停取消在途请求，继续时保留逻辑请求身份 | SpeechGenerationControlTests、ExplainGenerationControlTests、SpeechPipelineTests |
| 未来页占满预算导致当前页断粮 | 当前可听队列不足时允许有所有权检查的补充；未来预读仍计入预算，不绕过暂停或串行请求 | 真实 HTTP/播放器控制回归 |
| 等待中暂停、暂停后换声、快速跳转出现旧音频或无法继续 | 保留生产者与精确后缀；过期响应不得进入新队列，暂停换声不显示永久加载 | ReadAloudContinuationTests、ExplainGenerationControlTests、AudioPlaybackOwnershipTests |
| 段落交接时播放按钮与 loading 闪烁 | 统一状态快照与 500 ms 显示延迟；延迟只影响展示，不延迟暂停或取消 | ReaderPlaybackLoadingViewTests、ReaderPlaybackBarLayoutContractTests |
| 四书源跨页、后台翻页与迟到确认导致停播或跳页 | 保留 Kindle 跨页整句、来源定位、已确认页继续、Kobo 无动画精确翻页、WeRead/Google 页所有权 | PaginationContinuityTests、Kindle / Google / Kobo / WeRead 套件 |
| 改窗口尺寸或返回阅读器后丢位置、重新生成或破坏高亮 | 完整音频与播放时钟保留；隐藏阅读器不因主窗口变化提前重排；用户暂停优先 | MacWindowRoutingTests、ReaderViewportTests、ReaderAppearanceTests |
| 深色 PDF 高亮不可见；EPUB 小封面缓存污染大图 | 继承普通混合色高亮绘制、像素预算分离缓存和当前显示比例 | ReaderViewportTests、DocumentImagePreservationTests |
| 流式音频导致正文缩短、段落跳动 | 完整原文持续排版，流式高亮严格投影到原文，不用猜测字符偏移 | ReaderViewportTests、ReadingResumeTests |
| iOS 新活动与账号/额度流程 | 共享活动、语言、账号及服务端权益规则；Mac 继续保留自己的侧栏、Finder/多窗口与逐句请求策略 | StudyBoostTests、MacDistributionTests、ProStatusSynchronizationTests、QuotaTwoTierTests |

30 秒为停止预读水位，10 秒及以下恢复补充；一次在途请求及解读完整标注单元允许有界超出，不能宣称绝对不超过 30 秒。Mac 保留自身已验收的逐句规划，未把 iOS 的设备折叠 UI 或手机导航结构照搬到桌面。

工程校验新增三组件版本一致性、Mac scheme 与维护清单一致性及六组关键播放回归必选检查。基线提升至 iOS 1.2.51，严格保护 iOS 原图与扩展。另修复 macOS Bash 3.2 在 `set -u` 下展开空筛选数组、导致完整测试在启动前退出的问题；完整与筛选执行均使用同一入口。新增的测试套件使用独立应用 ID、Keychain 和 App Group，不清除正式账号或书架。

## 验收记录

执行证据位于 `reports/mac-ios-parity-20261016/`。以下项目在实际完成后更新，不以计划代替通过：

- 重点隔离回归：231 PASS / 0 FAIL / 2 SKIP。跳过的是需显式提供的捷克语和芬兰语外部 PDF 样本；PDF 深浅色、高亮投影与布局回归均通过。
- 完整 Mac scheme 回归：2,044 PASS / 0 FAIL / 4 SKIP（共 2,048）。跳过为 Google Books 外网 shell、捷克语/芬兰语外部 PDF、显式启用的 YouTube 在线提取。首个完整入口因 Bash 空数组在启动前退出，保留 `full/` 记录；修复后 `full-r2/` 是单次成功完整运行。
- 正常签名应用国际/英文朗读与解读 × 常规、社区、私人声音：六项 PASS。Bella、Morgan Freeman by Tims、既有 Mac QA 私人音色均有新生成 HTTP 200、AVPlayer 实际推进、字幕/高亮及自动下一段或下一块证据。原文标注可见，讲解共 8 块。
- 升级保留正式账号、Pro、四书源书架与旧阅读记录。窗口从 1024×610 放大至 1726×925 时解读继续，暂停后恢复尺寸仍保持暂停。Kindle 原位置朗读与暂停、Google Books 恢复/逐词高亮/等待中暂停通过。Kobo 官网真人验证待处理；微信读书实际页面提取、中文 TTS、逐词覆盖与段落推进通过，但当前为公开版权页且页面显示登录，本轮不声称完成已登录书库跨页验收。Kindle 手动下一页未取得新的页指纹，本轮不把该动作列为实机跨页通过，跨页回归证据来自完整测试套件。
- Release 签名、架构、本地化与夹具排除：待执行。
- App Store 上传、29 语言更新说明、原截图保留和送审回读：待执行。

首次新 QuickRead 计划请求发生超时，正常 UI 显示错误及重试入口；重试生成成功后完成实际讲解、标注与跨块推进。保留该失败尝试，没有更改服务、超时参数或使用假讲解规避验收。核心证据为 `live-core-observations.json`，含账号或书籍细节的完整运行日志仅本机保留。运行验收使用 Apple silicon；Intel 仅进行通用架构构建检查，不宣称 Intel 实机测试。

发布前发现并发 iOS 1.2.52（87）已上传。已核对 `aa630c4a` 相对本轮主线只有 iOS 四组件版本/构建号变更，无应用源码差异；Mac 正式构建递增为 88，防止平台间构建号混淆。核心验收候选 87 与正式 88 的应用源码必须保持逐文件一致，正式归档另验版本与签名。

## 商店资料

以本轮读取的现行 Mac 商店文案为基准，仅更新 29 个语言条目的 What's New；本地意图文件为 `store/app-store/mac-1.2.51/asc-metadata.json`。已快照当前标题、副标题与原截图。价格、商品、地区、隐私、法律声明及其他平台不属于本次修改范围。
