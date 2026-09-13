# AO3 iOS 正文恢复修复（2026-09-13）

本次只完成独立修复，供离线功能稳定后整合；不合并离线、不改版本号、不归档、不上传、不送审。

## 源码基线

- 分支：`codex/ao3-reader-recovery-20260913`。
- 基线：`5f863c4ba9692ab51c9cf1ee318cad63a17d2c92`（1.2.38 / Build 59 的发布整合快照），包含已验证的 `b6dd4d7` 祖先。
- `bash scripts/build-reader-more-integration.sh --check` 通过。
- 独立 `WebAssets/ao3-bundle.js` 随现有 WebAssets 文件夹资源打包；通用 `bundle.js` 与基线完全一致，SHA-256：`3b281ed480c60d82192b911bacee3cd8258487de2e899dca226f435520c920bc`。
- AO3 脚本 SHA-256 与真实页面源 HTML 哈希见 `verification-summary.json`。
- 独立脚本压缩后约 876 KB；依赖字符串的空白以转义形式保留，`git diff --cached --check` 通过。

## 原因与修复

AO3 首次访问会延迟展示条款提示，然后隐藏正文。原通用提取器会把可见的条款识别为正文；条款关闭后没有重新提取，原生 bridge 又只接受首次结果，因而朗读和点击跳读都不能回到章节。

1. AO3 专用提取器只收集章节正文，保留重复段落、短段和内联排版，不混入条款、摘要、作者注释或评论。
2. 条款提示存在时（包括尚未显示的延迟阶段）暂停正文管线，并显示完成网页提示的说明。代码不接受条款、不改同意状态、不显示被网站隐藏的正文。
3. 用户完成网页提示后，通过 DOM 状态变化自动提取、同步朗读/解读段落与点击坐标。迟到的提示、加载失败、切换章节会清除旧内容，防止继续使用上一份正文或音频。用户暂停与睡眠定时仍优先；正在播放的同章恢复到先前段落。
4. 新正文和旧消息用页面地址及文档标识区分。浏览器缓存返回时刷新标识并重建监听；同文新 DOM 只重绑坐标。
5. 在朗读/解读入口增加 AO3 内容就绪检查，覆盖播放栏、迷你播放器及延迟权限重试；新增两条提示的九语言翻译。

## 验证

应用内 XCTest 使用真实 `WKWebView`、正式打包脚本及 `WebReaderBridge`，同时挂接朗读和解读 VM。新增 7 项测试覆盖：显示/隐藏提示、自动恢复与重复段落点击、迟到提示及用户暂停、换章及错误页、同文 DOM 替换、无包裹文本、重复缓存返回、消息地址校验。

相关回归包括网页高亮、朗读权限暂停、连续朗读、阅读位置恢复、睡眠定时与 Google Books bridge。最终 117 项测试中 116 项通过、1 项按既有约定跳过（需要网络的 Play Books shell 测试），0 失败；新增 AO3 7 项全部通过。结果见本地 `AO3-and-reader-final.xcresult` 和 `final-regression.log`。

压缩打包后追加复验 AO3 7 项和网页高亮 5 项，12 项全部通过：`AO3-packed-bundle.xcresult` / `packed-bundle.log`。

对用户提供的三个真实网页，使用当天取得的完整章节 HTML/CSS，在 iOS WebKit 中复现条款遮挡及本地提示关闭，逐段比较提取文本与原章节 `<p>` 文本数组（归一化空白，保留次序和重复）。三个页面全部匹配：

| 章节 URL | 提示期间提取 | 恢复后正文 | 混入条款 |
| --- | ---: | ---: | ---: |
| https://archiveofourown.org/works/86539701/chapters/228985126 | 0 | 216 段 | 0 |
| https://archiveofourown.org/works/86539701/chapters/231697481 | 0 | 311 段 | 0 |
| https://archiveofourown.org/works/85592371/chapters/227434811 | 0 | 357 段 | 0 |

真实正文测试是本地页面回放，不是在用户设备上验证。未调用云端 TTS；验证范围为正文提取、原生数据交接、拦截与恢复、点击和高亮相关回归。AO3 网站网络错误（原调查中另见 525）仍需网站恢复，但错误页不会作为章节朗读。

压缩后最终脚本回放结果：`AO3-real-chapters-packed.xcresult` / `real-pages-packed-test.log`，1 个覆盖三个章节的测试通过，0 失败。

页面全文、截图、构建日志和 xcresult 仅保留本地诊断目录，不纳入源码提交。原始复现材料位于主工作树 `reports/ao3-ios-repro-20260913/`。本目录 `real-page-harness/` 和 `evidence/` 保存修复回放与截图；`verification-summary.json` 仅保存 URL、哈希与计数。

## 后续整合

待离线功能稳定后，挑选本分支的 AO3 修复到最终发布基线，重跑 AO3 与播放器回归，再按实际 App Store 状态选择版本和 Build。本次没有执行这些发布动作。

AO3 独立脚本可从 `WebReader` 目录运行 `npm run build:ao3`；在独立 worktree 中通过 `READOUT_DESKTOP_SOURCE` 指向现有 `readout-desktop/src`。正式产物应从经过审核的依赖源码构建，并保留本次正文回归。
