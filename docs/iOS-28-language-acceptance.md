# iOS 28 语言适配与验收

工作树：`codex/ios-28-languages`；基线 `09456f1979cc14ca19977ede4b1edde043c5f840`。候选版本 **1.2.47 (72)**。本次为客户端实现和验收，不包含 App Store 上传、送审或发布。

## 范围与状态

Global 支持 28 语言；中国区保留原 9 语言。新增 19 语为 ar、cs、da、el、fi、fil、he、hu、id、ko、ms、nb、nl、pl、ro、ru、sv、tr、vi。

已完成 **114 / 114** 次三分钟播放，客户端验收完成。权威状态为 [acceptance-current.json](../reports/ios-28-languages-20261008/acceptance-current.json)，每种语言的实播秒数见 [播放矩阵](ios-28-language-evidence/playback-matrix.md)。每语种分别验证 Web、PDF、EPUB 的朗读和解读；每模式至少 180 秒实际播放，加载、暂停、重复循环及短试听均不计入。

使用已登录现有 Pro 的专用 iPhone 模拟器 `EC127445-7281-4C64-9417-8642E44F4039`，保持真实鉴权、服务和权益。小屏／iPad 布局另用临时无账号模拟器，完成后删除。未重置或注入真实账号、权益、额度，未覆盖用户真机。

## 实现

- 统一 28 语能力、音色目录、朗读／解读语言选择和持久化；未知或相近语言保持保守判定，提供明确的语言纠正入口。
- 本地语言识别与 OCR 能力按语言分配系统识别和补充模型；PDF 原文范围、EPUB 原生段落和网页正文保留同一朗读／标注定位链。
- App、Share、Widget、权限说明、快捷指令等 6 个字符串目录完成直接翻译，覆盖 28 语言；RTL、热切换及错误提示适配。
- Safari 扩展同步语言能力。远程目录尚未返回时，Global 仍能列出 28 语；CN 继续 9 语。98 个入包资源与独立扩展候选 `9baaaa9c3f29b493ffafff4d6f940be4d7f011ca` 一致。
- Global 音色页对齐已确认的 Android 行为：Explore／My Voices、独立浏览语言、按需搜索、少量常规音色直接展示、同源公开克隆完整池、私人／受赠音色先过滤再取最新 3 个。阅读器与完整 My Voices 保留完整授权库。详见 [音色页报告](ios-voice-tab-alignment-2026-10-09/README.md) 和 [逐项清单](ios-voice-tab-alignment-2026-10-09/acceptance.csv)。

## 验收中修复的问题

| 问题与最终行为 | 回归证据（相对报告目录） |
|---|---|
| 用户截图中的捷克语 PDF 跨行高亮过高、跟读位置过低：PDFKit 异常选择框按字体行高约束，保留准确字符范围，跟读下边界提前到可视高度 70%。 | `pdfgeometry117-regression`；4 项回归；`long119-cs-pdf/visual-review.json` |
| 音频切段缓冲时按暂停误判为播放：按真实播放意图处理，后到音频继续等待显式恢复。 | `pause107-regression`；2 项回归；`long108-ar-pdf-explain` |
| EPUB 中途恢复发生布局循环：相同富文本不重复赋值、相同高度不重复失效。 | `layout110-regression`；5 项回归；`long111-nb-epub` |
| RTL PDF 序号／星号方向错误、边缘裁切：按源语言方向和标记尺寸定位。 | `rtl122-pdf-regression`；6 项回归；`long124-rtl-pdf-explain` |
| 网页解读在定位正文中偏移、嵌套链接重复绘制：使用真实 SVG 坐标变换，合并同一行选中文字。 | `web133-mark-geometry`；3 项 WK 回归；印尼语 Web 181.82 秒 |
| 网页隐藏 CSS 被当作正文：使用可见文字与原 DOM 的可逆 UTF-16 映射，排除隐藏样式和脚本。 | `web135-malay-highlight`；4 项 WK 回归；19 个公开网页定位审计 |
| 长篇解读进入未预取的下一批后有音频却不播放：重置批次偏移、首块领取和计划状态。 | `explain136-batch-continuation`；2 项回归；挪威语 Web 184.22 秒、范围 0→10 |
| 暂停后换声、音频返回前点播放被旧状态覆盖：保留最新显式播放／暂停意图。 | `voice134-alignment/unit-resume.xcresult`；真实常规／公开／私人／受赠 Read 和 Explain |
| 最大辅助字号下德语名称截断、推荐区被固定横排撑出屏幕：文字纵向换行，推荐音色改为纵向行。 | `voice134-alignment/layout-final-narrow-fixed3`；`layout-final-ipad` |

## 其他验证与边界

- 28 语均有真实传输、解码和短播放证据；原有 9 语的真实朗读／解读主流程全部通过。这些不抵扣新增语种的 114 项长测。
- 38 份 PDF／EPUB 均经 iOS 原生解析，段落 ID 和 PDF 原文范围检查通过；36 份自动识别正确，印尼语／马来语两份保守返回不确定。经正常选择语言、重开保留后，各自朗读／解读三分钟通过；不把手选算作自动识别成功。
- 19 个真实网页分别完成默认移动布局和长测完整布局的导入检查；17 种自动识别正确，印尼语／马来语走已验证的明确纠正入口。导入测试未启动 TTS。
- 6 字符串目录 × 28 语覆盖及格式参数检查通过（`localization-final-delivery.json`）；这不等同于母语者发音／翻译逐条审校或完整 OCR 字错率认证。
- 早期完整隔离测试为 2,116 通过、14 失败、19 跳过，不能称为全量全绿。旧 9 语契约、目录 fixture 等后续定向复测及适用限制见 `historical-test-closure.json`；后续修复分别保存独立回归结果。
- 音色页 15 种 UI 语言截图、375pt 最大辅助字号 de/ar/he、iPad 最大字号和 3 项真实 WKWebView 视口契约回归已有证据。iPad 分屏拖拽及活动 mini player 截图未在最终这一轮重复，既有窗口／避让逻辑保留。

已知输入边界：原版波兰语 PDF 字体映射损坏会丢字，验收使用同语种真实正文制作并核对的 `pl-library-clean.pdf`；原文件和诊断保留。马来语 Bumi 中的独立 Jawi 词被服务端 Malay 音色拒绝，改用公开 Biologi 文章完成语言验收；未声称已修复该服务端混合文字限制。

Google 共享日预算曾阻塞测试。按用户授权，生产 `API_TTS_DAILY_CHARACTER_LIMIT` 已从 500000 调整到 2000000，保留当天用量；Google 和 4090 均已验证 HTTP 200、音频和时间戳。它是本方服务代码对 Google 线路的共享字符预算，不是 Vercel 账单预算；不影响 4090 线路。详见 `budget-incident-audit`。

## 候选构建与复跑

最新未签名 Release 编译通过，版本 1.2.47 (72)，16 个 DEBUG 验收标记均未进入正式二进制，网页脚本与已测源码逐字节一致。见 [Release 验证](ios-28-language-evidence/release-verification.json)、[源码摘要](ios-28-language-evidence/source-manifest.json)。基线祖先、Voice/TOC 集成和 Safari 入包检查通过。未签名产物没有上传或安装到真机。

```sh
# 仅在现有已登录的专用验收模拟器执行；自动跳过已通过项目。
/usr/bin/python3 scripts/run-ios-language-long-matrix.py

# 单个格式需使用新的报告目录。
CASTREADER_ACCEPTANCE_SIMULATOR=EC127445-7281-4C64-9417-8642E44F4039 \
CASTREADER_ACCEPTANCE_REPORT="$PWD/reports/ios-28-languages-20261008/new-check" \
CASTREADER_ACCEPTANCE_LANGUAGES=nl \
CASTREADER_ACCEPTANCE_FORMATS=web \
bash scripts/verify-ios-language-reading.sh
```

长测使用现有「深入」解读选项，逐个记录真实媒体时钟、暂停恢复、分段、字幕／标注及截图。脚本只通过正常设置关闭自动播放，不改变账号。勿在此真实账号上运行会改写 Pro 的完整单元测试。

此前逐轮问题、失败和复测记录完整保留在 [验收过程记录](../reports/ios-28-languages-20261008/acceptance-history-before-final.md)。不删除失败证据，也不把后续手工通过改写为早期自动测试通过。

交付证据摘要见 [acceptance-summary.json](ios-28-language-evidence/acceptance-summary.json)；114 项原始结果的摘要校验见 [matrix-evidence-integrity.json](ios-28-language-evidence/matrix-evidence-integrity.json)。交付前仅核对现有证据和源码，未重复已通过长测。
