# 后端 TTS / 解读观察

本轮仅检查后端。观察到的预设 TTS 供给和国际区讲解生成正常，未发现本小时新增的后端 HTTP、模型错误或区域、版本漂移。**整体结论仍是证据不足**：两区克隆和中国区解读缺少本窗口的实际调用样本，24 小时尚未结束。

主观察窗从 2026-09-06 18:37:52.522573 UTC 开始，固定于 2026-09-07 18:37:52.522573 UTC 结束。本次主采集截止 23:54:12.961358 UTC，约已观察 5 小时 16 分钟。专门后端日志截止 23:53:17.725 UTC；本小时窗口为 22:52:47.445 至该截止。读取后的健康状态另列，不计入窗口请求。

| 区域与服务 | 本轮服务端证据 | 判断范围 |
|---|---|---|
| 国际区 Kokoro / Global 网关 | 本小时 1,890 条均 HTTP 200，非空响应体，完成事件齐全；全部与美国代理唯一关联。网关结束耗时 P50 572 ms、P95 1,570 ms、最大 3,728 ms | 已返回请求记录范围的供给符合预期；不是端侧首音或播放耗时 |
| 国际区 Direct TTS | 主窗累计 2,217 个 200；既有 12 条连接断开，数量未增加；HTTP 4xx/5xx 为 0。较上轮新增 333 个 200 | 未新增 HTTP 供给失败；断开不能计作 HTTP 成功或失败 |
| 中国区预设 TTS | 203 个通用 TTS POST 全为 200，包含既有监控；61 轮预设音频合同均完整解码、余文归零。国际区相应监控 60/60 健康 | 可见 HTTP 层及预设音频合同符合预期；通用入口缺 voice 字段，不逐请求硬贴模型标签 |
| 国际区 QuickRead | 39 份窗口内修改的任务均 ready 且有首块；31 份所有讲解块已生成，8 份部分生成但仍可续。当前无排队 | 讲解生成与持久续块符合可见预期；没有完整 HTTP 请求账本，不计算成功率 |
| 中国区 QuickRead | 窗口 journal 记录 0、持久任务修改 0；读取时健康、无排队 | 缺实际窗口样本，不能认定全链路成功 |
| 国际区克隆 | 窗口内没有结构化合成记录；读取时健康、队列 0、进程沿用；启动以来累计 173 完成、0 失败、0 过期 | 窗口样本不足；累计计数不充当本窗口请求量 |
| 中国区克隆 | 读取时健康、队列 0；累计 4 完成、0 失败、0 过期 | 窗口样本不足；健康和累计计数不能代替实际调用验证 |

国际区 QuickRead 的日志有一条 `fast-block0 error`，时间为 21:42:46 UTC。脱敏消息 SHA 与生产使用的固定错误 `request_disconnected` 精确匹配；不是模型返回错误的证据。运行源码确认只监听实际请求 aborted 和响应未结束时的 socket close，错误处理在响应已经关闭时不会继续写 502。连接为何断开仍未知，不能推断用户主动退出，也不能证明这次已完整交付。该条早于本小时增量窗口，本小时没有新增相同日志。

39 份任务按**文件修改时间**选取，不能称为 39 个新任务。其规格没有可靠的显式创建时间，31 份完整生成和 8 份部分 ready 也不等于音频交付或用户听完。另有 1 个历史文件不符合当前解析结构，修改时间在观察窗外，未新增计作故障。

两区 QuickRead 的 server 文件 SHA 均与已审阅发布回执相同，request lifecycle 文件 SHA 与审阅源码相同；进程沿用。中国区 Next、QuickRead、两条模型隧道和 Nginx 均 active，NRestarts 为 0。美国 Kokoro R134 和代理 v2 的进程、源码、slot、revision 校验通过；两区探针没有区域元数据不一致。这些检查不能扩写成全链路物理地域证明。

美国代理本小时 2,210 次接入、2,209 次完成 200，无错误、取消或路由身份变化。该计数按事件时间统计，包含前窗进入、本窗结束的请求；截止时还有 2 个本窗请求未出现完成事件，其中 1 个是上述 Global 请求。Global 返回结果已经含它截止后的完成，故不能把代理截止差异认定为失败。另有 320 个未携带 attempt 的代理接入没有落入本次 Global 请求集合，尚不对它们硬指定调用方。

旧窗口记录继续保留：Direct 的 3 个 400、1 个维护时 502、4 个 504，以及 Global 核心的 4 个 504，未增加或清零。主采集器的原 automaticVerdict 包含客户端事件，原件保留；本轮另列 backendVerdict，客户端、博客及支付数据不参与本任务结论和通知。

本轮没有改生产代码、配置、路由，没有部署、重启或新增合成。只新增本地脱敏报告和只读采集辅助脚本。初次辅助读取中 CN journal 不接受 ISO 参数，已改用 epoch 查询成功；初次 job 统计错误依赖缺失的 created_at，已改为修改时间记录集合。初次文件保留作采集纠错记录，正式结论使用 `*-backend-supply-v2.json`，这些采集问题不是生产故障。

主要证据：[后端结论](/Users/xuxuheng/Documents/CastReader/reports/audio-playback-recovery-rollout-20260907/monitoring/observations/20260906T2353Z/heartbeat-review.json)、[前后计数](/Users/xuxuheng/Documents/CastReader/reports/audio-playback-recovery-rollout-20260907/monitoring/observations/20260906T2353Z/backend-snapshot-comparison.json)、[Global 与代理关联](/Users/xuxuheng/Documents/CastReader/reports/audio-playback-recovery-rollout-20260907/monitoring/observations/20260906T2353Z/vercel-proxy-join-summary.json)、[国际区解读](/Users/xuxuheng/Documents/CastReader/reports/audio-playback-recovery-rollout-20260907/monitoring/observations/20260906T2353Z/us-backend-supply-v2.json)、[中国区后端](/Users/xuxuheng/Documents/CastReader/reports/audio-playback-recovery-rollout-20260907/monitoring/observations/20260906T2353Z/cn-backend-supply-v2.json)、[国际区克隆](/Users/xuxuheng/Documents/CastReader/reports/audio-playback-recovery-rollout-20260907/monitoring/observations/20260906T2353Z/us-gpu-backend-supply-v2.json)、[解读错误分类](/Users/xuxuheng/Documents/CastReader/reports/audio-playback-recovery-rollout-20260907/monitoring/observations/20260906T2353Z/us-quickread-disconnect-evidence-check.json)、[发布身份](/Users/xuxuheng/Documents/CastReader/reports/audio-playback-recovery-rollout-20260907/monitoring/observations/20260906T2353Z/quickread-identity-comparison.json)。
