# CastReader 声音克隆与新 TTS 生产架构

## 结论

当前 Demo 的主要问题不是 Qwen3-TTS 0.6B 单次推理不够快，而是把“一张卡只能安全执行一个重任务”直接暴露成了 HTTP 非阻塞锁：前台段落、下一段预取和音色创建只要相撞就立即返回 429；客户端又会在首个音频片段到达时过早预取，因此用户正常朗读也会自己制造并发冲突。公网链路还依赖无 SLA 的临时 Quick Tunnel，音色编译产物只保存在单台 GPU 本地。这四点共同造成超时、空列表、长时间加载和偶发不可用。

生产版应拆成控制面、任务面、GPU 数据面，并由公开 API 维持 Kokoro 兼容响应。GPU 只主动向外领取任务，不再作为公网源站，也不再依赖某一条反向隧道。

```text
iOS / Web
    |
    v
Public API / Control Plane
  鉴权、额度、voice 元数据、幂等、兼容适配
    |
    +--> Redis durable queue/status --> GPU Worker (outbound pull)
    |                                  单卡有界调度
    |                                  interactive > prefetch > voice-build
    |
    +--> Regional encrypted objects <-- raw reference / prompt.pt / optional audio
         Global: Supabase Storage
         China: Tencent COS via STS
    |
    +--> Kokoro-compatible response
         {audio,audio_format,timestamps,voice_code}
```

## 当前故障树

1. 单进程 `Lock.acquire(blocking=False)` 把正常的内部串行约束变成用户可见 429。
2. iOS 收到当前段第一个 segment 就启动下一段预取；当前段尚未完成时，两者争用同一把锁。
3. 前台和预取都以 30 秒超时结束，失败后没有稳定的幂等恢复语义。
4. Quick Tunnel 是测试通道，地址会变化、链路延迟不稳定且没有生产 SLA。
5. `prompt.pt` 仅存在 GPU 本地；更换节点或本地丢失时，需要下载原始音频并重新加载模型编译。
6. 音色创建成功后客户端再刷新列表；刷新失败时用户看见空列表，误以为创建失败。
7. 随机采样缺少质量回归门，某些文本可能抽到异常音频；仅检查“非空 WAV”不足以识别电音式退化。

## 生产请求协议

### 外部兼容层

朗读和解读继续使用现有 `/api/captioned_speech_partly`。当选择克隆音色时，公开 API 把内部任务结果转换为与 Kokoro 完全相同的四字段 JSON：

```json
{
  "audio": "<base64 mp3>",
  "audio_format": "audio/mpeg",
  "timestamps": [{"word":"...","start_time":0.0,"end_time":0.2}],
  "voice_code": "vc_..."
}
```

不得因新引擎增加顶层字段。请求 ID、排队时间、执行时间和重试提示放在响应头与服务端日志中。

### 内部任务

内部使用独立 schema，并至少包含：

- `job_id`：服务端生成，稳定且全局唯一。
- `idempotency_key`：`user + document + paragraph + voice + speed + text_hash`。
- `session_id`、`user_id`：用于每用户公平调度。
- `kind`：`interactive`、`prefetch`、`voice-build`。
- `deadline_at`：过期预取不得再占用 GPU。
- `voice_id`、`language`、`text`、`speed`、`seed`。
- `attempt`、`lease_owner`、`lease_expires_at`。
- `cancelled_at`：用户切文档、切音色或停止朗读时取消尚未运行的预取。

任务状态为 `queued -> leased -> running -> succeeded|failed|expired|cancelled`。领取任务必须带 lease；worker 崩溃后 lease 到期可重领。成功写入必须用幂等条件更新，避免重试生成两份可见结果。

## 单卡调度与背压

单张 4090 内部保持一次只执行一个不兼容重任务，但调用方进入有界队列而不是立即 429：

- `interactive`：用户当前正要播放的段落，最高优先级。
- `prefetch`：只允许每个播放 session 保留一个下一段；新预取覆盖旧预取。
- `voice-build`：最低优先级，只在没有临近 interactive deadline 时启动。
- 全局队列有硬上限；真正满时返回 429 + `Retry-After`，而非忙一次就 429。
- 对同一用户设置在途上限，避免一个长文用户占满全局队列。
- 用加权公平而非无限严格优先，保证音色创建不会永久饥饿。
- 一旦 voice-build 开始，无法安全抢占；调度器应在启动前检查未来数秒内是否有交互任务。

0.6B Nari 服务自身可以做批处理，但当前完整音频优先目标与动态音色路径尚未证明批量在 4090 上稳定。第一版先用可预测的单执行槽，压力数据证明安全后再开放 2 路微批，而不是让公网并发直接击中模型。

## 音色资产生命周期

音色创建改为异步资源：

1. API 校验授权与录音基本指标；国际区把加密原始参考音频和 transcript 保存到 Supabase Storage，中国区由客户端通过受保护 STS 直传腾讯 COS，再由控制面校验 object key 归属并读取。
2. 数据库建立 `processing` voice，立即返回 voice ID；客户端显示明确进度，不显示空头像或空列表。
3. voice-build 任务生成 `prompt.pt`，完成后加密写入当前线路的区域对象存储，记录模型版本、prompt schema、hash 与创建时间。
4. worker 使用本地 LRU 缓存；缓存未命中从当前线路的区域对象存储下载 `prompt.pt`，不重新编译。
5. 编译失败写 `failed + error_code`，允许用户重试；删除时清理 DB 和对象存储，worker 缓存按版本失效。

原始录音和 prompt 都不是单台 GPU 的真相源。数据库与加密对象存储才是权威，GPU 节点可随时替换。

## 稳定性机制

- worker 每 5 秒心跳：模型版本、ready、显存、队列深度、当前任务、最近错误。
- 控制面根据心跳维护 circuit breaker；不向失联或高显存节点派新任务。
- 模型启动完成并通过固定音频 canary 后才进入 ready；进程重启期间为 draining/unready。
- 每个任务有分阶段超时：排队、模型、编码、总时长分别记录。
- 可安全重试的只包括“尚未领取”或“结果未提交且幂等键相同”的任务。
- 预取失败不影响当前段播放；前台任务失败才对用户显示可重试状态。
- GPU OOM、CUDA error、连续异常音频触发 worker 自动摘流并重启，而不是继续返回坏音频。
- 服务停止时先停止领取、等待当前任务、归还未开始 lease，再退出。

## 音频质量门

每次生成做低成本、不增加模型推理的检查：

- 容器/采样率/时长有效，正文非空。
- RMS、峰值、静音比例、削波比例、DC offset 在经验范围内。
- 高频能量比例与谱平坦度超过基线阈值时标记为可疑电音。
- 音频时长相对文本长度明显异常时失败。
- 同一请求最多以确定性备用 seed 重生成一次；仍失败即返回明确错误并记录样本，禁止无限重试。

每日离线回归用固定中英文、数字、标点、长句和情绪句集合，检查正文无增删重复、JSON 合同、音频指标和人工抽听样本。

## 可观测性与目标

结构化日志统一包含 `request_id/job_id/session_id/voice_id_hash/model/worker/priority/queue_ms/inference_ms/encode_ms/total_ms/result/error_code`，不记录原始录音、完整文本或 token。

第一阶段验收门：

- 4 字段 JSON 合同通过率 100%。
- 低于队列设计容量时 429 为 0。
- 60 分钟长稳无进程退出、CUDA error、OOM、空音频。
- 并发 1 的成功率 100%，P95 受模型基线约束；并发升高时只增加可解释的 queue time。
- 创建音色与朗读混合压力下，当前播放请求优先，音色创建最终完成。
- kill worker、模型重启、过期预取、客户端取消均有确定的状态迁移。
- 压测前后旧 TTS 健康、错误率和延迟无明显回归。

这些指标验证的是单卡服务的“稳定和可降级”。一张 4090 仍然是物理单点：硬件故障或整机离线时无法做到真正无缝。正式承诺高可用至少需要两个常驻、已预热的 GPU worker，跨美国/中国区不能直接互为所有用户的低延迟热备，应按数据合规和地区路由分别配置容量。

## 分阶段落地

### 阶段 A：隔离验证

- 美国生产卡不发压测流量。
- 中国 4090 使用独立目录、venv、模型目录、端口和日志；保留旧 8880 服务不变。
- 先以预生成测试 prompt 验证显存共存，再逐级并发、混合优先级、长稳和故障恢复。

### 阶段 B：消除当前故障

- 部署有界调度器，替代非阻塞全局锁。
- iOS 只在当前段生成完成后预取下一段，并取消过期预取。
- 创建成功后客户端先本地插入 voice，再后台刷新。
- 固化采样参数并加入音频质量门。

### 阶段 C：生产任务面

- 引入 Redis durable queue/status、lease、幂等、取消与 worker 心跳。
- GPU worker 改为 outbound pull；移除 Quick Tunnel 生产依赖。
- raw reference 与 `prompt.pt` 都进入区域化加密对象存储（国际区 Supabase、中国区 COS），worker 只做缓存。
- 灰度流量按用户稳定哈希，失败自动回 Kokoro 或明确提示，不在同一请求内反复撞新模型。

### 阶段 D：容量与高可用

- 根据真实 P95 文本长度、生成 RTF 和峰值并发计算每区卡数。
- 至少两台预热 worker 后才启用自动摘流、滚动升级与卡级故障转移。
- 达到容量阈值前扩容，不把无限排队当作扩容方案。

## 2026-08-26 实测与当前生产桥接

这次发布先完成了不依赖新基础设施采购的止血层，目标架构中的 durable queue 与每区双 GPU 热备仍属于下一阶段。国际区由 Vercel 控制面通过固定端口 TLS 访问美区 worker；服务端只信任环境变量内固定的私有 CA。中国区由 `api.castreader.cn` 控制面通过固定、受管的私有 SSH 隧道访问中国区 worker。此前实验性的 Cloudflare Quick Tunnel 已停止且禁止自启动，不再承担生产或回滚职责。worker、Nari 和旧 TTS 独立托管，重启其中一个不会级联停止另外两个。

音色创建不再为每次录音启动一个新的 0.6B 模型进程。worker 启动时加载可复用的 prompt encoder，约占 2.65GB 显存；生成与音色编译仍经过同一个有界调度器，所以不会发生两个重任务同时写 GPU。该变更把同一张 4090 上的音色创建从 26.6 秒降到 1.95 秒。生产卡未做合成压测，只做了加载、健康检查和服务滚动；所有负载与故障测试均在中国区隔离端口执行。

| 场景 | 结果 | 旧 TTS 影响 |
|---|---:|---:|
| 6000 次、并发 4、61.96 分钟最终长稳 | 6000/6000；aggregate RTF 0.1013；interactive P95 1.40s；worker run P95 0.763s；失败/过期 0 | 1783/1783 健康；P95 2.05ms；最大 3.99ms；最低剩余显存 8445MB；最高 57°C |
| 2500 次、并发 4、约 25 分钟长稳 | 2500/2500；aggregate RTF 0.1019；interactive P95 1.33s | 723/723 健康；P95 2.04ms；最大 3.40ms |
| 10 语言、24 条语料各两遍 | 48/48；四字段合同、MP3、时间戳正文覆盖均通过；P95 1.41s | 28/28；P95 2.03ms |
| 极端并发 40、80 次 | 精确接收 1 running + 32 queued；33/33 完成；其余 47 明确 429；无崩溃/OOM | 20/20；P95 2.02ms |
| 热音色编译与 8 次朗读相撞 | 创建 1.95s；朗读 8/8；朗读 P95 2.91s | 19/19；P95 1.93ms |
| 删除本地 prompt 后从加密对象恢复 | 导出、删除、导入、再合成 2/2 通过 | 无异常 |
| 强杀 clone adapter | 12.2s 自动恢复；Nari PID 不变 | 进程未重启 |
| 强杀 Nari | 34.7s 自动恢复；同 request ID 最终返回四字段合同 | 32/32；P95 2.67ms；最大 2.96ms |

电音质量门对每次 WAV 做低成本频谱检查。当前多语言样本的高频能量比最大 0.001102、谱平坦度最大 0.007647、削波最大 0；明显白噪声、持续 9kHz 音调和重削波单测都会被拒绝。一次异常最多换确定性 seed 重试一次，禁止无限重生成。

### 参考录音质量阶段 1 / 2（2026-08-26）

声音克隆在进入 prompt encoder 前增加了独立的 CPU 质量管线 `castreader-reference-v3`，不增加 TTS/LLM 推理。阶段 1 使用 Silero VAD（不可用时回退能量 VAD）只裁掉首尾静音，统一成单声道 24kHz，目标有效人声 RMS 为 -20dBFS，增益最多 ±9dB，峰值上限 -1dBFS，并在首尾加入 10ms 淡入淡出。阶段 2 对 SNR 9–18dB 且噪声稳定的样本做最多 4.5dB 的保守频谱降噪，使用 CampPlus speaker embedding 检查说话人一致性，并以语音结束后的能量衰减检查房间混响。

这里刻意不从引导录音中任意截取内部“最清晰 6–10 秒”。Qwen ICL 要求参考音频与 `reference_text` 精确对应，随意抽取内部片段会破坏 transcript 对齐。当前引导文案自然落在约 6–10 秒，服务端保留完整讲话顺序、仅裁外部静音；以后若支持长音频上传，必须先具备片段级 ASR 对齐再做内部选段。

硬拒绝码覆盖无有效人声、讲话不足、静音占比过高、音量过低、削波、SNR 低于 9dB 和多人声。混响采用 warning-first：尾音相对响度改为与整段人声的稳健电平比较，单个句末尾音永不作为硬拒绝依据；只有至少两个独立尾段都接近直达声（高于 -4dB）时才拒绝。轻度稳定噪声会被处理后继续创建。质量错误以 HTTP 422 的结构化 `detail.code/message/metrics` 从 worker 传到 Vercel，再由 iOS 映射为 9 种产品语言的可操作提示；worker 同时只记录错误码和数值指标，不记录音频或朗读文本。

中国区 v3 实机矩阵 9/9 符合预期：两份单人声通过，轻度稳定噪声通过并执行降噪；重噪声、过轻、削波和双人声分别命中对应拒绝码；两份混响样本允许创建，其中严重样本带 `room_echo_detected` warning。CPU 冷启动约 2.3 秒，模型常驻后每段约 0.15–0.25 秒。五类 422 验证前后 GPU scheduler 都保持 `submitted=0/failed=0/expired=0`。同一参考音频端到端复建 prompt 用时 2.048 秒，裁剪 6.64→5.974 秒、标准化 +4.7dB、无降噪和 limiter；旧/新 prompt 的同文案生成分别为 6.08/6.80 秒，两份均通过输出音频质量门，新版输出 RMS 由 0.0483 提升到 0.1013且无削波。旧 8880 在创建与两次对照合成前后均为 200。

2026-08-26 真机首次录制连续 3 次被 v2 误判为混响过大，生产证据推翻了“单句尾音高于 -8dB 即拒绝”的实验室阈值。v3 在不重启旧 TTS/Nari 的前提下滚动上线后，同一 iPhone 环境首次重试即成功：原录音 9.66 秒，人声 8.524 秒（88.24%），SNR 19.76dB，削波 0，混响尾段 0，多说话人最低相似度 0.6886，标准化 +5.51dB，处理后峰值 -2.06dBFS，无 warning；prompt 构建 1.138 秒。随后同一音色完成 2 次试听和 33 个带时间戳正文分段，连同音色创建共 36/36 GPU 作业完成、失败/过期 0、排队 P95 0.08ms。35 个音频请求共生成 274.24 秒音频，GPU 合计 24.478 秒，aggregate RTF 0.0893，合成 P95 1.283 秒；每段均首个 seed 通过电音质量门，削波 0，最高高频能量比 0.001848、最高谱平坦度 0.022972。测试结束后旧 8880、Nari、clone 与固定 TLS 全部为 200，GPU 队列为空、利用率 0%；worker error log 自 v3 启动后没有新增内容。

### 段首变音防护 v4（2026-08-26）

真机缓存音频证明段首变音已经存在于服务端 MP3 内，排除 AVPlayer、网络下载和词级高亮；发生位置又总是每个独立段落的模型冷起点，且 worker 排队、显存和温度正常，排除拥堵。结构性 A/B 进一步推翻两个直觉方案：把 codec 解码调度从 `[1,2,4,8,12]` 改为 `[7,12]` 时波形 SNR 约 68dB、延迟与质量指标几乎不变；temperature 从 0.9 降至 0.75/0.65 也没有稳定降低段首音高偏移。`defer_codec_until_terminal` 在当前序列路径上不可用并会令 staging Nari 退出，已永久保持关闭。因此 v4 不修改 codec schedule、不降低 temperature，也不裁掉正文开头。

实际有效的改动是让参考录音在人声结束后始终保有 200ms 模型稳定尾部。过去代码只取 `min(源文件末尾, 人声结束+200ms)`，用户松手紧贴最后一个字时实际上没有尾部；现在只补齐缺失的零样本，并将合成尾部排除在 SNR、讲话占比等参考质量统计之外。A/B 中硬切参考的段首/正文中位音高比为 1.0894，500ms 尾部虽降至 1.0665但出现 1 次电子前缀拒绝；200ms 尾部在 16 次中无拒绝，中位比降至 1.0181，P95 为 1.2205，保持了更好的平衡。

输出质量门同时从“整段均值”扩展为独立检查首个有效人声后的 2.16 秒：记录段首与正文的音高中位数/P90 比、段首高频能量和谱平坦度；明显电子前缀或同时满足中位数与 P90 大幅跳变时换确定性备用 seed 重试一次。该检查只消耗 CPU，不增加模型调用；正常结果仍为原来的精确四字段 JSON，正文不增删、不重复。27/27 隔离测试通过，包括硬切录音补足尾部、前缀白噪声拒绝、大幅音高跳变拒绝和正常句首抑扬放行。

中国区部署后用一份末尾无静音的真实建声请求验证，服务端记录 `last_speech_end_s=7.72`、`trim_end_s=7.92`、`synthetic_tail_padding_ms=200`，prompt 构建连同调度共 2.254 秒。随后 10 语言 24/24 段全部通过精确四字段 JSON、Base64 MP3、时间戳单调、正文覆盖和音频末尾误差校验；P50 704ms、P95 810ms，aggregate RTF 0.115，worker 25/25 完成、失败/过期 0。测试期间中国区旧 8880 探针 192/192 为 200，Nari、worker 与旧 TTS PID 均未变化，无 CUDA/OOM/重启。

v4 随后只在美区 GPU 利用率连续 6 秒不高于 2% 的自然空档替换 clone adapter。旧 TTS、Nari 与固定 TLS 均未重启，固定 TLS 与内部 worker 健康检查为 200；发布后 20 轮旧 TTS/Nari/clone 联合探针全部通过，clone scheduler 为 `submitted=0/completed=0/failed=0/expired=0`，符合“不向美国 4090 发送合成或压力流量”的限制。更新前 worker 已备份到 `/workspace/castreader-clone/backups/prefix-v4-20260826T060423Z`。段首输出质量门会立即保护已有音色；200ms 参考尾部只会写入更新后新建的 prompt，旧 prompt 没有保存原始录音，不能在不重新录制的情况下无损重建。最终听感仍需以新建音色的真机主观验收为准。

### 段首解码器冷启动修复 v6（2026-08-26）

真机继续听到段首变音，证明 v4 的 200ms 参考尾部和输出质量门只能降低概率，不能消除根因。对照官方 Qwen3-TTS 实现后确认：官方 ICL 会把 `ref_code + generated_code` 作为连续序列交给 12Hz waveform decoder，再裁掉参考音频；此前 Nari 只把参考编码用于 Talker conditioning，Codec 每个段落仍从空隐藏状态启动。生产历史也与此一致：同一真实音色的若干已接受样本，段首音高 P90/正文 P90 比达到 2.03–2.86，而参考录音本身 SNR 21.91dB、无削波并有 200ms 尾部，排除了录音质量作为主因。

完整照搬官方 ICL 不是单卡可用方案。隔离实现将 88 帧参考编码与正文整段联合解码后，合成期间 GPU 空闲显存降到 481MiB，触发安全看门狗；该版本已立即回滚，旧 8880 始终保持 200。官方仓库的 cold-start 缺陷报告给出了更小的等价修复：在 12Hz decoder 首次正文帧前加入 250ms 编码静音作为隐藏状态预热，再只返回静音之后的 PCM。当前 v6 prompt 只保存 `4 x 16` 个 `decoder_bootstrap_code`，首次 Codec dispatch 为 4 帧静音上下文加 2 帧正文，之后继续使用原有增量 decoder state；不再携带 6–10 秒完整参考，也保持 `defer_codec_until_terminal=false`。

旧 v2 prompt 不需要用户重录。worker 可原子加入这四帧固定静音编码并升级为 v3；区域对象存储若再次恢复 v2，导入时也会即时完成相同升级。真实用户音色 `37b848942345` 的生产验证中，提示无损升级后生成 10.00 秒音频仅用 1.131 秒，队列 0.10ms，首段/正文音高中位数比 1.138、P90 比 1.1782，显存采样前后及合成中都为剩余 8489MiB；JSON、MP3 与 45 个单调时间戳全部通过。当前隔离单测 27/27，通过后 worker 为 `submitted=1/completed=1/failed=0/expired=0`，旧 8880 连续 10/10 为 200。是否完全消除用户主观听感仍以真机连续多段验收为准。

同轮验证还发现质量门过去会接受 Talker 未输出 EOS 而跑到 4096 帧上限的 327.68 秒异常音频。worker 现按输入文字和语言类别计算保守 token budget；输出若精确撞到预算上限则视为无 EOS，换一次确定性 seed，第二次仍异常就明确失败，不再让客户端下载或播放数分钟的伪正文。

美国生产仅在连续 6 秒 GPU 利用率不高于 2% 的自然空档滚动重启 clone adapter；旧 TTS 与 Nari PID 未变化。随后五类不合格录音全部返回对应 422，worker scheduler 前后仍为 `submitted=0/completed=0/failed=0/expired=0`，证明生产验收没有向美国 GPU 发送合成或压力流量。控制面 production 为 `dpl_Cf1UeswgKhsPhC5vYbJZuRZyTfgS`，匿名路由回读仍正确返回 401。

客户端与最终生产回读同样通过：iOS 声音克隆与本地化定向测试 16/16，通过 9 种产品语言的质量错误映射；全量并跑时出现的 5 个 ServiceRouting 共享状态失败，隔离复跑为 5/5 通过，确认不属于本次声音质量回归。签名真机包 `1.2.29 (49)` 构建成功。2026-08-26 12:40 CST 尝试覆盖安装时，目标设备 `8D96EFB3-DBC1-52E3-B10D-412C1059D28E` 在 CoreDevice 中为 `unavailable`，因此本轮最新包尚未覆盖到设备，不能把“构建成功”记作“已安装”。中美旧 8880、Nari、clone adapter 与固定 TLS 最终健康检查全部为 200；worker 队列为空且 `failed=0/expired=0`。Vercel 最近 30 分钟没有 voice-clone 新增 5xx，现存错误日志来自无关 SEO 页面缺少翻译消息。

生产发布后保留了以下回滚层：上一版 Vercel production deployment、旧 Quick Tunnel、worker 更新前文件备份，以及三份现存 prompt 资产。固定 TLS、Quick Tunnel、Nari、clone adapter、旧 TTS 是五个独立进程。服务端瞬态重试预算为 47.5 秒，覆盖实测 34.7 秒的完整 Nari 恢复；稳定 request ID 使同一请求在新 worker 上只占用一个 GPU 作业。

iOS 长文链路另修复了一处静默截断：克隆请求原先只发送段落前 600 个字符，却没有把本地尾文接入 `unprocessed_text` continuation。现在按服务端实际使用的 UTF-16 单位切分，并严格按“服务端未处理部分、客户端尚未发送部分”的顺序继续；包含代理对字符的边界与正文逐字守恒已加入回归测试。该修复避免超过 600 单位的英文长段落在第一段后停止或少读正文。

最终长稳使用常驻 prompt encoder、最新质量门、24 条多语言语料与 4 路调用压力连续运行 3717.364 秒。6000 个请求全部同时通过精确四字段 JSON、Base64、MP3 `ffprobe`、时间戳单调性、正文覆盖和音频末尾误差小于 250ms 的校验；共生成 36696 秒音频，吞吐 1.614 req/s。interactive 4800/4800，P95 1.400s；prefetch 1200/1200，P95 7.858s，低优先级排队符合设计。Nari 与 worker PID 全程未变化，无 CUDA、OOM、异常质量事件、失败或过期；6000 个样本最高高频能量比 0.001102、最高谱平坦度 0.007647、削波 0。由此“60 分钟单卡稳定和可降级”硬门完成。

长稳结束后的美国真实高峰观察中，Vercel 旧预设音色 `/api/captioned_speech_partly` 共捕获到 14 次上游 500；同期新 clone worker 为 0 个作业、队列为空、GPU 仍剩余约 9.7GB，旧 TTS/Nari/clone 进程均未重启，因此不能归因于新 Nari 抢占。该窗口随后仍连续完成数百次 200，但 500 已重复出现，整体验收暂保留这一条旧 Kokoro 长尾问题；新克隆链路的 6000 次隔离稳定门不受此结论污染。

为在不增加美区 GPU 流量、不记录用户正文的前提下定位该旧链路长尾，生产控制面增加了只针对上游非 2xx 的安全错误指纹：记录状态码、语言、预设音色、输入长度、上游 request ID，以及异常类型和异常文本的 16 位 SHA-256 分组值；不记录异常原文，不自动重试，也不改变原响应。该监控先通过 preview `dpl_AZZsSTXpeRU5eGM6UJgZMpbdR5nC` 验证，再于 06:10 CST 发布为 production `dpl_GAwK3YDZ5LcLPGLUP9WkAgU9RZHr`。监控随后捕获到两次完全相同的 `it / if_sara / inputLength=1 / processing_error`，间隔约 4 秒且指纹一致，证明这是同一单字符边界请求的客户端重试，而不是服务重启、显存不足或 Nari 抢占。

由于长度 1 本身不能区分标点、单字母与数字，控制面继续加入只统计 Unicode 类别数量、绝不记录字符内容的二级指纹。该版本通过 preview `dpl_3iTN1yP7C3E695hFEHbi2d4tnw9n` 验证，并于 06:37 CST 发布为 production `dpl_5rtJwxdoVJLzTe4b5wUQ7vZv5nmu`。二级指纹随后捕获到同一 `pt / pf_dora` 请求的 5 次重试：`inputLength=1` 且 `punctuation=1`，其余 Unicode 类别全部为 0，错误指纹仍与意大利语样本完全一致。由此根因确认是纯标点被旧 Kokoro 当成可合成正文，而不是单字母、数字、服务负载或 GPU 故障。

控制面现已在进入任一 TTS 引擎前识别只含 Unicode 标点/组合符号的输入，并直接返回 0.168 秒有效静音 MP3、空时间戳与原 `voice_code`；标点仍由客户端原文显示，字母、数字、货币符号和 Emoji 不受影响，也不新增任何 GPU 推理。该修复通过 8 项相关测试、TypeScript、完整 Next 构建和 MP3 `ffprobe`，preview 为 `dpl_6HNNyAEYitRs4kAopHswgqJWxjzP`，07:13 CST production 为 `dpl_EUFivwmWfXvv93g3h2A2LLWuRq9k`。生产 canary 返回 200、精确四字段 `audio/audio_format/timestamps/voice_code`、678 字节 `audio/mpeg`，响应头明确 `punctuation-only`；调用前后美区 clone worker 均为 `submitted=0/failed=0/expired=0`，证明请求未进入 GPU。

截至 07:47 CST 的长稳生产回读，纯标点修复版连续运行约 34 分钟没有任何 500；最新 1000 条成功日志中 876 条为 `/api/captioned_speech_partly` 自然朗读。美区旧 TTS、Nari、clone adapter 与固定 TLS 的 PID 均未变化，健康检查全部 200。中国区 worker 保持 6000/6000、失败/过期 0，Nari/worker PID 连续存活超过 3.5 小时；最终显存剩余 8445MB、28°C，worker 最近 10000 行无 ERROR、Traceback、CUDA、OOM 或 fatal。

### 双区正式链路验收（2026-08-26 15:42 CST）

国际区与中国区已经使用各自的 4090 和区域存储完成真实最小闭环，不再把 Demo 链路当作生产证明：

| 线路 | 控制面与 GPU | 音纹资产 | 实测闭环 |
|---|---|---|---|
| 国际区 | `castreader.ai` / Vercel → 固定 TLS → `castreader-us4090` | Supabase 私有 bucket，命名空间 `voice-clone/` | 建声 201（4.245s 服务端 / 4.720s 端到端）；合成 1.604s 服务端 / 1.844s 端到端；MP3 27,309 bytes、13 个时间戳；删除 200 |
| 中国区 | `api.castreader.cn` → 受管私有隧道 → `castreader-cn4090` | 受保护 STS → 腾讯 COS 私有 bucket `castreader-voice-1323065328`（上海），持久资产命名空间 `voice-clone-cn/` | STS 合同、COS 直传、建声 201（9.436s）、合成 2.151s；MP3 26,541 bytes、13 个时间戳；删除 200 |

两区合成响应都精确保持 Kokoro 的四个顶层字段 `audio/audio_format/timestamps/voice_code`；Base64 MP3、`start_time/end_time` 单调性和正文覆盖均通过。中国区临时原始 WAV 在建声读取后立即删除，`user/cn/` 另有 1 天生命周期兜底；本次删除音色后专用 COS bucket 对象数回到 0。国际区没有使用 Cloudflare R2，未知归属的 `vidduo-ai`/Cloudflare 资产不再参与链路。

最终健康回读：美区 worker `9/9` 完成，中国区 worker `3/3` 完成，两区 `failed=0/expired=0/queue_depth=0`；旧 8880、Nari 与 clone worker 均健康。美区显存使用/剩余 14,502/9,591MB、58°C；中国区 15,665/8,416MB、29°C。Vercel 最近 90 分钟的 `/api/voice-clone/*` 记录均为 info，没有克隆路由错误；现存 error 是无关 SEO 页面缺少翻译消息。

iOS 已按启动时冻结的 `ServiceRouting` 分流：国际区继续 multipart 上传到全球控制面，中国区先获取 STS、按服务端返回的 COS endpoint 签名直传，再提交 `referenceObjectKey`。定向测试最终为 103/103，通过包已签名生成。15:42 CST 再次检查时目标真机 `8D96EFB3-DBC1-52E3-B10D-412C1059D28E` 仍在 CoreDevice 中显示 `unavailable`，因此最新包尚未覆盖安装；必须等设备解锁、连接并信任本机后再安装，不能把“构建成功”写成“已安装”。

### 语言分级与音频感知时间戳（2026-08-27 00:21 CST）

时间戳合同现按朗读语言而不是音色来源执行：中文、日文、韩文请求明确发送 `return_timestamps=false`，worker 即使收到旧客户端的 `true` 也返回空数组，iOS 接收层与最终高亮层再各自清空一次，统一按自然句子/segment 高亮；英文、法文、德文、西班牙文、葡萄牙文、意大利文、俄文、印地文等空格分词语言继续使用单词时间戳。响应顶层字段仍精确保持 `audio/audio_format/timestamps/voice_code`，segment 模式只是把 `timestamps` 设为 `[]`。

旧 clone 时间戳只是把容器总时长按 token 字符数加权平摊，既没有观察音频，也把首尾静音、标点停顿和实际语速变化错误分配给单词。新实现不增加 ASR、LLM 或 forced aligner：直接在已生成的最终 WAV 上以 20ms frame / 10ms hop 做一次向量化 RMS 包络，检测真实发声起止与大于约 90ms 的停顿，再用文本词权重给出初始边界，并把内部边界吸附到附近低能量谷。该分析在中国区实测 10 秒约 9ms、60 秒约 49ms、300 秒约 241ms，不占 GPU。

生产 canary 使用同一 V4 克隆音色：英文 6.80 秒音频返回 14 个正文词，首词从真实发声的 0.25 秒开始、末词在 6.16 秒结束；中文 5.44 秒音频返回 0 个时间戳。两次请求均成功，worker `submitted=2/completed=2/failed=0/expired=0`，时间戳分析分别为 6.213ms 与 0.029ms；旧 8880、Nari 和 clone worker 全部健康。美国区只滚动更新并做只读健康检查，未发送合成流量。worker 单测 7/7、iOS 定向测试 5/5，真机包已覆盖安装并启动到 `8D96EFB3-DBC1-52E3-B10D-412C1059D28E`。

这是“不新增一次模型推理”约束下的音频感知近似，不宣称等价于 forced alignment。官方 vLLM-Omni 的 Qwen3-TTS word timestamp 方案实际需要额外部署 `Qwen3-ForcedAligner-0.6B`，且每个句子生成后再跑一次对齐；若将来要求字幕级精确边界，应单独评估该 0.6B 对齐服务的显存、延迟与队列隔离，不能把它伪装成 TTS 本体免费输出。

### 参考录音健壮性 v4 与多样本闭环（2026-08-27）

多语言矩阵发现葡萄牙语连续清晰讲话会被 v3 误拒为 `VOICE_REFERENCE_TOO_NOISY`。该录音 6.569 秒内有 6.489 秒人声，真实非人声不足约 0.1 秒；旧算法在找不到至少 5 个噪声帧时，把最低能量的 15% 人声帧当作房间噪声，算出了不可能的 -2.46dB SNR。v4 不再用人声伪造噪声底：真实非人声证据少于 150ms 时将 SNR 记为未知，并以有效帧的宽带谱平坦度作为保守后备。这样不会因为用户按住录音后立即说满整段而误拒；持续宽带重噪声即使被 VAD 当成人声，仍会被明确拒绝。质量指标新增 `noise_evidence_seconds/noise_estimate_reliable/broadband_flatness`，profile 更新为 `castreader-reference-v4`。

隔离单测 10/10 通过，覆盖“近乎无静音的清晰连续讲话必须通过”和“近乎无静音的持续宽带重噪声必须拒绝”两个新增回归。中国区 clone worker 在队列为空时原子替换并由既有 watchdog 自动拉起；Nari 与旧 8880 未重启，发布前文件保存在 `backups/audio-quality-20260826202646`。

最终端到端矩阵为 29/29：23 个应通过样本覆盖中/英/德/西/法/意/日/韩/葡/俄 10 种语言、多种男声/女声/年龄听感、偏轻音量、轻粉红噪声、轻混响、16k/24k/44.1k/48k、单/双声道、WAV/FLAC、DC offset 和较长首尾静音；6 个应拒绝样本分别命中时长不足、音量过低、削波、重噪声、无人声和多人声的精确 422 错误码。每个通过样本都完成建声、prompt 导出、3 个随机 seed 试听、删除后 prompt 重导入、本语言带合同朗读、跨语言带合同朗读和最终清理。

该轮 worker 从 `submitted/completed=312/312` 到 `496/496`，`failed=0/expired=0`，队列 P95 0.15ms、运行 P95 667.61ms；旧 8880 在每个样本前后共 58/58 探针为 200。结束时残留 `vc_matrix_*` 目录为 0，worker 自 v4 启动后无 ERROR/Traceback/CUDA/OOM/fatal，GPU 使用/总量/剩余为 15693/24564/8389MiB、32°C、利用率 0%。机器可读证据保存在 `artifacts/validation/clone-input-matrix-result-v6.json`。

同一文件 hash `0c311113…5ecc` 随后在美区 GPU 利用率连续 6 秒不高于 2% 的自然空档滚动到国际区 clone adapter。发布前先在美区 CPU 环境运行 10/10 单测，发布过程和发布后都没有发送建声、试听、合成或压力流量；旧 TTS、Nari、固定 TLS PID 分别保持 `3746912/2739704/2235801` 不变，仅 clone adapter 更新为 `3092505`。旧 TTS/Nari/clone/TLS 联合健康探针 20/20 为 200，worker 队列为空且 `submitted/completed/failed/expired=0/0/0/0`；上一版质量门保存在 `/workspace/castreader-clone/backups/reference-v4-20260826T203955Z`。

### DeepFilterNet3 中国区影子 A/B（2026-09-02 / 03）

中国区新增了完全独立的 `/root/autodl-tmp/denoise-shadow` 影子目录，没有替换 18890 worker 文件、没有重启旧 TTS/Nari/clone，也没有改变线上默认建声路径。候选管线固定使用 DeepFilterNet 官方 `v0.5.6` x86_64 musl 静态二进制（SHA-256 `70775e251eee44c0f2451a1e833326cf8bcbbe304d3e7cd12851e6fce72ef7da`）内置的 DeepFilterNet3 模型，48kHz 单声道、12dB attenuation limit、delay compensation、关闭 post-filter；处理后再进入与对照组完全相同的 `castreader-reference-v4` 质量门和 x-vector prompt encoder。

样本采用 DEMAND 的 12 组真实环境噪声，覆盖厨房、客厅、洗衣机、会议室、办公室、食堂、田野、公园、车站、广场、交通路口和地铁；分别与既有中英文干净参考按 12/15dB active SNR 确定性混合。12/12 原始带噪与候选参考均通过现网质量门，随后完成 24 次临时建声与 24 次同文案、同 seed `20260902` 的试听合成；worker `submitted/completed` 从 `59/59` 精确到 `107/107`，`failed/expired=0/0`，结束时测试音色残留为 0，旧 8880、Nari 18094 与 clone 18890 均健康。

候选参考的 SI-SDR 12/12 提升，均值 +6.54dB、中位数 +7.23dB、范围 +0.06～+10.16dB；相对干净原声的 CampPlus cosine 为 0.837～0.977。最终克隆音频相对干净原声的 CampPlus cosine 在 10/12 组提升，平均增量 +0.0330；会议室背景人声与车站两组分别为 -0.0253、-0.0025，说明普通单通道降噪不能可靠消除同类人声，且上线策略必须保留 clean bypass、声纹保护和可回退。两组克隆结果削波率均为 0。CPU RTF 均值 0.279（0.247～0.318），包含每条样本重复加载静态模型的冷启动开销。完整盲听、标注音频和机器可读指标保存在 `artifacts/denoise-ab-20260902/china/ab-20260902-atten12/`。

## 明日验收前硬门

**结论：当前止血架构通过明日的新 TTS/声音克隆功能与单卡稳定性验收。** 该结论覆盖 iOS 全链路、Kokoro 四字段兼容、长文正文守恒、中国区隔离长稳与故障恢复、美区固定 TLS 生产桥接，以及旧预设音色纯标点长尾修复；不等价于已经具备卡级高可用。

1. 6000 次长稳成功率必须为 100%，不得出现 CUDA error、OOM、空音频或合同错误；旧 TTS 探针不得出现非 200。
2. 美区只观察真实流量，不发送压力流量；worker 的 `failed/expired`、队列深度、质量拒绝和进程 uptime 必须稳定。
3. Vercel 新生产部署的 voice-clone 路由不得出现新增 5xx；美区固定 TLS 与中国区受管私有隧道必须持续可用；Cloudflare Quick Tunnel 保持停用。
4. iOS 继续接收与 Kokoro 相同的 `audio/audio_format/timestamps/voice_code`，前台与预取分别发送 `interactive/prefetch`，切页取消不得清空已创建音色。
5. 一张卡仍是物理单点。若要对外承诺卡级无缝故障转移，必须进入阶段 C/D，至少配置第二张预热 GPU 和 durable lease queue。
