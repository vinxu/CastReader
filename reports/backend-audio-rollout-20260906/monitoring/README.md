# 本次上线后的 24 小时验收

入口：

```bash
python3 /Users/xuxuheng/Documents/CastReader/reports/backend-audio-rollout-20260906/monitoring/collect_rollout_acceptance.py
```

状态与最新结果沿用 `../../backend-audio-iteration-20260906/monitoring/acceptance-state.json` 和 `latest-acceptance.json`。旧 collector 和测试保留原有证据哈希，新入口复用其数据采集与判定，再校验本次新增的稳定 US 入口。

正式窗口已启动：UTC `2026-09-06T05:01:25Z` 至 `2026-09-07T05:01:25Z`（北京时间 9 月 6 日 13:01:25 至 9 月 7 日 13:01:25）。自动化 `24` 已回读为 ACTIVE。起点配置与第一份结果分别固化在 `observation-start-state.json`、`observation-initial-snapshot.json`。初次采集窗口仅 13 秒，尚无五分钟探针周期和客户端样本，判为证据不足是预期结果，不能当作故障或 24 小时通过。

- `waiting_release` 不采集、不开始计时；全部必需组件真实上线、回读后才进入 `observing`。
- 起止点在状态文件中一次性固定，终点为起点加 86400 秒。自动任务到期后按同一窗口采集最终数据，随后暂停。
- 基础来源：US/CN 已有五分钟供给探针、Global 客户端事件、Vercel 核心请求错误、旧版直连网关请求，以及 Global 实际部署身份。
- 当前模型由稳定入口的实际 slot 决定。新增只读采集核对 proxy 源文件、进程与监听端口、持久化 revision、健康状态，以及当前模型的 Supervisor PID、监听 PID、cwd 和 G2P 源 SHA；不加载模型或合成音频。
- 旧 `current` 链接保留 R132 温备含义，仅作为 `legacy_blue` 证据。最终 `kokoro_us` 必须来自正在接流量的 green/R133 实例，再用原验收逻辑重新判定。
- 供给、客户端证据和数据覆盖分别判断。探针成功不能覆盖客户端技术失败；凭据/数据读取失败、版本漂移、缺样本或缺排空可信证据均不会自动算通过。

测试：新增适配 10 项、原验收 28 项通过；新增采集器已在真实 US 主机只读核验 green/R133 的 PID、端口、目录与源文件。发布前等待状态也验证为零采集。

这个观察窗口不等于四端每次播放的端到端证明；旧客户端是否正确收到首音频、用户结束原因和克隆/解读样本覆盖需要分别报告。两模型共用同一 US GPU 主机，也不能因此宣称已完成主机级容灾。
