# 切换后部分场景停播：追加诊断与修复

日期：2026-09-15。应用源码 `a4a3ee0`，分支 `codex/mobile-voice-explore-20260914`。这是 `e573cde` 时间戳对齐修复之后的新边界问题，不能用上一轮用户反馈覆盖本轮停播。

## 真机证据

`/tmp/castreader-voice-switch-stop-20260915/reader-refocus.log` 与 `kindle-background-probe.log` 于 16:07 成功从 iPhone (66) 读取。

1. **16:06 页尾切换停播**：社区音色 `vl_d1efb23a380bdaa2f6b0` → `af_maya`。16:06:03 开始普通音色请求，16:06:04.013 返回 HTTP 200；16:06:04.030 成功定位新音频 5.069 秒，结束切换，但 16:06:04.206 `AUDIO ready … auto=N`，随后未进入 playing。
2. 此前 Kindle 日志显示音色面板于 16:05:47.011 打开。连续翻页已执行语义翻页，但 `wait-image-stable` 被 `.layoutRepair` 的面板保护拦住，反复重试/取消。16:06:02.249 到达下页音频 gate；16:06:02.295 取消 handoff 移除 gate，`isPlaying/isBuffering/isQueuedSegmentGated` 均为 false，实际播放请求仍存在。此时切换音色把短暂静音当成了暂停。
3. 报错 `Please choose an option in Amazon's cookie prompt first.` 是错误归因。该次 Kindle 会话最后的 Cookie 状态明确为 `hidden`；`requireReaderOperation` 原先把面板、Aa 与 Cookie 等所有拦截统一抛作 Cookie 错误。
4. **另一类服务失败**：16:04:42.796 从 `vl_3553117ace9560c74c4a` 切到 `vl_25c1e7df106ccaf499d0`，语言为英文。目录原始 ID `v_25c1e7df106ccaf499d0` 对应“李云龙”、中文来源。请求 `9E4F3701-462D-4CDE-AE9E-5038530802DD-0` 在 16:04:44.064、45.470、47.414、50.285 连续四次返回 503，最后正常退出生成并结束切换状态，没有可播放音频。

Vercel 生产日志也确认同一时段 `/api/voice-clone/captioned-speech` 的四个 503，部署 `dpl_5idvJLkC621dy88YNGbzRpgKQYAe`。请求 ID：`8b6ww-1789459483045-33a59b9e05eb`、`znq9f-1789459484643-4e0959aebda7`、`gjlb2-1789459486635-69847c07fb06`、`59hwt-1789459489514-7f913103940a`。结果保存在 `vercel-503.jsonl`；返回日志没有内部错误码/错误正文，不能据此断言是 worker、参考素材、对齐还是并发问题。该服务端失败尚未修复。

## 修改

- `waitForKindleImageStable` 使用 `.capture` 权限：读取已渲染的页面稳定性可在音色面板打开时继续；真正的布局修改仍由 `.layoutRepair` 门控，Cookie 和 Aa 阻断仍有效。
- `AudioPlayerService.hasPlaybackRequest` 暴露已有传输请求意图，同时排除用户暂停、系统中断和终态播放器失败。朗读切换在自己持有队列时据此决定是否继续播放，避免 gate 被撤销后丢失播放意图。
- 阅读管线按实际 Cookie 状态选择错误，其他临时阻断返回已有 busy 错误；诊断日志记录具体阻断来源。
- 克隆失败日志新增稳定服务器错误码、音色 ID 和请求 ID，便于后续定位上述 503；不记录朗读文本、响应正文或凭据。

## 验证与安装

- 修复前：3 个针对性测试中 2 个按预期失败——面板下稳定观察抛出 Cookie 错误、页尾 gate 撤销后新音频保持暂停。显式用户暂停的保护测试通过。证据 `/tmp/CastReaderVoiceStopRed20260915.xcresult`。
- 修复后：同 3 个测试通过，证据 `/tmp/CastReaderVoiceStopGreen20260915.xcresult`。
- 模拟器 131 项回归按组通过：主轮 100 项播放/续读/暂停/失败恢复/睡眠定时通过；Aa/面板组先有 1 个测试的 2 条旧断言仍要求 Cookie 文案，更新为无 Cookie 时的已有 busy 提示后，31 项完整重跑通过。证据 `/tmp/CastReaderVoiceStopRegression20260915.xcresult`、`/tmp/CastReaderVoiceStopSettingsFinal20260915.xcresult`。
- 真机 6 项全部通过：真实 WK 页面稳定观察与 viewport 保持、真实 AVPlayer 页尾 gate 撤销后的自动续播及显式暂停、三类音色往返、快速连续切换和失败重试。证据 `/tmp/CastReaderVoiceStopDeviceFinal20260915.xcresult`，16:22:46–16:22:59。测试使用本地可控页面/TTS，不代表“李云龙”的生产合成通过。
- 基线脚本 `scripts/build-voice-toc-integration.sh --check/--device` 通过，保留音色发现、EPUB TOC 及发布祖先。
- iPhone 安装完成并在 16:23:52 正常启动；版本仍为本地 `1.2.40 (61)`。Debug dylib UUID `49C29AD6-C519-31AC-BC6E-C45D382050B7`。回执 `/tmp/CastReaderVoiceStopFinalInstall20260915.json`、`/tmp/CastReaderVoiceStopFinalLaunch20260915.json`。

当前剩余项：上述特定音色英文合成的 503 根因与修复；新版真实 Kindle 跨页加选音色的用户复测反馈。不得将本报告写成所有音色 / 所有网络场景验收完成。
