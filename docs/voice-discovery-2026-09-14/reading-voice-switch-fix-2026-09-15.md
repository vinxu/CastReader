# 朗读中切换音色卡住：修复与验收

日期：2026-09-15。应用源码：`e573cde323227ecee152cffce9993731ee241dd7`。
工作树：`/Users/xuxuheng/Documents/.worktrees/CastReader-mobile-voice-explore-20260914`，分支 `codex/mobile-voice-explore-20260914`。

## 结论

已修复本次日志中“克隆切常规音色，API 返回成功，但播放队列为空、切换中不结束”的链路。已安装到 iPhone (66) 并于 16:02:13 正常启动。仍保留音色发现 `633f6bb`、EPUB TOC `ad4b885` 和发布祖先 `64c2dbd`。

这里的真机验收使用可控 TTS 输出、真实 AppSettings → ReadAloudViewModel → AVPlayer 路径，确定性覆盖问题分支；不是声称已完成生产 API 的所有音色、网络或长时间压力验收。真实文章 / 生产请求的用户复测反馈另外记录。

## 根因与变更

- 日志中的两次独立失败分别为 14:48:39 社区音色切 Nicole、14:59:34 社区音色切 Puck。新音频分别在约 2.4 秒和 0.9 秒返回；新旧 processed text 哈希一致，时间戳可完整映射，但原来的词边界匹配拒绝拆词 / 合词变化。
- `ReadingResumeContract` 现在先保留原有音频身份、同词时间比例与句级恢复策略；当引擎把同一个词切成不同的时间戳单元时，验证完整前缀和目标词哈希，再验证目标范围有连续的时间戳覆盖。成功后从首个覆盖该词的时间戳开始，最多回读当前对应的时间戳单元，不套用旧音频秒数。
- 新书签增加可选的语义词 UTF-16 长度。旧书签通过原始前缀、范围长度及完整词哈希恢复，兼容已保存的失败位置。文字变化或缺少目标时间戳仍拒绝猜测跳读。
- 切换事务通过统一的匹配 ID 收尾函数和生成任务 `defer` 结束；同步早退、生成失败、无法对齐、取消均不再留下全局“切换中”。新音频已可用时及时收尾，旧任务不能清除新任务状态或放回旧音频。
- 对齐失败后，显式点播放或另选音色可重新请求同一个已验证的书签位置。无法确认文档位置的保护保持不变。
- 失败时不再把尚未通过续读对齐的下载片段当成可播放队列前缀；用户在等待中暂停，最终入队也保持暂停。

## 验证

1. 修复前的确定性复现：同样的 `We can't wait.`，旧词 `can't` 与新词 `can` / `'t` 导致 `.waiting` / `.unavailable`；真实 VM 请求已返回却无法入队。2 个测试按预期失败（8 条断言）。证据：`/tmp/CastReaderVoiceSwitchRed20260915.xcresult`。
2. 模拟器回归：ReadingResumeTests、VoiceCatalogTests、EpubNavigationTests、ReaderViewportTests 共 114 项，113 通过，1 项可选 EPUB 本地语料测试因未设置 `CASTREADER_EPUB_CORPUS_DIRECTORY` 跳过。证据：`/tmp/CastReaderVoiceSwitchRegression20260915.xcresult`。
3. 播放器与发布功能回归：ReadAloudContinuationTests、AudioPlaybackOwnershipTests、AudioPlaybackFailureRecoveryTests、AudioStreamingPauseIntentTests、ReadAloudEntitlementPauseTests、KindleNavigationPositionTests、KindleReadingSettingsOwnershipTests、PlaybackSleepTimerTests、WeReadOpeningPlaybackTests 共 89 项通过。证据：`/tmp/CastReaderVoiceSwitchPlaybackRegression20260915.xcresult`。
4. iPhone 15 Pro Max 真机 8 项全部通过（16:01:11–16:01:22）：
   - 播放中克隆切常规音色；暂停中切换；等待新音频时暂停。
   - 快速连续切换，旧请求晚到的音频与完成回调均无效。
   - 内容对齐失败、再选音色、网络失败、显式重试恢复。
   - Kindle 中社区 → 常规 → 自己录制 → 常规 → 社区 → 常规连续往返。
   - 拆词 / 合词、流式跨片段、旧书签、中文、Unicode、标点归一化与缺失时间戳保护。
   - 证据：`/tmp/CastReaderVoiceSwitchDeviceFinal20260915.xcresult`。

首次真机轮次 6 项通过、1 项测试失败：手机 2 倍速继续播放影响“当前时间”断言，且测试在书签异步写入前断言存在。测试随后改为等待实际书签，并检查已有首个恢复播放 tick 的位置；应用源码未因此修改。最终保留手机的 2 倍速设置，8 项通过。

## 安装与来源

- 版本仍为本地迭代 `1.2.40 (61)`；版本号不作为源码证明，未上传 App Store。
- `bash scripts/build-voice-toc-integration.sh --check` 通过，最终 HEAD 为 `e573cde` 且代码无未提交补丁。
- 构建：`CASTREADER_DEVICE_DERIVED_DATA=/tmp/CastReaderCloneLatencyDevice20260915 bash scripts/build-voice-toc-integration.sh --device`。
- 应用：`/tmp/CastReaderCloneLatencyDevice20260915/Build/Products/Debug-iphoneos/CastReader.app`。
- `CastReader.debug.dylib` UUID：`AEEEAD7C-5CD5-3CEB-9764-B7093BA86652`。
- 安装、启动回执：`/tmp/CastReaderVoiceSwitchFinalInstall20260915.json`、`/tmp/CastReaderVoiceSwitchFinalLaunch20260915.json`。
- 真机日志副本：`/tmp/castreader-voice-switch-fix-20260915/`。书签和账号未清空，测试文档使用独立临时 HistoryStore。

云端首次合成的正常等待时间不由此修改；本次消除的是音频返回之后对齐 / 状态清理造成的停滞。

## 正常启动后的真实朗读日志

16:04:07 成功回读 `Documents/reader-refocus.log`（本地 `device-reader.log`），观察到实际 Kindle 文章的一次生产请求切换：

- 16:03:50.659 当前段重新生成。
- 16:03:55.512 克隆音频请求返回 200。
- 16:03:55.566 同一段恢复到新音频 2.457 秒，切换事务结束。
- 16:03:55.669 AVPlayer 进入 playing，16:03:55.797 记录首个真实播放 tick。
- 16:03:59.651 当前段播放完成，此后继续推进第 6、7、8 段；日志截至 16:04:05.076 仍在 playing。

这段真实日志说明此次切入克隆音色后，音频返回到继续播放约 157 毫秒，未出现原有“返回成功但空队列”的停滞。克隆切回常规及连续往返的确定性真机验收见上方 8 项测试。用户主观复测结果截至记录时尚未回复。后续两次追加日志复制因设备传输 socket 关闭失败，没有将失败传输当作新的运行证据。
