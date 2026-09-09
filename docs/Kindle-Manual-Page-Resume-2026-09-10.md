# Kindle 冷恢复后的手动翻页朗读回归

## 原因

2026-09-09 真机日志在 23:48:32–37 连续记录六次 `KINDLE user page gesture ignored ... active=N`。同一时间旧页面仍在输出词级高亮，页面已翻走后出现 `captured-page-not-visible`。之前同一进程的手动翻页能正常进入 `manual resume started`。

`KindleBookViewModel.startCurrentMode()` 先 `vm.activate()`，再在存在记忆点时调用 `ensurePlaying()`。这时 VM 已持有音频会话，恢复入口直接生成记忆段落，绕过了 `start()` 内原有的 `applyPlaybackMetadata()`。因此播放器的 `currentBookId` 仍可能为空或属于上一本内容。

Kindle 的手动翻页和页面监测依赖播放器的书籍身份。TTS 还在 loading/streaming 时另一个条件会允许恢复；进入 ready 后书籍身份不匹配就返回 inactive，造成“声音还在播放，翻页却不触发新页朗读”的时序相关表现。`7d15e3a` 加入 `hasPendingReadingResume → ensurePlaying()` 后扩大了这条旧的初始化遗漏路径；同样的预激活后 `jump()` 也受影响。

## 修改

- 在 `ReadAloudViewModel.ensureAudioSessionClaim()` 创建并接管新的音频会话时同步绑定播放内容。冷恢复、预激活跳读、重新接管播放都共用这个入口。
- Kindle 忽略手势的诊断增加书籍身份是否匹配、是否播放、是否恢复中、是否自动换页和当前页是否存在；不记录书籍正文或账号信息。
- 增加两个能够在修复前失败的真实 VM/音频回归测试，以及使用已授权 Kindle 书架的原生真机 UI 场景（冷启动续播、左右滑动、上下页按钮、连续滑动、最终暂停）。

## 验证

修复前两个回归测试均失败，播放器保留 `previous-content`。修复后相关 85 项测试全部通过（ReadingResume 56、KindlePageTurnEvidence 19、ReadAloudContinuation 7、ReadAloudEntitlementPause 3）。

版本 1.2.36（57.15）已安装到用户 iPhone。第一轮真机日志确认冷恢复后下一页和上一页均为 `resume=true`，分别在 1.82 秒和 2.23 秒内发起新页朗读，现场可见新页词级高亮。

原生手势测试的最终结果与脱敏日志见工作区报告 `reports/kindle-manual-page-resume-20260909/README.md`。此次验证针对本次 Kindle 回归，不代表重新执行所有平台的真机验收。
