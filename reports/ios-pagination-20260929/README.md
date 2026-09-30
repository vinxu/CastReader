# iOS 四平台适配验收记录

本目录保存 Kindle、微信读书、Google Play Books、Kobo 的 iOS 分页、音频连续性、高亮与解读字幕迭代证据。代码以 `candidate-109.json` 对应源码为本次提交基线；1.2.48（71）只是开发包版本，不能把不同候选的测试结果混为最终验收。

## 当前结论

- 候选 109 已编译并安装真机，57 项字幕/语音回归最终通过。其中首轮 1 项遇到耳机移除与系统音频打断，源码未变的定点重跑通过；原失败结果仍保留。
- 单行字幕在微信读书、Kindle、Google Play Books 完成定点实播。对应 `live109-*-subtitles.json` 记录实际事件、时间戳质量和验证边界。
- 仍未通过四平台最终验收：微信读书有一条音频缺少原始词时间；Google 跨章节冷启动等待 8,543 ms；Kobo 真人验证阻塞；完整长时间测试矩阵尚未完成。
- 旧候选的失败与通过记录都保留，不因提交代码而改写为全部通过。详见 `../../docs/iOS-four-platform-final-acceptance-2026-09-29.md` 和 `../../docs/iOS-explain-single-line-subtitles-2026-09-30.md`。

## 日志与脱敏

原始 `.log` / `.gz` 留在本地验收目录，不提交。分析中的原始日志路径和 SHA-256 用于本地核验，不代表远端仓库附带原日志。临时 QuickRead 任务 capability 在可提交分析中替换成稳定散列标识；原件另存本地私有验收目录。脱敏不改动时长、失败事件或验收结论。

## 本次提交检查

- `bash scripts/build-voice-toc-integration.sh --check` 通过，发布祖先保持完整。
- `node scripts/test-weread-ios-contract.mjs` 与 `node WebReader/weread-native-resume-test.mjs` 通过。
- 候选 109 清单所有源码摘要与当前源码一致；额外生成的 `ao3-bundle.js` 与已构建真机包内资源一致。
- `git diff --check` 通过。本次仅保存及推送代码，不表示 App Store 发布或最终验收通过。
