# CastReader 核心后端修复发布基线与切换合同

基线采集时间：2026-09-05 23:15 CST；这是切换前的历史快照。

本文为 Kokoro G2P 与 QuickRead deadline/cancel/resume 修复保留切换前基线和发布要求。下列基线采集当时只读；后续已执行的构建、探针和生产切换记录在[当前上线总表](../README.md)，不可把本文旧 PID 和目录当作当前线上状态。任何下一次切换都必须重新采集并做 CAS。实际切换事务和观测到的停机边界以对应上线回执为准；旧实例尚无 admission pause 时，重复空闲检查不能证明零竞态或零停机。

## 1. 切换前线上基线（历史快照）

| 区域/服务 | 当前进程与版本 | 健康 | 可用于 CAS 的完整证据 |
|---|---|---|---|
| US Kokoro | `current → /workspace/castreader-runtime/releases/20260904-kokoro-playback-us-r131b`; Kokoro PID/start `1158018/528101142` | 8880、clone 8890、Nari 8094 均 HTTP 200 | [us-gpu-baseline.json](./us-gpu-baseline.json) |
| CN Kokoro | 最后证明为 `/root/autodl-tmp/castreader-runtime/releases/20260904-kokoro-playback-cn-r131b`; Kokoro `640207/2020118568` | 2026-09-05 18:52 CST 快照三端均 HTTP 200 | [cn-gpu-baseline.json](./cn-gpu-baseline.json)；本轮刷新被 SSH provider 关闭，必须在切换前重取 |
| US QuickRead | PID/start `507570/168905163`; `/root/castreader/video-pipeline → /root/castreader/routing-releases/20260904-quickread-gif-retirement` | `/health`: queue 0、active false | [us-quickread-baseline.json](./us-quickread-baseline.json) |
| CN QuickRead | PID/start `1067993/232505929`; `current → /opt/castreader-quickread-cn/releases/20260904-quickread-gif-retirement` | `/health`: queue 0、active 0；systemd `NRestarts=0` | [cn-quickread-baseline.json](./cn-quickread-baseline.json) |

US Kokoro 的 45 个 `api/src` Python/JSON 文件有排序文件清单和组合 SHA。当前 Kokoro、clone、Nari 的 PID、start ticks、cwd 与 9 月 4 日 R131b 切换回执逐项一致。US Supervisor 的 Kokoro 配置与 launcher 也已单独哈希；实际 program 是 `castreader-tts`，受保护的另两个 program 是 `castreader-clone` 与 `castreader-nari-base`。

CN Kokoro 本轮不能取得新鲜 SSH 证据。目录内 JSON 明确标为 last-proven snapshot；其 PID、start ticks、cwd 与 9 月 4 日切换回执一致，但任何实际变更前必须由当前可连接的 operator 更新它。禁止通过换入口绕过 provider 限制。

两区 QuickRead 当前关键文件与 9 月 4 日激活清单全部匹配，详见 [baseline-comparison.json](./baseline-comparison.json)。不过旧激活清单漏了一个关键区域差异：

- US `tools/extract-content.mjs`: `8eba87646a36fc5969b3fd989e9093bc5c3d77d80d03bfb5d3184197cad96a8e`
- CN `tools/extract-content.mjs`: `199489b2b665967ee03b460590f3ca43a4951a2c9126c19faf5aef796fde8533`

所以新修复不能把任一区整份 `extract-content.mjs` 覆盖到另一区。必须从两个现场基线分别打锚点补丁，并在新 manifest 同时列出各自 before/after SHA。

CN QuickRead 私有环境文件仍为 mode `600`，当前 SHA 与 9 月 4 日激活值相同；US 只记录运行进程环境字节 SHA，不输出变量和值。这些 SHA 只用于检测切换期间配置是否漂移，不能被当作恢复内容；恢复仍需私有环境备份。

## 2. 发布制品必须包含什么

一份可上线制品需要一个不含密钥的 `release-manifest.json`，最少包含：

```json
{
  "schema_version": 1,
  "service": "kokoro|quickread",
  "region": "us|cn",
  "source_commit": "full git sha",
  "artifact_sha256": "sha256",
  "before": {
    "release_target": "absolute path",
    "runtime_tree_sha256": "sha256",
    "pid": 0,
    "start_ticks": "0",
    "private_environment_sha256": "sha256 or null"
  },
  "protected_processes": [
    {"role": "clone", "pid": 0, "start_ticks": "0", "cwd": "absolute path"},
    {"role": "nari", "pid": 0, "start_ticks": "0", "cwd": "absolute path"}
  ],
  "files": [
    {"path": "relative/path", "before_sha256": "sha256", "after_sha256": "sha256"}
  ],
  "rollback_target": "absolute immutable release path",
  "backup_receipt": {"provider": "same-region private storage", "verified": true}
}
```

Kokoro manifest 要覆盖整个 `api/src`、模型包清单、launcher、Supervisor/watchdog 配置和区域 voice/model catalog。QuickRead manifest 要覆盖 `server/`、`tools/`、`deploy/`、`package.json`、`pnpm-lock.yaml`、process-manager 配置；不能再只列六七个 patch 文件。

构建阶段就应验证每个 `before_sha256`。现场安装阶段再次验证。任一不符意味着同时有人改过生产或基线选错，必须停止并重建制品；不能现场手工解冲突。

## 3. Kokoro 切换：只动普通 TTS

### 切换前

1. 读取节点操作指南。US 必须先读 `/etc/vast-agents-guide.md`；CN 当前没有发现 `AGENTS.md`，仍按本仓库备份 SOP 执行。
2. 创建全新、不可变 release 目录。不能修改 `current` 指向的目录。
3. 核对完整 source/model/voice/launcher manifest；核对当前 private off-host 备份及完整 readback。CN 恢复资产必须仍在上海私有 COS，US 恢复资产留在其国际存储；不能跨区借备份。
4. 在隔离端口启动候选。只有候选服务可以加载新代码；production 8880、clone、Nari 不动。
5. 运行固定、无用户内容的 G2P 回归与多段 TTS 合同检查，确认每段非空、正文完整、协议 JSON/音频可解码。真实合成 probe 由发布 operator 在用户授权窗口执行，本次基线任务未执行。
6. 切换瞬间重新获取 `current target + Kokoro PID/start_ticks/cwd + source tree SHA + launcher/config SHA + clone/Nari PID/start_ticks/cwd` 并与 manifest 做 CAS。

### 排空与原子切换

- 入口先停止给旧 Kokoro 新建请求，再等待已有连接/active count 归零；候选和生产不能同时争用同一张 24 GB GPU 做大批合成。
- 只向 Kokoro 的精确 PID 发送 `TERM`。US 使用 Supervisor program `castreader-tts`；不能执行 `supervisorctl restart all`。CN 使用 worker 确认后的 Kokoro 专用入口；不能重启 clone/Nari/watchdog。
- 原子替换 `current` symlink，再启动同一个 Kokoro program。clone 和 Nari 的 PID/start_ticks 必须前后相同。
- 本地 8880 health 通过后再恢复入口新请求；随后检查对应区域公开 gateway 的 metadata、固定区域、完整响应和多段连续性。

### 回滚

回滚目标必须是切换前 CAS 中的精确 immutable release。停止的仍只能是新 Kokoro PID；原子把 `current` 指回旧 release，启动同一 Kokoro program，核对旧 source tree SHA 和三个 health。clone/Nari identity 发生变化时不能继续自动操作，应保留现场给 operator 诊断。

US `/workspace` 不是持久卷。即使旧 release 仍在本机，也不能把它当唯一回滚；宿主回收时必须从已验证的 off-host 恢复集还原。

## 4. QuickRead 切换：保留任务并恢复续块

### 区域化制品

同一 Git commit 生成两个区域制品，但从两个不同的现场 base 构造：

1. 完整复制 US 当前 immutable release 到 US staging；校验 US before tree SHA；只应用经过审查的 shared changes 和 US anchor patch。
2. 完整复制 CN 当前 immutable release到 CN staging；校验 CN before tree SHA；只应用相同 shared changes、CN `llm-provider` 与 CN anchor patch。
3. 分别生成完整 after tree manifest。US 不能出现 CN DeepSeek/本区路径；CN 不能出现 Gemini、Anthropic、OpenRouter、US proxy 或 foreign fallback。
4. Candidate 使用独立端口和独立测试 job 目录。加载私有 env 后最后覆盖 candidate `PORT`；9 月 4 日曾因 env 中 `PORT=7777` 覆盖 17777 而 bind 冲突，不能重复。

### 合同测试

必须覆盖：

- 客户端在 job capability 发布前断开：排队项被删除、reservation 释放、provider 被 abort、没有孤儿任务。
- block0 已原子落盘并把 job id 发给客户端后断开：原计划继续完成，或同一 job 从 `planning` checkpoint 恢复；不能把已经开始播放的任务取消。
- 同一 `job_id:block_idx` 的并发 continuation 只发一次 LLM 请求，所有 waiter 获得同一结果；一个 waiter 断开不取消其他 waiter。
- continuation 在返回客户端前完成耐久 checkpoint；进程退出后仍能 compose 已播 block 并生成下一块。
- block0 后崩溃/重启：同 job id 恢复，不重扣额度，不重播 block0，不丢正文。
- `paragraphs` 为 null、空数组、全是短片段、CJK 无空格标点时，从已有正文确定性重建；顺序和正文不丢不重。
- route→planner/block→provider 使用同一个 deadline/abort signal；curl child 和 fetch 都在 deadline 后退出。技术超时返回可重试故障，不伪装成业务额度拒绝。
- CN 仅 DeepSeek 固定 endpoint；Global 仅其已批准的国际 provider 链，不跨区互相兜底。

当前实现 worktree 的独立审查记录见本目录后续 review 文件。测试入口以仓库现有 Node tests 为基础：

```bash
cd /Users/xuxuheng/Documents/MyProject/.worktrees/readout-desktop-quickread-cancellation-recovery-20260905
node --test \
  scripts/video-pipeline/server/*.test.mjs \
  scripts/video-pipeline/tools/llm-provider.test.mjs \
  scripts/video-pipeline/tools/extract-content-cn-provider.test.mjs \
  scripts/video-pipeline/tools/regional-routing.test.mjs
```

### 候选、排空和切换

- US candidate 在独立端口启动，PM2 生产 symlink 仍指旧 release。CN candidate 同样用独立端口，不能让 `/etc/castreader/quickread-cn.env` 中的 production `PORT` 抢占 7777。
- Candidate 使用复制的 fixture/job store；不能对 production jobs 做写测试。
- 切换前等待 production `/health` queue 0、active false/0，并核对 process identity、symlink target、完整 tree SHA、environment SHA、PM2/systemd config SHA。然后停止新 admission，等待现有任务 checkpoint/flush 完成。
- 原子替换 symlink。US 对精确 `quickread` program reload；CN 对精确 `castreader-quickread-cn.service` restart。禁止重启整机、Nginx、TTS tunnel、PostgreSQL 或其他服务。
- 启动后先读取 health、进程 cwd、after tree SHA、区域 provider/TTS base 的脱敏能力，再恢复流量。持久化 job fixture 验证只能读预置的非用户测试 job。
- 失败时在同一事务里把 symlink 指回 manifest 的旧 target，恢复旧 environment（若本次有变），重启同一 program，并验证 old tree SHA。不要删除失败的新 release，保留日志和 manifest 供诊断。

CN 当前 systemd 使用 `KillSignal=TERM`、`TimeoutStopSec=20s`。新 server 若要保证计划 checkpoint，必须在 20 秒内停止 admission、等待有限的 in-flight checkpoint 并 flush；超时不应继续接新任务。US PM2 当前未显式设置 `kill_timeout`，发布前应在候选配置中明确一个覆盖最大 checkpoint 时长的值，并测试 TERM 路径。

## 5. 禁止使用的旧发布方式

不要执行 [deploy.sh](/Users/xuxuheng/Documents/MyProject/readout-desktop/scripts/video-pipeline/deploy/deploy.sh:37)。它在第 38 行使用 `rsync --delete` 覆盖 mutable 目录，并在第 50 行直接 `pm2 startOrReload`。这会抹掉两个区域实际不同的 `extract-content.mjs`，也没有完整 before SHA/CAS、immutable release、排空或事务回滚。

[DEPLOY.md](/Users/xuxuheng/Documents/MyProject/readout-desktop/scripts/video-pipeline/deploy/DEPLOY.md:39) 的新加坡、GIF、本地素材与旧 Caddy 步骤是历史说明；当前生产拓扑已不同，不能作为本次发布依据。第 129 行的“restart/stop”也不是回滚，因为它没有恢复旧字节。

同样禁止：

- `rsync --delete` 到 production current；
- 直接编辑 current release；
- `pm2 restart all`、`supervisorctl restart all`、重启 CN watchdog；
- 用 US 文件、模型或对象救 CN，或用 CN 节点救 Global；
- 在切换前没有重新 CAS 的情况下复用本报告 PID；
- 用真实用户正文、录音或随机用户 clone voice 做 probe。

## 6. 同区备用与发布权限

详情见 [resource-control-readiness.json](./resource-control-readiness.json) 与 [us-standby-offers.json](./us-standby-offers.json)。

- 当前 US Vast 控制面只显示一台已租生产 4090，没有已验证的暖备用。市场只读快照有两台不同 physical machine 的 RTX 4090 24 GB 候选：约 `$0.39941/h`（约 `$291.57/730h`）和 `$0.41704/h`（约 `$304.44/730h`，static IP）。未购买；报价会变化。
- CN `castreader-train6000` 当前 SSH connection refused。`westd` 只是 provider zone 标签，本次没有 AutoDL/Seeta 控制面权限来证明它仍在租、位于中国大陆、可启动或价格，因此不能算同区备用。
- 两区当前都没有“恢复完成、模型/voice parity、预热、健康、可接管”的暖 GPU。API/网关多实例不能弥补单 GPU 供给。
- `vinxu/readout-desktop` 的 main 与 `scmyyan/readout-web` 的 production beta 都观察到 `protected:false`。Web 最新 beta 为 `3ce12a7c...`，maintenance workflow run `33934272517` 成功。分支没有硬保护时，生产门禁必须由 exact-SHA workflow、artifact manifest 和现场 CAS 三层组成。
- 当前凭据能只读 GitHub runs；本次没有通过触发 workflow 来测试发布权限。US/CN SSH、US Supervisor/PM2、CN sudo/systemd 已可读；CN 上海 COS bundle 存在。9 月 4 日备份 readback 成立，但本次没有生产写探针，不能把它表述为今天仍有写权限或已完成冷恢复演练。

## 7. 发布前的最后 CAS 清单

真正切换前的单一 operator 必须在同一分钟内取得并写入最终回执：

1. Git source commit、区域 patch SHA、完整 artifact SHA；
2. 当前 symlink target、PID、start ticks、cwd、完整 runtime tree SHA；
3. 私有 environment SHA 与启动配置 SHA；
4. Kokoro 的 clone/Nari protected identity；
5. 当前 queue/active/连接数与排空完成时间；
6. 当前版和新版本各自的同区 private backup/readback receipt；
7. candidate contract test result 与固定 probe hash；
8. rollback target 的完整 tree SHA；
9. 切换后新 PID/start ticks/cwd、health、公开路由区域 metadata；
10. 任何一项失败时的回滚完成值。

这份最终回执应由发布脚本自动生成。人工只选择已审制品和是否进入切换；不在生产机临时编辑代码或拼命令。
