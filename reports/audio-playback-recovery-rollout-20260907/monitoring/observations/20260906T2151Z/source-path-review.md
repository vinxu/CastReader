# PDF Explain 晚失败路径：冻结源码只读复核

基线：Android 1.0.46/build53 保存上传源码 `3fe41d62b9f0c1d699ba20e84aecb63fd970b33b`，通过 `/Users/xuxuheng/Documents/.worktrees/CastReader-Android-main-release-20260902` 的 `git show` 读取该提交，未将 worktree 当前 HEAD 当作已发布代码。以下路径均相对 `app/src/main/java/com/same/castreader/`，行号属于该冻结提交。

**确认存在“切回朗读后，旧 Explain 仍可晚报 failed”的具体代码路径；不能证明本次异常就是该路径的某个特定网络错误。**

| 位置 | 代码能证明的事实 |
|---|---|
| `ui/screens/pdfreader/PdfReaderViewModel.kt:424–435,480` | 切到 READ 或点 PDF 段落调用 `exitExplainToRead`：仅设 `explainActive=false`、停止并释放旁白、更新 mode、启动朗读。没有取消 Explain Job，也没有结束 Explain analytics session。 |
| 同文件 `487–535` | `startExplain` 的 `viewModelScope.launch` 没有保存独立 Job。PDF 内 `pipeline_failed/unexpected_error` 只有 `528–531` 这一处通用 `catch(Exception)` 出口；不是专门的模型/TTS错误分类。它没有检查当前 mode、active flag、session identity 或 generation。之后 `533–534` 仍改 Explain UI/flag。 |
| `analytics/ProductAnalytics.kt:540–564,677–695,755–782` | `beginRead` 不关闭 Explain；反向 `beginExplain` 会将 Read 记为 `mode_switched`。因此上述切换后 Explain session 可继续存在。`endExplain` 操作当前 Explain session，无调用方传入的旧 session token。完整 `stopSession` 才在 PDF VM `1103–1105` 上报 Explain cancelled。 |
| PDF VM `570–586,628–637,654–688` | 主 `planBatch` 直接调用 `extractPlan`，主批次规划 `660` 的异常可以冒泡到通用 catch。循环入口虽检查 boolean，但正在等待的请求不会因该 boolean 改变而自动取消；下一批预取和下一块预取还分别使用独立 `viewModelScope.launch/async`。某些 fetch/TTS/compose 调用通过 `runCatching(...).getOrNull()` 吞掉错误（`711–718,732,751–759`），因此不能把通用出口反解成特定端点。 |
| `data/remote/QuickReadApi.kt:169–194,249–273,328–374` | 调用在 `withContext(IO)` 中执行同步 `newCall(...).execute()`/流读取，未将 mode boolean 绑定到 `Call.cancel`。IO 等异常重试耗尽后可抛出；HTTP异常通常由 PDF VM 的另一专门 catch 记 `request_failed`。通用 catch 也没有单独排除 CancellationException。 |

可实现的晚错误链为：Explain 已进入主批次规划 → 用户操作触发上述 READ 转换 → 旧 Explain Job/session 未结束 → 进行中的规划随后抛出未被专门分支处理的异常 → 旧协程继续上报 `pipeline_failed/unexpected_error`。这说明客户端生命周期隔离有缺口，但没有精确请求标识或现场异常类，不能把本条生产失败改记为“已证实取消”，也不能排除服务或网络异常。

**对已经运行的 Read 的影响边界：** `529` 的 `endExplain` 只生成 Explain 事件并清空 Explain analytics session（`ProductAnalytics:755–782`），不调用 Read 播放器。`531` 的 `emitSubtitle` 仅更新 PDF UI 的 subtitle（PDF VM `987`）；`533–534` 仅更新 `explaining/explainFinished/subtitle` 和 Explain flag。这个错误分支没有 `playbackController.pause/clear`、`audioPlayerManager.pause/clearQueue` 或 Read 队列操作，不能据此宣称它直接停止了已运行的朗读。可证明的是旧 Explain 仍能污染终止统计和 UI 状态；其他晚回调还可写同一 UI 的 loading/section（`663,671–681`），未检查 mode 的旁白 poller 可写共享 MiniPlayer 文本（`865–875`），所以影响边界也不限于独立 Explain 页面。上述读到的分支没有证明 Read 音频被中断；现场随后 Read 达到600秒，仍不等于 Explain恢复。

**未发现该调用链配置固定 120 秒计时器。** `di/NetworkModule.kt:40–49` 配置 connect 30 秒、read 60 秒、write 60 秒，没有配置整次调用 `callTimeout`；`extractPlan` 为最多 2 次、60,000ms retry budget（`QuickReadApi.kt:247–250`），但预算只在异常发生后检查是否再试（`179–183`），不是提前终止整个请求的 deadline。extract-block/compose 使用默认最多 3 次且默认 retry budget 为 `Long.MAX_VALUE`。快道 race 的 GLOBAL 值为 8 秒、CN 为 25 秒（`util/QuickReadFastLane.kt:25–28`）。因此现场 READ 开始到 Explain failed 的 **120.267 秒**仅为时序事实，不能据此认定“120 秒网络超时”。

`QuickReadApi.resolveEndpoint:82–96` 对全球发行版 GLOBAL 路由会读取远程配置；不能以本轮 Vercel阶段成功替代该 Explain 链路的健康证明。本次未读取凭据、运行模型、发合成请求或修改代码。

现场仍保留真实 Explain 失败：`a6fbedfbaf4a619cc70c`，occurred `21:27:07.828Z`，received `21:27:15.844Z`。39.719 秒是同一 Explain session 的首块；随后另一 READ session 达到600秒，不能作为 Explain恢复证据。
