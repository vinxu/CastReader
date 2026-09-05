# 美国区核心音频连续供给监控上线回执

完成时间：2026-09-06 00:21 CST。目标是美国区 **QuickRead 控制主机** `140.82.14.49`，不是 GPU 计算机。该变更只增加独立的 systemd oneshot/timer 和本机状态目录；没有修改或重启 QuickRead、GPU TTS、clone、Nari、代理或 Vercel 项目，也没有配置外部通知。

## 制品与现场前提

- 源提交：`272d3148d6a93cec079d7dc649a78d406e5fe36f`。
- 本地制品：`/tmp/castreader-core-audio-monitor-272d3148.tar.gz`，12,698 bytes，SHA-256 `5c085a6187cd3ed9b13102369ff09c559dc7ad3006d499ceb4f033ce02a5f0d3`。
- 远端不可变 release：`/opt/castreader-core-audio-monitor/releases/272d3148-5c085a61`；`current` 原子指向该目录。
- 主机是 Ubuntu 24.04 x86_64，现场已有 `/usr/bin/node` v22.23.2 和 `/usr/bin/ffmpeg` 6.1.1；没有升级或替换系统 Node、ffmpeg。
- 安装前 `/opt/castreader-core-audio-monitor`、两个同名 systemd unit 和同名 timer 均不存在。
- 安装前 QuickRead 当前树仍是 `/root/castreader/routing-releases/20260904-quickread-gif-retirement`，源码树 SHA-256 `2322e420b31fee4c1664cf9a4c8dc9ab67962009c358caab4514a6f11b8582a7`；PM2 PID `507570`、启动毫秒 `1788498138981`、restart count `5`、状态 online；健康值 queue 0、active false。代理配置树 SHA-256 `a6f8e3a54cb7f94fe7895f789701d2f7523613b5583e46bcd0d8eae7c995f918`。完整脱敏基线见 [us-monitor-rollout-before.json](/Users/xuxuheng/Documents/CastReader/reports/backend-core-fixes-20260905/release/us-monitor-rollout-before.json)。

## 监控合同

美国区目标在 [probe-core.mjs](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-release-guard-20260905/scripts/core-audio-monitor/probe-core.mjs:10) 固定为 `https://api.castreader.ai/api/captioned_speech_partly`、基础音色 `af_heart` 和一段不含用户内容的诊断正文。公网端点只允许该区的固定域名和固定路径，带凭据 URL、其他域名、端口或路径在请求前拒绝；见同文件第 52–70 行。

检查会持续提交响应中的 `unprocessed_text`，直到余文归零；至少需要两个 segment。每一段 MP3 都通过 ffmpeg stdin 完整解码，不把音频写盘；时间戳只影响 `alignment_degraded`，不会把可播放音频判成供给失败。单段上限 35 秒、整轮上限 120 秒、最多 6 段；systemd 外层上限 150 秒。每轮单飞锁和原子状态写入见 [run.mjs](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-release-guard-20260905/scripts/core-audio-monitor/run.mjs:19) 与 [state-store.mjs](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-release-guard-20260905/scripts/core-audio-monitor/state-store.mjs:18)。

unit 使用 DynamicUser、只读系统、独立 0700 StateDirectory，不含重启业务的动作，见 [service unit](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-release-guard-20260905/scripts/core-audio-monitor/systemd/castreader-core-audio-monitor@.service:6)。timer 每 5 分钟执行、带最多 15 秒抖动和 Persistent catch-up，见 [timer unit](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-release-guard-20260905/scripts/core-audio-monitor/systemd/castreader-core-audio-monitor@.timer:4)。告警只写本机 `notificationPolicy: dry-run` envelope，没有 webhook sender。

## 先验证再启用

安装脚本在写入前同时核对制品、Node、QuickRead target/source/PID/start/restart、queue/active 和代理树，随后只安装新目录和新 unit。安装事务见 [us-monitor-install-transaction.txt](/Users/xuxuheng/Documents/CastReader/reports/backend-core-fixes-20260905/release/us-monitor-install-transaction.txt)。

timer 仍为 disabled 时，2026-09-06 00:15:00 CST 执行一次手动 oneshot：

- 状态 healthy，`supplyOk=true`、`alignmentOk=true`；
- 2 个 segment，处理字符数 366 + 211，余文 211 → 0；
- 音频 369,837 + 230,445 bytes，总 600,282 bytes；
- 每段完整解码时长 23.088s、14.376s；
- 两段 upstream node 都是 `castreader-us4090`，并已在代码内验证响应区域必须为 `global`；
- 总请求耗时 2,349ms；结果目录 1 份，告警目录 0 份。

手动结果见 [us-monitor-manual-oneshot.json](/Users/xuxuheng/Documents/CastReader/reports/backend-core-fixes-20260905/release/us-monitor-manual-oneshot.json)。只有上述合同和新一轮业务 CAS 全部通过，才在 00:16:09 CST 启用 `castreader-core-audio-monitor@us.timer`。

Persistent catch-up 在 00:16:12 CST 完成，首次正常 5 分钟调度在 00:21:14 CST 完成；两轮同样是 healthy、2 段、余文 0、全段可解码。timer 当前 enabled/active/waiting，service 最近退出码 0，累计 3 份结果、0 份告警。见 [us-monitor-post-enable-status.json](/Users/xuxuheng/Documents/CastReader/reports/backend-core-fixes-20260905/release/us-monitor-post-enable-status.json)。

## 与既有 Vercel 检查的边界

既有 `readout-web` 仍保留 `/api/cron/tts-health-probe` 的 Vercel Cron，每 5 分钟一次，配置在 [vercel.json](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-release-guard-20260905/vercel.json:84)。它先做一句短文本的单请求可用性检查，再轮换最多一个补充语言，并沿用 Redis/飞书告警状态；入口说明见 [route.ts](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-release-guard-20260905/src/app/api/cron/tts-health-probe/route.ts:8)。

本次 systemd monitor 是新增的完整多段连续供给检查：它验证余文推进、每段可解码、区域响应和最终余文归零，状态只留在美国控制主机。它没有迁移、关闭、修改或替代现有 Vercel Cron；两项覆盖不同。当前也没有外发通知，所以 systemd monitor 的故障只会形成本机 dry-run envelope，仍需后续经审阅的通知消费者才能主动触达值班人。

## 前后 CAS 与回滚

启用后的 QuickRead target、52 个源码文件树、PM2 PID/start/restart、健康状态、代理配置树和 Node 二进制均与安装前一致，证明本次没有碰业务发布。完整后置快照见 [us-monitor-rollout-after.json](/Users/xuxuheng/Documents/CastReader/reports/backend-core-fixes-20260905/release/us-monitor-rollout-after.json)，汇总与证据 SHA 见 [us-monitor-rollout-receipt.json](/Users/xuxuheng/Documents/CastReader/reports/backend-core-fixes-20260905/release/us-monitor-rollout-receipt.json)。

若只回滚该监控：先 `systemctl disable --now castreader-core-audio-monitor@us.timer`，删除两个新 unit 和 `/opt/castreader-core-audio-monitor`，再 `systemctl daemon-reload`。它没有改业务 target，因此不需要回滚 QuickRead、代理或 GPU。
