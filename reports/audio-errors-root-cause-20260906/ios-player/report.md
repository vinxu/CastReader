# iOS build 53 播放失败代码归因

审阅日期：2026-09-06。已发布基线：`e3bbe903c0bed886a53b3b0ba2c8240c4fe6b9d6`（1.2.33 / 53）；比较目标：`47f9541a0a9d08ff9d415a1692005b2d81c35eec`。所有行号均指基线，除非注明提交。只读取应用代码；报告目录内保存离线探针和夹具。未安装应用、未合成生产音频、未修改应用源码。

## 结论

这两条 `read_end / audio_playback_failed / player_item_failed / player` 能证明当前朗读拥有者收到了播放器错误回调，不能确定是 AVPlayer 解码错误、文件缺失、准备超时还是写磁盘失败。现有生产遥测抹掉了这四种入口之间的差异，也未携带底层 NSError。因此目前不能把两次事件归因于模型、网络、音频格式或系统清理临时文件。

确认存在两个相关客户端缺陷：

1. 已发布版本仅检查 Base64 是否能解码，空音频和合法 Base64 包裹的非音频内容可进入播放器。离线 AVFoundation 探针确认这些输入使 AVPlayerItem 失败。`09dcb64` 只补上预置音色的空字节检查；不验证非空字节是否可播放。**没有证据证明这两个事件的响应包含上述内容。**
2. 播放器失败后，仍在运行的 TTS 生成回调可把 VM 的 `.error` 覆盖成 `.streaming` / `.ready`；失败的 AVPlayerItem 则保留。此时播放按钮可能失去原本的重新生成分支。这是代码中可达的恢复缺陷，不能反推最初失败的触发器。三个后续提交均未处理。

## 两条会话的解释边界

会话事实来自上级调查保存的 `../client/session-evidence.json`，不是本探针生成。

| 事件 | 已知上下文 | 正确解释 |
|---|---|---|
| 2026-09-06 13:59:43.618Z | Kobo onboarding，en / af_heart；13:59:34.096Z 开始；13:59:36.435Z 首音频；累计 playback_seconds=0 | 开始到失败 9.522 秒、首音频到失败 7.183 秒。首音频不等于已证实听到声音。若播放器按正常新会话顺序建立，12 秒准备超时与该总时长不相容。空的第一个音频会在 ready 前失败，单凭空音频探针不能复现这条完整时序。 |
| 2026-09-06 14:16:31.236Z | 历史 EPUB，en / af_nova，resume=true；同一逻辑会话 2026-09-05 15:37:11.038Z 开始，前一日已过 180/300 秒里程碑；累计 370 秒 | 370 秒不是这次恢复后连续播放六分钟，也不是失败音频项的时长。跨日会话使暂停/恢复已有 item 的路径值得检查，但没有文件状态或设备错误信息证明发生过临时文件删除。 |

两次属于不同安装标识；代码证据不支持将其视为同一设备或同一个 Kindle 翻页问题。

EPUB 会话在 9 月 5 日已经开始，早于 9 月 6 日后端发布。现在没有失败 segment 的音频身份、关联 TTS 请求 ID 或生成时间，不能因 read_end 落在当日发布窗口就把失败音频归到 R133；失败项可能来自此前生成的会话内存/预写缓存，也可能后来生成，二者均未证实。

### 首音频与累计时长的真实契约

`ReadAloudViewModel.handlePlaybackState` 在 `audio.isPlaying == true && ownsAudioQueue && currentSegment != nil` 时发 `read_first_audio`（4282–4305）。不是音频返回或入队时直接发。

但 `AudioPlayerService` 在 `.readyToPlay` 回调里调用 `playImmediately(atRate:)` 后立即设 `isPlaying = true`（1652–1655），普通 `play()` / 恢复也如此（1266–1267），不等待 `timeControlStatus == .playing` 或 currentTime 推进。另一个观察回调稍后才按真实状态修正这个布尔值（1744–1794）。因此这里的首音频严格说是“客户端认为开始播放”的信号。

累计时长由同一逻辑会话的连续 segment 时钟增量产生，切 segment / 暂停会重置游标但不会清零累计值（Read VM 116–185、4285–4288、4311–4319）。终止时用 `Int(ended.playbackSeconds)` 截断小数（4389）。首音频存在且累计值为 0 在这个实现中完全可能。

## 错误分类的精确路径

`ReadAloudViewModel.swift:729–741` 把全部 `onPlaybackError(message)` 映射为相同 analytics 三元组。产生回调的代码：

| 原始入口 | AudioPlayerService 基线行号 | 上报前仍可获得的信息 |
|---|---|---|
| `segment.audioData.write(to:)` 抛错 | 1547–1566 | 文件写入 Error，仅转成 localizedDescription |
| `AVPlayerItem.status == .failed` | 1607–1614、1667–1676 | `item.error`，仅保留 localizedDescription |
| 当前 item `.unknown` 持续到 12 秒定时器 | 1682–1699 | 固定文本“音频准备超时，请重试” |
| `.AVPlayerItemFailedToPlayToEndTime` | 1850–1885 | 通知的 error 或 item.error，仅保留 localizedDescription |

`reportPlaybackFailure` 根据当前 item identity 去重，暂停播放器并发回调（1888–1906）。它既不清空 queue / currentSegment / item，也不重建播放器或音频。

已有防陈旧回调措施：status 观察回调校验 `observedItem === playerItem` 和 session 归属（1611–1614）；终止通知也校验 item identity / ownership（1880–1883）。不能仅凭“发生切段”就断定旧 item 回调污染新 item。

## 确认缺陷 A：音频校验不足

生成流程为：HTTP 2xx + JSON 解码（APIService 233–255）→ `Data(base64Encoded: response.audio)`（TTSService 139–155 / 231–259）→ AudioSegment → 本地临时文件 → AVURLAsset。AVPlayer 获得的是本地文件 URL（AudioPlayerService 1536–1587），没有用服务器的远程媒体 URL 播放。

`TTSResponse.audioFormat` 存在但不用于播放格式选择（TTSTimestamp 83–108；TTSService 构造 AudioSegment 不传格式标志）。云端 AudioSegment 默认 `isWavFormat=false`，写成 `.mp3`（TTSTimestamp 397–410；AudioPlayerService 1536–1544）。请求声明 `response_format=mp3`（TTSTimestamp 46）。这说明未验证响应格式；**文件扩展名与实际格式不同本身并不等于失败**。

`ensureDuration` 只在 API 时长缺失时尝试 AVAudioPlayer(data:)。解析失败返回 0，然后仍保留原 segment；API 已提供时长时连这一步也跳过（TTSService 305–324）。这个方法不能视为可播放性校验。

离线探针 `local_payload_probe.swift` / `local_payload_probe.txt` 在 macOS 26.2 的真实 AVFoundation 上、无播放无网络运行：

| 输入 | build 53 Base64 检查 | 09dcb64 预置音色检查 | 本地 AVPlayerItem |
|---|---|---|---|
| 空字符串 | 放行，0 字节 | 拒绝 | failed，-11849 / underlying -12873 |
| Base64 包裹 `not audio` / JSON | 放行 | 放行 | failed，-11849 / underlying -12873 |
| URL 文本、data URI、非法 Base64、带换行 Base64 | 拒绝 | 拒绝 | 尚未进入播放器 |
| 有效静音 WAV，文件扩展名为 `.wav` 或 `.mp3` | 放行 | 放行 | 两者均 ready |
| 路径不存在 | 与 Base64 无关 | 与 Base64 无关 | failed，-11800 / underlying -17913 |

这是输入检查与文件型 AVPlayerItem 的本地行为证据，不是受影响 iOS 设备或线上音频的复现。尤其 URL 文本/data URI/非法 Base64 通常走 `tts_failed` 错误路径（Read VM 2922–2943），不能不加解释地用来归因本次 `player` 事件。

## 确认缺陷 B：失败状态可被同一生产者覆盖

`onPlaybackError`（Read VM 729–741）没有取消 `generationTask`、递增 `generationEpoch`、清除期望新音频或让当前 session 失效。因此其后的这些 guard 仍会通过：

- 后续 `appendSegment` 只检查 epoch、段落、session / active ownership（2958–2963），成功入队后无条件设 `.streaming`（3021）。
- 生成任务结束只检查相同 epoch/段落/session，执行 `finishStreamingProducer` 后无条件设 `.ready`（2854–2864）。
- `AudioPlayerService.loadSegment` 没有返回内部 `playSegment` 的成败，在首次播放/等待分支之后仍返回 true（1013–1026）。因此写文件错误可以先同步触发 `.error`，再被调用者立即覆盖为 `.streaming`。
- 正常按钮只在 VM `.error` 时重新生成（2124–2126）；否则进入保留队列的 `audio.play`。后者不检查 `item.status == .failed`，直接重用 item 并把 `isPlaying` 设为 true（1243–1269）。外部 `ensurePlaying` 也没有 `.error` 分支（2163–2204），锁屏 Play 直接调用相同 `audio.play`（622–626）。

因此一个可达顺序是：segment 0 的播放器错误 → read_end 已终止一次 → 尚在运行的生成者返回 segment 1 或正常结束 → VM 显示 streaming/ready，但当前 item 仍 failed → 再点播放走复用坏 item 分支。

`failure_state_probe.swift` 使用真实失败 AVPlayerItem 和上述相关状态赋值验证这条窄控制流；输出为 `error/item2 → streaming/item2 → ready/item2`，终止计数仍为 1，重试分支 false。该探针刻意没有编译全应用或模拟实际 UI，只验证代码允许的后续状态覆盖不可能修复底层 item。

## 临时文件、缓存与竞态审查

- 所有播放临时文件位于 `tmp/CastReaderPlaybackAudio`；文件名附独立 UUID（AudioPlayerService 34–108）。相同段落/片段 id 不会直接覆写同一个路径。
- 预写缓存用 `segment.id`（仅 paragraphIndex-segmentIndex）作为键（1108、1121、TTSTimestamp 402）；取出时从字典移除，并核实路径存在（1146–1152）。之后 `discardPrestagedSegments` 不再持有当前播放文件，因此普通预取取消不会直接删掉已取出的文件。
- `stop(preservingPrestagedIDs:)` 先撤观察、暂停并清空 item/player，再删除当前文件；保留新队列将使用的预写文件（1338–1368）。普通 `loadSegments` 用新段落的 segment IDs 保留预写（1039–1044）。
- `playSegment` 确实先删除前一音频文件（1502–1505），随后才在 `playAudio` 撤旧观察/换 item（1577–1598）。这是可改进的生命周期顺序；文件名隔离和陈旧回调 guard 降低混淆风险。没有设备文件/回调证据证明该短窗口导致本次事件。
- `prestageSegments` 自身不带 session 参数，键也不带 generation/content；不过唯一生产调用由 Read VM 的取消、isActive、generationEpoch、prefetchingIndex 检查保护（3187–3206），重生成会 clearPrefetch / clearQueue（2797–2802），暂停/换模式也有 ownership fencing。不能仅凭字典 key 短就宣布本次跨文档串缓存。
- `prepare()` 会删除整个自有播放目录；调用点只有启动协调器 ready 前（CastReaderApp 182–214）和 AudioPlayerService 单例初始化（508–512）。没有发现每次前台都会清目录。App 的 background observer 只处理分析/归因服务（253–261）。
- 普通 pause 只暂停，保留 currentTempFileURL、item、queue（1272–1276）；恢复 `play` 不核实文件是否仍存在，不重写 Data（1243–1269）。因此跨日 EPUB 应检查恢复时的文件存在性、读权限和 item error；**当前没有证据显示 iOS 清理过此文件，也没有证明其在同一个 item 上恢复**。
- YouTube 永久音频缓存不适用于 Kobo/EPUB；并且当前生产 provider 使用默认 `audioCachingEnabled=false`（YouTubeRouteCenter 82；YouTubeCacheStore 542），Read VM 2898–2900 明确不持久化新音频。不能用该缓存的维护/淘汰逻辑解释这两次失败。

## 后续提交覆盖范围

| 提交 | 覆盖 | 本次已证实缺口 |
|---|---|---|
| `09dcb64` | 预置 TTS 临时 HTTP/网络/响应错误一次重试；容错可选时间戳元数据；空 Base64 音频拒绝；TTS 错误码细化 | 部分修复缺陷 A 的预置音色空音频；不校验非空内容、不修播放器失败恢复、不细分 player 错误。 |
| `814030a` | Kindle 翻页确认失败后观察可见页并恢复、受控再试 | 两条来源是 Kobo / EPUB，没有直接覆盖这两条的播放错误。 |
| `47f9541` | Kindle continuation ownership 在模式变化时的检查 | 不处理音频数据、临时文件、AVPlayer 错误或 Read VM 失败覆盖。 |

`git diff e3bbe90..47f9541 -- CastReader/Services/AudioPlayerService.swift` 为空。故不能宣称三个提交整体已经修复这两次 `player_item_failed`。

## 缺少的决定性证据

Release 的 `ReaderRunLog.write` 全部位于 `#if DEBUG`（ReaderHostView 1641–1662），App Store 包不写 `reader-refocus.log`。源码没有读取 `errorLog()` / `accessLog()` / `NSUnderlyingErrorKey` 或监听媒体服务 reset。现有 error 上报仅有固定类别，localizedDescription 只留给本地 print / DEBUG 日志。

要确定触发器，下一次至少需要：原始入口类别（staging / item_status / failed_to_end / readiness_timeout）、NSError domain/code/underlying 链、item 状态、媒体字节数与检测到的容器类型、当前文件存在/大小、segment/session ownership、是否从暂停恢复及恢复前后台间隔。用一次请求 ID 或不可逆内容摘要关联 API 响应即可，无需保存朗读原文、完整音频、token 或账户信息。

优先修复可确认的“播放器失败后仍被生成者覆盖”并区分失败类别；是否应重写本地文件、重建 item、重新生成 TTS，应依据具体错误和重试上限决定。当前证据不足以选定模型/网络切换作为根因修复。
