# Mac 本地文档与真实阅读验证（进行中）

基线：iOS 1.2.47 / 09456f1。环境：Apple silicon，macOS 26.2。

## 已执行

- 真实用户账号及 Pro 月订阅已恢复；⌘Q 后新进程正常恢复同一账号，无登录墙。
- 系统导入缺陷复现：SwiftUI 原始 fileImporter 请求原地读写 sandbox extension，在只读 entitlement 下记录 FPSandboxingURLWrapper EPERM，没有交付回调。
- 新增 Catalyst 专用 UIDocumentPicker `asCopy: true`，iOS 保留原 fileImporter；正文/克隆音频两入口共享适配。没有扩大到读写权限。
- 实际从原生 Open 面板选择 `CastReaderTests/Fixtures/document-images/mixed-illustrations.pdf`；17 个段落，4 页，解析后进入 PDFKit 原文阅读器。源文件未修改。
- 点击真实朗读：`tts.castreader.ai` HTTP 200；AVPlayer timeControl=playing；逐段推进并自然完成；观察到扫描页橙色词高亮和随段落/词自动滚动。
- 切换 Explain 并启动真实国际解读：生成讲解，播放器完成两块讲解；字幕时间线推进；原 PDF 扫描页出现橙色手写圈注，滚动到标注位置；最后状态 Explanation complete。
- 以上证明真实服务/音频解码播放时钟/视觉反馈，不等同于已完成扬声器主观听音、全部语言与全部格式验收。

- Finder 冷启动打开 DOCX，审核导入后原始英文/中文图文进入 WebReader；真实 TTS 进度、高亮可见。EPUB 冷启动导入保留表格、PNG、SVG、标题；目录选中后返回对应段落并保持暂停。
- Finder 打开使用 Alternate 文件关联，不抢占用户默认阅读器；接入同一账号作用域的拖入审核队列。

## 自动合同

G03 首轮 77 项：76 通过，1 失败；旧网络隔离测试缺少 QuickRead 新版 cms 会话依赖（401），已注入仅供 URLProtocol 截获测试使用的私有 session provider。没有改动产品认证逻辑。

修正后 `g03-local-contracts-retry/summary.json`：77 PASS / 0 FAIL / 0 SKIP。覆盖旧 iOS 原用例：PDF 原文+扫描 OCR/坐标/取消和内存界限、EPUB 图像/SVG/目录/冷缓存、DOCX/TXT/Markdown/RTF/HTML 本地解析、恶意或损坏输入、拖入队列/账号边界。真实私有 EPUB/PDF 语料集用例未纳入，不算已通过。

iOS `g03-ios-build-retry/summary.json`：39 PASS / 0 FAIL / 0 SKIP。CloudImportIntegrationTests 原 iOS target 未注册，20 项未实际执行，已在隔离宿主补入，cloud-summary.json 记录另 20/20 通过。iOS 合计 59/59。

## 桌面输入与采集补充（23:12）

- 原生菜单：系统默认 Open 的 Command-O 与自定义导入快捷键冲突，UIMenuBuilder 拒绝了整个菜单。现替换默认 Open，保留 Open Recent/New Window，并移除没有实现的文档编辑菜单。实测 ⌘O 打开导入、Esc 关闭面板、⌘2 到文库；搜索框输入空格正常，⌘1 不打断编辑。
- 原生选择器还存在 sheet 释放早于 delegate 回调的问题。delegate 现由外层视图 StateObject 持有；修正后 Markdown 回调、解析 6 段、显示全文成功。同一进程连续导入 Markdown 6 段、TXT 4 段与 PNG 成功；损坏 PDF 明确提示文件可能损坏/加密/DRM，确认后可继续导入。
- Markdown：中英全文、标题、原文词高亮可见；空格启动真实 TTS 并暂停；18→20 pt 设置生效，完整原文和暂停位置保留。
- Mac 多页相机控制器已实现并接入 iOS 扫描回调：AVFoundation 本地预览/拍照、透视处理复用 ImagePreprocessor、撤销上一页、取消/完成、权限及不可用提示；采集与图像处理在串行后台队列，离开后停止。已实测无权限初始页和取消；相机授权已向用户提出，未收到允许前不启用摄像头。
- 相机/OCR 扩展合同首轮 137/138：真实 Vision 取消测试缺少测试包 PNG 资源。Mac 测试包现同步 iOS 测试资源，重跑 **138/138 PASS，0 SKIP**，报告 g03-camera-contracts-retry/summary.json。包含真实 Vision 取消后恢复识别，不以替身结果冒充。

## 阅读合同与多窗口补充（23:28）

- g04-reading-contracts/summary.json：**228 PASS / 0 FAIL / 0 SKIP**。在前 138 项上新增读取续播、权益暂停、音频所有权、讲解字幕、字号/主题/网页 Aa、睡眠定时的既有 iOS 合同。此结果早于后续窗口焦点补丁，不作为该补丁的自动测试证据。
- 公开合成图片 `Mac OCR sample.png` 从文件面板导入，显示原图，英文 OCR 5 段真实朗读至自然完成；截图观察到 `1894` 词框位置正确。样本尾部中文没有进入朗读，当前 iOS 源码 `recognizeImportedImage` 明确选择单一主语言进行最终识别；这次不能宣称混合语言全部识别。另需纯中文样本和 iOS 对照，不改动该共享语言选择合同。
- 多窗口发现并修正：两个 Catalyst UIWindow 可以同时声称 isKeyWindow，旧全局选取可能把 ⌘2 发到背后窗口。键盘改按实际事件接收 UIWindow 找对应 scene，应用级呈现通过最近的 didBecomeKey 记录聚焦窗口。实测第一窗 Library → 新窗 Home → ⌘3 新窗 Voice，Window 菜单同时保留 Library/Voice；切回 Library 后 ⌘O 在当前窗打开导入。

## 尚待执行

文本/图片的实际窗口导入与重开；EPUB 长篇恢复和 DOCX 扩展边界；Finder 打开及拖放、多窗口、快捷键；iOS 同样本对照；暂停/恢复、字号与缩放、语音切换/睡眠、断网失败恢复；最终签名 Release。后续记录逐项补充，G03/G04 不因上述部分通过而标记整体完成。

## 中文、摄像头与 iOS 对照补充

- 纯中文 `Mac OCR Chinese.png` 六行全部识别并朗读到自然完成（日志 `READ document finished para=5 readable=6`）；默认中文声音晓萱走 `tts.castreader.ai` HTTP 200，原图末句高亮对齐。国际版本保留中文内容能力。
- 同一轮共享用例在 iPad 模拟器执行 **220/220 PASS，0 SKIP**，报告 `g04-ios-reading-contracts/summary.json`（Mac 的 8 项发行约束不适用于 iOS）。
- 用户已明确允许相机本地预览。真实预览显示成功，取消返回首页；没有拍摄、保存或上传现场照片。实际文档拍摄和多页识别仍待用户准备样本，不将预览通过当作拍摄验收。
- Mac Upload Image 改为图片类型原生选择器；首轮选择后 Open 禁用但面板未完成，取消可恢复。此项仍在排查，不能记录为通过。

## 2026-10-05 阅读控制、声音及普通网页

- 图片入口第二轮从目录直接选择 PNG，真实 delegate 返回一个文件并进入原图 OCR 阅读器；首次 Go To Folder 选择停滞保留为间歇问题，不能归因于应用或工具而直接忽略。
- 实际选择 1.5x 后播放器显示 1.5x，已恢复 1x。睡眠定时 5:00→4:31→3:31，取消后 More 为 Off；到期暂停/不被迟到音频恢复由已有真实播放器测试覆盖。
- 搜索 Bella 得到 Bella/Isabella；Bella 试听状态为 playing，选择后正文声音从 Heart→Bella，正文真实播放。当前英文首选仍为 Bella，后续验收结束再恢复 Heart。
- `https://www.w3.org/History/1989/proposal.html` 真实加载保留原始图文，国际 TTS 自动推进、高亮 `short`、滚动可见；空格暂停通过。Explain 国际服务四块讲解、字幕推进，原网页标题/摘要橙色手写高亮，作者/CERN 圈注可见，末块音频自然完成。
- g13-window-contracts：232/232 PASS；新增聚焦窗口/辅助窗口干扰、活动音频移交与书签隔离。实际多窗口关闭移交尚未完成：系统菜单重复窗口标题使自动化无法稳定点选，不能用合同测试替代真实关闭场景。
- g05-voice-contracts：420/420 PASS，0 SKIP。新增音色目录/发现/克隆账号授权、上传音频预处理（真实 WAV/声道/时长）等已有 iOS 测试。
- 本机磁盘接近满盘，已清理本任务 17 个已结束的隔离 DerivedData 缓存，测试源清单和 xcresult 保留；空闲约 14 GiB。清理清单另存 build-cache-cleanup.json。


## 2026-10-05 音频导入本地验收补充

- 原生文件选择器分别导入 `Too short.wav`（1 秒合成音）、`Silent sample.wav`（7 秒静音）。前者显示至少 3 秒，后者显示未找到足够清晰连续语音；“重新选择文件”和取消均可恢复，原有播放器保持暂停。
- `say` 在本机生成 `Synthetic speech.aiff`，无个人录音。导入后选出 0:04–0:14 的 10 秒片段、9.5 秒有效语音、95% 覆盖；试听显示 Stop Preview，结束后恢复 Preview。未勾选声音授权声明，Create 保持 disabled；取消返回声音页。未上传样本、未创建声音、未消耗克隆额度。
- 麦克风录制、真实声音授权后的创建/删除/分享仍需适当验收样本，不能用上述本地预处理替代。
