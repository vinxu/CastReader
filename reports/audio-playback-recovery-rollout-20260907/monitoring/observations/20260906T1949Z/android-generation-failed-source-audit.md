# Android 1.0.46 (53)：19:49 UTC 心跳的 generation_failed 源码审计

这两条客户端失败继续计为失败。已定位该版本中 `generation_failed` 的唯一写入点：它覆盖当前朗读任务的网络请求、响应转换、Base64 处理和部分音频重新入队等异常，不能单凭这个错误码推断模型合成失败。正常 `CancellationException` 在该分支之前明确重抛，未发现“正常协程取消被普通 Exception 吞成这两条失败”的直接源码依据。

本次仅读取本地冻结 Git 对象、已有发行产物及本窗口脱敏报告；没有重新采集生产日志、查询 Play、修改应用或服务、部署、合成或复现设备操作。逐文件 Git blob、SHA-256、带原始行号的摘录和本地依赖字节码保存在 [source-evidence.json](/Users/xuxuheng/Documents/CastReader/reports/audio-playback-recovery-rollout-20260907/monitoring/observations/20260906T1949Z/android-generation-failed-source-evidence.json)。

## 发行身份与边界

- 已有正式上传记录绑定 `1.0.46 / versionCode 53` 到源码 `3fe41d62b9f0c1d699ba20e84aecb63fd970b33b`。实际归档 AAB 本次重新计算为 53,865,621 bytes，SHA-256 `8ed9ad2b03c6ae56ba246f17b5101e031236a75fe2daebab25a6f5f8e49ab7d2`，与提交回执完全相同。
- [提交回执](/Users/xuxuheng/Documents/.worktrees/CastReader-Android-kindle-feedback-20260905/build/google-play-release/play-submission-43.json) 在 **2026-09-06 17:38:35 UTC** 记录“审核中 / publiclyReleased=false”。这只能描述当时状态，不能据此断言 19:49 UTC 仍未公开。发行文档另记录过同一优化 payload 的 debug 签名模拟器安装；这也不能证明两条事件来自模拟器，不能把事件改成测试流量。
- 客户端上报版本/build 与上述发行版本相符；尚无该客户端实例的签名、安装来源或 artifact hash 证明。以下结论准确适用于该冻结上传源码，不能把版本号等同于实例的密码学身份。
- 独立 TTS recovery 提交 `0663a5bf32c125df5c581346731477383a676169` **不是** `3fe41d62` 的祖先。该分支新加的响应转换重试和细分 analyticsCode 不属于本次所审计源码；也没有把主工作树的后续修改当成已发布行为。

## 已有事件能够证明什么

使用 [mobile-new-failures.json](/Users/xuxuheng/Documents/CastReader/reports/audio-playback-recovery-rollout-20260907/monitoring/observations/20260906T1949Z/mobile-new-failures.json)，按既有匿名会话键关联：两次失败为同一匿名设备和同一内容会话，Android 1.0.46/build 53，Global，英文 PDF / preset 音色。失败行本身的语言/来源部分为 unknown；英文、PDF、preset 来自对应 `read_start` / `read_first_audio`，没有补造失败行缺失字段。

| 客户端发生时间 UTC | 会话内观察 | 能支持的结论 |
| --- | --- | --- |
| 19:00:27.241 开始 → 19:05:24.873 失败 | 3.037 秒首音频；失败事件记录 playbackSeconds=115 | 已播放后发生一次终止生成失败；不能称全会话从未得到音频。 |
| 19:05:31.473 resume → 19:05:31.492 失败 | 两事件相差 19ms；playbackSeconds=0，未见该会话首音频 | 再次开始后迅速遇到一次异常；不是同一个 read_end 的重复记录。 |
| 19:05:37.017 再次 resume | 2.3 秒首音频，随后播放里程碑持续，最终记录 1894 秒播放后于 19:43:37 关闭 | 之后恢复了较长播放；不追溯取消前两次失败。 |

19ms 是客户端发生时间差，不是已确认的 HTTP 请求时长。两条失败分别延迟 14.807 秒、8.188 秒到达服务端；不得将共同 received 时间当作真实失败同时发生。本窗口已确认的 7 条 Direct `no_response` 没有 19:05 近时项；本审计不将它们或 proxy `cancelled` 与这两次失败强行关联。没有匹配 TTS request/trace 键，服务器总体 200 成功计数不能为这两次客户端调用单独证明成功，也不能为它们单独证明失败。

## 唯一错误出口与取消传播

所有行号以下述冻结源码为准，文件路径位于发行 worktree；不可用更新后的其他 HEAD 替换行号。

1. [PlaybackController.kt:1276](/Users/xuxuheng/Documents/.worktrees/CastReader-Android-kindle-feedback-20260905/app/src/main/java/com/same/castreader/player/manager/PlaybackController.kt:1276)：内层 try 执行 `generateStandardTTS`，并在正常返回后安排下一段预取。**1286–1287 先重抛 CancellationException**；1288 才处理其他 Exception；1290 若 generation/content 已过期就退出。1310–1315 唯一写入 `FAILED / tts_failed / tts / generation_failed`。
2. 同文件 1333–1344：有效性由 playbackGeneration/contentId 判断；`ensurePlaybackWorkCurrent` 先 `ensureActive()`，再把被替代内容变为 CancellationException。2517 请求后 2526 再次检查。正常取消或晚到的旧响应不会因此进入普通错误出口。
3. 同文件 1979–2003：`requestTts` 虽然 catch Throwable，但仅把可解析的克隆结构错误转换，其他异常原样重抛；[CloneSynthesisFailure.kt:17](/Users/xuxuheng/Documents/.worktrees/CastReader-Android-kindle-feedback-20260905/app/src/main/java/com/same/castreader/data/remote/CloneSynthesisFailure.kt:17) 只接受 CloneSynthesisBlockedException 或 HttpException，不会把 CancellationException 转为克隆错误。此次会话为 preset。
4. 同文件 1818–1855：后台预取也先重抛 CancellationException。普通预取失败可留下 ERROR/已生成前缀，**此分支自身不记录 generation_failed/read_end**。
5. 冻结依赖为 Retrofit 2.11.0、OkHttp 4.12.0、Moshi 1.15.1、coroutines 1.8.1。读取本地 Retrofit JAR 的 `KotlinExtensions.await` 字节码，确认注册 `invokeOnCancellation` → `Call.cancel()`；没有借用不同版本库的网上示例。

HTTP 层的 IOException 不等于 Coroutine CancellationException。[TtsEndpointInterceptor.kt:114](/Users/xuxuheng/Documents/.worktrees/CastReader-Android-kindle-feedback-20260905/app/src/main/java/com/same/castreader/data/remote/TtsEndpointInterceptor.kt:114) 对未取消调用的网络错误可同区回退一次；127–134 对 `chain.call().isCanceled()` 为 true 的 IOException 原样抛出，不做回退。若有独立 HTTP 取消而 coroutine 仍有效，或网络失败以 IOException 到达当前任务，理论上仍可记通用失败；没有当前证据证明两次事件走了这个边界。已观察到的下游连接关闭也不能证明是用户主动点了取消。

## PDF 的结束、切换和恢复

[PdfReaderViewModel.kt:296](/Users/xuxuheng/Documents/.worktrees/CastReader-Android-kindle-feedback-20260905/app/src/main/java/com/same/castreader/ui/screens/pdfreader/PdfReaderViewModel.kt:296) 把 PDF 朗读交给公共 PlaybackController，并标记 FILE/PDF。1072–1088 的暂停/恢复使用 `togglePlayPause()`；它不是单独的一套网络生成器。

| 路径 | 冻结源码 | 与 generation_failed 的关系 |
| --- | --- | --- |
| 正常朗读完成 | PlaybackController 3078–3091 | 默认 SUCCESS/completed；PDF 的 onAllComplete 在 PdfReaderViewModel 137–139 仅更新阅读完成状态。没有正常完成直接改写 generation_failed 的分支。 |
| 文档切换 / 关闭 | PlaybackController 911–925、3097–3114；PdfReaderViewModel 1103–1110 | 写 CANCELLED/content_switched 或 content_closed，并先增加 generation、取消 TTS。不同于此次 FAILED/tts_failed。 |
| 切到解读、重播解读 | PdfReaderViewModel 450、500 → PlaybackController 3189–3197 | generation++、取消请求、清队列、暂停。受前述取消/过期保护，不直接记 generation_failed。 |
| 只按暂停键 | PlaybackController 3121 | 若正在播放，只暂停播放器，保留正在生成的任务。因此“先暂停，随后当前生成真的出错”仍可记失败；但本次没有操作记录证明发生过暂停。 |
| 更换音色 | PlaybackController 718–730 | 先使 generation 过期再取消、清缓存/队列；没有证据可把该正常切换当作本次失败。 |
| 未读完的尾部失败 | PlaybackController 1291–1309、2756–2777 | 保留已生成 segments 和剩余文本，标记 ERROR；已播前缀耗尽后暂停并保留当前段，等待重试。这能解释“有首音频和115秒播放后仍 read_end failed”。 |
| 再次播放 | PlaybackController 3158–3175 | 如果当前段 ERROR 且有尾文、已无排队音频，重新 loadParagraph，携带已完成前缀 ID；否则播放已有队列或重新加载当前段。没有直接重抛 `ParagraphTTSState.error` 的代码。 |

队列完成另受 epoch/contentGeneration/callback lease 校验（PlaybackController 2664–2676）；旧队列完成会丢弃。该保护说明不能只因发生过所有权切换就认定有失败。PDF 本次事件也不提供切换/点击的操作级证据。

## 服务器可以成功而客户端仍 generation_failed 的具体路径

| 可能路径 | 精确源码依据 | 现有证据的限度 |
| --- | --- | --- |
| 200 响应的客户端收体/JSON 转换失败 | [CastReaderApi.kt:49](/Users/xuxuheng/Documents/.worktrees/CastReader-Android-kindle-feedback-20260905/app/src/main/java/com/same/castreader/data/remote/CastReaderApi.kt:49) 为 suspend 返回 TTSResponse；[NetworkModule.kt:74](/Users/xuxuheng/Documents/.worktrees/CastReader-Android-kindle-feedback-20260905/app/src/main/java/com/same/castreader/di/NetworkModule.kt:74) 配 Moshi。读取 Retrofit parseResponse 与 Moshi converter 实际 JAR：在收到2xx后继续读取/转换 body，并可抛 IOException/JsonDataException。 | 在响应头之后发生的转换/收体错误不在 interceptor 的状态码回退范围；冻结 requestTts 没有转换后的有界重试。但没有这两次实际坏 JSON/截断体证据。 |
| Base64 处理失败 | PlaybackController 2532 `Base64.decode` 位于统一 try 内；[TTS.kt:24](/Users/xuxuheng/Documents/.worktrees/CastReader-Android-kindle-feedback-20260905/app/src/main/java/com/same/castreader/data/model/TTS.kt:24) audio 为必填字符串。 | 可在 HTTP200 后抛普通异常，不会产生服务端4xx/5xx。没有实际 audio 字节或解码异常，不能判定发生。 |
| 音频已生成，本地入队失败 | PlaybackController 2577 →1000–1013 → [AudioPlayerManager.kt:379](/Users/xuxuheng/Documents/.worktrees/CastReader-Android-kindle-feedback-20260905/app/src/main/java/com/same/castreader/player/manager/AudioPlayerManager.kt:379) → [AudioPlaybackService.kt:474](/Users/xuxuheng/Documents/.worktrees/CastReader-Android-kindle-feedback-20260905/app/src/main/java/com/same/castreader/player/service/AudioPlaybackService.kt:474)。479–480 同步写临时 MP3，495–504 同步 addMediaItem/prepare/play；没有在这里隔离异常。 | 例如文件写入或同步播放器调用异常会被标作 generation_failed，尽管模型已经返回音频。**没有磁盘空间、文件异常或 Media3 栈证据，不判定为磁盘满或播放器故障。** |
| 未请求新音频就重放前缀失败 | PlaybackController 2460–2467 采用 ERROR/STREAMING 且 voice/原文匹配、有已生成内容和余文的前缀；2491–2500 重新入队该前缀；2517 才发新的 HTTP 请求。 | 提供了“resume后19ms再次失败，无新的失败HTTP”在源码上可成立的具体路径。原 ERROR.message 仅作为状态保存，不被直接重抛；因此必须发生一次新的异常，不能说缓存错误本身自动再发了一次失败事件。 |
| 新网络请求立即失败 | PlaybackController 2517 →1987；interceptor 127–135。 | DNS/连接等可在到达源站前失败。19ms不足以支持“这次新请求等满8/30秒connect或60秒read timeout”，但无法排除立即失败；read_start发生在配额/服务就绪等检查之后（1208），不是用户点击或全部工作开始时间。 |

完全 READY 缓存的重放在 PlaybackController 1222–1257，位于内层 generation_failed try **之前**，不能把任何“缓存播放错误”都笼统套入这个错误码。能进入上述19ms候选的是内层 generateStandardTTS 中的部分前缀路径，或新的网络/处理异常。

缺失 timestamps 本身不会抛错：TTSResponse 时间戳可选；PlaybackController 2220–2260 退到句级显示。缺失 remainder 在 2287–2308 从 processedText/timestamps 推导，空 timestamps 在2313按输入完成；有效显式空 remainder 仍为完成。duration 检测异常在2178–2210被 runCatching 转为 null。因此，不能把 R134 的有效短静音/空时间戳或正常缺少 remainder 直接认定为这两次 generation_failed。底层异步播放器解码错误也不会自动穿过一个已经返回的生成协程；报告列出的播放器候选限定为该调用栈里的同步失败。

## 可确认结论与下一步边界

可确认：同一内容的两次真实客户端生成阶段失败，随后恢复；冻结源码的错误码过于宽泛，能覆盖服务器成功后的本地处理；普通协程取消和被替代任务有明确保护；19ms快速失败存在请求前的前缀入队路径，但没有原异常证据证明它就是本次原因。

不能确认：哪一次TTS请求对应两次失败、是否读体/JSON/Base64/文件/Media3错误、是否有独立HTTP取消、是否为R134回归。没有请求关联和异常类别，继续扩大正常服务器200日志也无法补齐客户端本地失败原因。后续如获授权，应优先获得客户端固定错误类别/阶段和匿名请求关联，区分 request、response_decode、audio_decode、cache_enqueue、player_enqueue；不需要导出原文、音频或用户原始ID。本轮不实施修改或额外采集。
