# 客户端播放连续性：定位、修复与发布边界

## 结论与证据边界

- Android 生产聚合中的 31 条 `tts_failed` 都来自 Android `1.0.45`、Global、`file`、`es`、`ef_dora`，且没有首段音频；它们属于同一个匿名安装产生的 31 个 reading session，不能写成 31 位用户。
- 这些 session 没有保存底层 Retrofit/Moshi/Base64/Media3 错误，也没有可与 TTS 网关日志连接的 request id。旧 direct gateway 在相邻窗口 `2026-09-05T23:49:45Z–23:53:30Z` 收到 70 条 Android `1.0.45` 请求并全部返回 HTTP 200，但无法证明哪几条对应该安装，也不能从 HTTP 200 推导“客户端已收到完整并播放成功”。证据为 `../direct-gateway/android-failure-window.json`。
- 当前固定、非用户的西语 `ef_dora` 探针返回可完整解码的 38,445 字节音频，时间戳和正文进度字段正常。它证明当前样本正常，不证明历史失败正文当时正常。证据为 `../direct-gateway/es-synthetic-probe.json`。
- iOS 生产聚合中，剪贴板事件在已有首音频、播放约 537 秒后以 `tts_failed` 结束；Kindle 事件在已有首音频、播放约 1,266 秒后以 `kindle_page_advance_failed/navigation/page_turn_failed` 结束。聚合没有更底层异常，因此下面修复针对已证实的客户端脆弱点，不把它们宣称为两个历史事件的唯一根因。

## Android 1.0.45 基线与修复

- 独立 worktree：`/Users/xuxuheng/Documents/.worktrees/CastReader-Android-tts-playback-recovery-20260906`
- 生产基线：`e74e5dc1e433cf98a644f8a724b00890e72faec9`
- 修复提交：`0663a5bf32c125df5c581346731477383a676169`

请求仍固定发送到所选区域的 `/api/captioned_speech_partly`，并保持 `stream:false`。Global 原有的 `tts.castreader.ai` 到 `api.castreader.ai` 技术回退仍限于 Global；CN 不新增境外回退。新逻辑只对普通预设音色做一次有界技术重试，且重试相同完整请求。克隆音色在进入该恢复逻辑前即被分流，原身份、额度与幂等路径不变。

`TTSResponse` 的 `timestamps`、`audio_format`、`duration` 现在按附属字段处理：坏时间戳元素被逐项丢弃，坏格式或时长降级为空，不再连带丢弃可播放音频。`audio`、`processed_text`、`unprocessed_text` 的合同保持严格；其中后两者如果类型错误，整次响应仍失败并重试，不能用错误的余文状态跳过正文。普通音色的 Base64 为空或无法解码时，会在任何音频入队前触发同一次有界重试；克隆音色不受影响。

验证：Global Debug 与 CN Debug 各执行 `TTSRequestContractTest` 5 项和 `PresetTtsFallbackPolicyTest` 7 项，均为 12/12 通过。覆盖坏附属字段保留音频/正文、正文核心字段仍严格、坏 Base64 重试、技术失败最多两次、取消不重试、401/422/429 不走技术恢复，以及区域不交叉。

## iOS 1.2.33 基线与修复

- 独立 worktree：`/Users/xuxuheng/Documents/.worktrees/CastReader-ios-tts-kindle-continuity-20260906`
- 生产基线：`e3bbe903c0bed886a53b3b0ba2c8240c4fe6b9d6`
- TTS 提交：`09dcb64b136cac25e7989718fb261ec6208e425e`
- Kindle 提交：`814030a62fe5f359c4dc896d30ba4d86f394f659`

普通预设音色对 408、5xx、选定网络错误、整体 JSON 解码失败以及入队前可判定的空/坏 Base64 做一次同区重试。401、422、429 不重试；克隆音色继续走独立的带身份、额度和 request id 的路径。时间戳逐项降级，坏 `audio_format`/`duration` 降级为空；音频与正文进度字段保持严格。终端分析只记录固定错误码，不把底层错误文案显示给用户。

Kindle 自动翻页失败后先连续观察当前 `visibleKey`。页面已经变化时，恢复当前可见页并继续同一个逻辑朗读 session，不再发第二个翻页动作。只有 Kindle bridge 明确返回 `dispatchCount=0` 时，原页面才允许一次重试；已发出或无法确认是否发出的动作绝不重发，避免延迟响应造成跳页。观察与再次捕获之后、激活新页之前，会复核原 Read/Explain owner、Read page session、模式、preload epoch、可见 reader surface、同步弹窗和是否已有新的播放；取消或用户上下文变化会静默放弃旧恢复，不覆盖新的用户操作，也不记录成技术播放失败。

验证：模拟器定向测试共 94 项通过，其中 `ServiceRoutingTests` 93 项、Kindle 页面证据合同 1 项；结果为 `/Users/xuxuheng/Documents/.worktrees/CastReader-ios-tts-kindle-continuity-20260906/build-playback-recovery/Logs/Test/Test-CastReader-2026.09.06_10-14-51-+0800.xcresult`。应用 target 在测试流程中完成编译。

## 上线边界

本轮没有部署、安装或发送 Android/iOS 包。服务端 direct gateway 的完整响应修复可以直接改善旧 Android 二进制；上述解析降级、同区客户端重试和 Kindle 页面恢复都需要新的客户端版本。现装 Android `1.0.45` 与 iOS `1.2.33` 不会因代码提交自动获得这些行为。
