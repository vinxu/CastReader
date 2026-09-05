# CN 持续音频监控安装审阅稿

状态：**已于 2026-09-05 23:58 CST 完成 immutable 安装、人工多段 gate 和 CN timer 启用。** 业务 Next、QuickRead、Nginx、两个隧道和 Voice Gift 的进程、源码树与配置 CAS 均未变化；没有配置外发通知。最终证据见 [cn-monitor-rollout-receipt.json](./cn-monitor-rollout-receipt.json)，完整前后快照见 [cn-monitor-rollout-before.json](./cn-monitor-rollout-before.json) 与 [cn-monitor-rollout-after.json](./cn-monitor-rollout-after.json)。

第一次 staged 制品暴露了一个真实启动缺口：Node 经 `current` symlink 执行时，旧版入口的字符串 URL 比较没有调用 `main()`，于是 systemd 在 0.09 秒内假成功且没有状态文件。Timer 当时仍关闭，该次 oneshot 没有发网络请求。修复加入 realpath 入口判断与 symlink CLI 回归，commit 为 `272d3148d6a93cec079d7dc649a78d406e5fe36f`。修复后的人工 gate 完整生成 3 段、逐段解码、余文从 61 字推进到 0；启用 timer 后第一次 `Persistent` catch-up 也为 3 段健康。旧 release 只为取证保留，不是有效回滚版本；真正回滚目标是安装前的“monitor 不存在”。

此前现场兼容性检查时间为 2026-09-05 15:42:47 CST；唯一一次安装前固定诊断请求时间为 15:43:18.930 CST。脱敏机器证据和该请求边界见 [cn-core-audio-monitor-compatibility.json](./cn-core-audio-monitor-compatibility.json)。

## 1. 结论与适用范围

中国 API 主机满足当前监控制品的运行条件：Ubuntu 22.04、systemd 249、Node 22.23.2、系统源 ffmpeg/ffprobe 4.4.2 均已存在，根盘当时约 35.1 GB 可用。现场未发现同名 monitor release/state 目录、同名 unit/timer 或相关系统 cron，因此没有已知命名冲突。

现网 `POST https://api.castreader.cn/api/captioned_speech_partly` 在唯一一次固定、无用户内容、基础音色 `zf_001` 的请求中返回 200，`x-castreader-upstream-region: cn`、精确余文推进和可完整解码的 MP3 均成立。监控只把这个 region header 当区域硬条件；`x-castreader-upstream-source`、node、revision、route header 只记录，不因缺失或值变化判定供给失败。因此现有健康服务不会因为 source 仍为 `cn-environment` 而被误报死亡。实现位置是 [probe-core.mjs](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-release-guard-20260905/scripts/core-audio-monitor/probe-core.mjs:180)，region 硬校验在第 206–208 行，其他元数据仅在第 234–237 行采集。

这次单请求仅证明入口兼容、第一段可解码且余文向前推进。它没有执行完整 monitor loop，不能据此宣称多段连续供给已经通过。安装后第一次人工 oneshot 才会沿 `unprocessed_text` 继续，要求至少两段并逐段解码；循环与最少两段合同见 [probe-core.mjs](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-release-guard-20260905/scripts/core-audio-monitor/probe-core.mjs:257)。本次准备阶段不会再发第二个合成请求。

## 2. 制品身份

最终制品来自 `scmyyan/readout-web` commit `272d3148d6a93cec079d7dc649a78d406e5fe36f`：

```text
local path  /tmp/castreader-core-audio-monitor-272d3148.tar.gz
bytes       12698
sha256      5c085a6187cd3ed9b13102369ff09c559dc7ad3006d499ceb4f033ce02a5f0d3
```

可复现构建命令：

```bash
git -C /Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-release-guard-20260905 \
  archive --format=tar 272d3148:scripts/core-audio-monitor |
  gzip -n > /tmp/castreader-core-audio-monitor-272d3148.tar.gz
```

归档内九个文件的 SHA-256 可由 commit 重建核对。仓库的 19 项测试不联网、不合成音频；它们覆盖区域端点拒绝、redirect 拒绝、余文分区、多段/单段判定、MP3 解码合同、时间戳降级、单飞锁、原子状态、保留期限、unit 不含重启命令，以及 production `current` symlink 确实执行 CLI。测试入口：

```bash
cd /Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-release-guard-20260905
node --test scripts/core-audio-monitor/*.test.mjs
```

## 3. 首次安装前 CAS

下面是 23:53 CST 首次 staged 安装实际使用的 absent-state gate。它绑定初版归档；该版随后在人工 oneshot 暴露 symlink 启动缺口，因此没有启用 timer。最终修复制品在切换 `current` 前又执行一次完整业务 CAS，并额外要求 current 精确指向这份初版、timer 仍为 disabled/inactive；完整命令输出分别保存在 [cn-monitor-install-transaction.txt](./cn-monitor-install-transaction.txt) 和 [cn-monitor-symlink-fix-transaction.txt](./cn-monitor-symlink-fix-transaction.txt)。命令不读取或输出业务环境变量：

```bash
set -euo pipefail

artifact=/tmp/castreader-core-audio-monitor-37d6f4d8.tar.gz
expected=b12f3afd80a209e3dba38892d9cf14120dd02576817937589d84c54b6d85d4eb
actual=$(sha256sum "$artifact" | awk '{print $1}')
test "$actual" = "$expected"
test "$(stat -c %s "$artifact")" = 12257

test ! -e /opt/castreader-core-audio-monitor/current
test ! -e /opt/castreader-core-audio-monitor/.current.new
test ! -e /opt/castreader-core-audio-monitor/releases/37d6f4d8-b12f3afd
test ! -e /etc/systemd/system/castreader-core-audio-monitor@.service
test ! -e /etc/systemd/system/castreader-core-audio-monitor@.timer
test ! -e /etc/castreader/core-audio-monitor-cn.env

test "$(systemctl is-active castreader.service)" = active
test "$(systemctl show castreader.service -p NRestarts --value)" = 0
test "$(readlink -f /opt/castreader/current)" = /opt/castreader/release-20260904120513
test "$(systemctl is-active castreader-cn-kokoro-tunnel.service)" = active

test "$(node --version)" = v22.23.2
command -v ffmpeg >/dev/null
command -v ffprobe >/dev/null
test "$(systemd --version | awk 'NR==1 {print $2}')" = 249
```

以上 release/PID/config 值属于 15:42 CST 的快照，真正安装时必须重新采集完整值。JSON 中三个生产配置 SHA 只保留了脱敏前缀，故刻意不能用于 CAS；operator 要重新取得完整 64 位 SHA，并至少覆盖：

- `castreader.service` 主 unit、全部五个 drop-in 的排序组合 SHA；
- Nginx `nginx -T` 的有效配置 SHA，以及精确 `/api/captioned_speech_partly → 127.0.0.1:3000` 合同；
- `castreader-cn-kokoro-tunnel.service` unit SHA、MainPID/start ticks；
- `castreader.service` MainPID/start ticks/cwd、current symlink 和 immutable release tree SHA。

安装监控不应改变上述任何值。安装后的 CAS 要逐项重取并与安装前相等。只检查 `active` 不够，因为服务可能在窗口里被别人换过进程。

## 4. 已执行的 immutable 安装步骤

以下是首次 staged 安装实际执行的命令结构。最终制品沿用相同的不可变目录、逐文件 SHA 和原子 link 切换，只把 release 换成 `/opt/castreader-core-audio-monitor/releases/272d3148-5c085a61`；最终 artifact、tree 与文件 SHA 见 rollout receipt。初版目录为取证保留，没有被覆盖：

```bash
set -euo pipefail

artifact=/tmp/castreader-core-audio-monitor-37d6f4d8.tar.gz
release=/opt/castreader-core-audio-monitor/releases/37d6f4d8-b12f3afd
current=/opt/castreader-core-audio-monitor/current

sudo install -d -o root -g root -m 0755 /opt/castreader-core-audio-monitor/releases
sudo install -d -o root -g root -m 0755 "$release"
sudo tar -xzf "$artifact" -C "$release" --no-same-owner --no-same-permissions
sudo chown -R root:root "$release"
sudo find "$release" -type d -exec chmod 0755 {} +
sudo find "$release" -type f -exec chmod 0644 {} +
sudo chmod 0755 "$release/run.mjs"

test "$(sha256sum "$release/probe-core.mjs" | awk '{print $1}')" = \
  ca57373856da1ffa69e49c85bee3d4c67d41eda75014baacea0f11d3eea11fbf
test "$(sha256sum "$release/run.mjs" | awk '{print $1}')" = \
  9626a4c6cce9d5c515c34f4d08daee24c1284fc12abf87b22f61315f47adbbc4
test "$(sha256sum "$release/systemd/castreader-core-audio-monitor@.service" | awk '{print $1}')" = \
  65fe20188f2b15af652e614d81e3fdf6b3e90de71670c1e352f5827a9e6f6916
test "$(sha256sum "$release/systemd/castreader-core-audio-monitor@.timer" | awk '{print $1}')" = \
  d7cf2893eb75f9c9397958ce8fe0c3833228c9c6decedae2bee36b6bc076be92

sudo ln -s "$release" /opt/castreader-core-audio-monitor/.current.new
sudo mv -Tf /opt/castreader-core-audio-monitor/.current.new "$current"
sudo install -o root -g root -m 0644 \
  "$release/systemd/castreader-core-audio-monitor@.service" \
  /etc/systemd/system/castreader-core-audio-monitor@.service
sudo install -o root -g root -m 0644 \
  "$release/systemd/castreader-core-audio-monitor@.timer" \
  /etc/systemd/system/castreader-core-audio-monitor@.timer
sudo systemctl daemon-reload
sudo systemd-analyze verify \
  /etc/systemd/system/castreader-core-audio-monitor@.service \
  /etc/systemd/system/castreader-core-audio-monitor@.timer

test "$(systemctl is-enabled castreader-core-audio-monitor@cn.timer 2>/dev/null || true)" != enabled
test "$(systemctl is-active castreader-core-audio-monitor@cn.timer 2>/dev/null || true)" != active
```

CN 使用仓库内固定 public endpoint，不需要 env 文件。不得复制 Global env，也不应创建 endpoint override。如果将来确实需要同机 loopback，必须单独审阅 `/etc/castreader/core-audio-monitor-cn.env`，只允许无凭据的 loopback URL；当前 public 路由最能覆盖 Nginx、Next 和本地隧道全链。

安装 unit 和 `daemon-reload` 本身不会发请求。第一次 `systemctl start castreader-core-audio-monitor@cn.service` 会发起完整多段探针，最多 6 段、每段最多 2 次尝试，所以必须属于单独的合成授权窗口。人工 oneshot 成功且结果已审阅后，才可另行执行：

```bash
sudo systemctl enable --now castreader-core-audio-monitor@cn.timer
```

修复后的人工 oneshot 于 23:58:13 CST 返回 `healthy`，3 段均完成 MP3 解码并把余文推进到 0；随后 timer 于 23:58:40 CST 启用。由于 `Persistent=true` 且开机时间已超过 `OnBootSec`，systemd 立即补跑一次，结果同样为 3 段 `healthy`，之后进入每五分钟调度。详见 rollout receipt；没有外发告警。

## 5. systemd 行为和状态范围

Unit 在 [castreader-core-audio-monitor@.service](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-release-guard-20260905/scripts/core-audio-monitor/systemd/castreader-core-audio-monitor@.service:1) 使用 `DynamicUser=yes`、`UMask=0077`、`StateDirectory=castreader-core-audio-monitor/%i`、150 秒 oneshot 上限和只读系统保护。systemd 249 支持相对的嵌套 `StateDirectory` 并创建父目录；DynamicUser 会把真实状态置于受保护的 `/var/lib/private`，同时暴露 unit 使用的 `/var/lib/castreader-core-audio-monitor/cn` 路径。

Timer 每 5 分钟执行一次，15 秒随机抖动并支持漏跑补偿，见 [castreader-core-audio-monitor@.timer](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-release-guard-20260905/scripts/core-audio-monitor/systemd/castreader-core-audio-monitor@.timer:1)。脚本另有 120 秒整轮、35 秒每段和 180 秒陈旧锁界限；同一 host/region 的并发运行会直接记录 `skipped_single_flight`，不会叠加合成。

结果只保存在本区机器，mode 0600，默认保留 7 天且 results/alerts 各最多 2016 个 JSON。音频通过 stdin 交给 ffmpeg 后丢弃，固定诊断正文也不写入结果；只留其 SHA、长度、段数、字节数、耗时、解码时长和白名单路由元数据。告警只是 `notificationPolicy: dry-run` 的本地 envelope，不发 webhook、邮件或消息。实现分别见 [run.mjs](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-release-guard-20260905/scripts/core-audio-monitor/run.mjs:18) 和 [state-store.mjs](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-release-guard-20260905/scripts/core-audio-monitor/state-store.mjs:83)。

## 6. 回滚步骤

基线中该 monitor 完全不存在，因此第一次安装失败时回滚是移除新增入口，同时保留结果证据：

```bash
set -euo pipefail

sudo systemctl disable --now castreader-core-audio-monitor@cn.timer 2>/dev/null || true
sudo systemctl stop castreader-core-audio-monitor@cn.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/castreader-core-audio-monitor@.timer
sudo rm -f /etc/systemd/system/castreader-core-audio-monitor@.service
sudo systemctl daemon-reload
sudo rm -f /opt/castreader-core-audio-monitor/current
```

不要自动删除 `/var/lib/private/castreader-core-audio-monitor` 或失败 release；它们是诊断和字节恢复证据。确认 `castreader.service`、两个 TTS tunnel、QuickRead、Nginx、GPU Kokoro/clone/Nari 的 PID/start/cwd/hash 与安装前一致。监控没有修改这些服务，所以任何变化都应视为并发发布，停止继续操作。

后续升级若已有旧 monitor release，先备份两个 unit 和 current 的精确 link target；失败时用 `ln -s` + `mv -Tf` 原子恢复旧 link、恢复旧 unit、`daemon-reload`，然后只启动旧 monitor oneshot。不得回滚或重启业务 TTS。

## 7. 监控能看见与看不见的范围

能看见的链路：

```text
CN controller systemd
  → api.castreader.cn public TLS/Nginx
  → Next /api/captioned_speech_partly
  → CN fixed route / local SSH tunnel
  → CN Kokoro preset voice
  → partial JSON + exact remainder
  → MP3 full decode
  → repeat until fixed text is exhausted
```

它会把 playable audio、正文连续推进、区域 pin 和时间戳质量分开记录；时间戳失败只标 `alignment_degraded`，不会伪装成朗读供给失败。它不自动重启任何服务。

它不覆盖：clone 模型、Nari、QuickRead LLM/持久化恢复、iOS/Android/Web/扩展的预取与 AVPlayer 队列、全部音色/语言、真实用户长书、DNS/TLS 控制面告警送达、GPU 暖备用接管、物理地域独立证明。public probe 从 CN controller 发往 CN 域名，可以检查公网入口和返回 region metadata；不能单靠 header 证明底层物理机器所在国家。

## 8. release guard 接入点与无法自行强制的边界

现有 CN Next 发布入口是 [deploy-cn.sh](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-release-guard-20260905/scripts/deploy-cn.sh:24)。它先要求 exact approved SHA、`origin/beta` tip、clean worktree 和 previous-SHA ancestor，再读取 current release identity、校验同区账本，构建 immutable release 并调用事务激活脚本。现有入口已经有 source gate，但没有调用新 [verify-cas.mjs](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-release-guard-20260905/scripts/core-service-release-guard/verify-cas.mjs:94)。要让 guard 真正生效，发布 wrapper 必须在任何上传/排空前生成 fresh `before` snapshot，并在 symlink 切换后、恢复流量前生成 `after` snapshot，二者都以同一 manifest SHA 调用 verifier；返回非零时进入现有 rollback。

当前 guard 自身不能强制以下事实：

1. 它不做 SSH、现场采集、artifact 上传、排空、切换或回滚；它只相信调用方给的 manifest/snapshot。采集和切换之间仍需 wrapper 缩小 TOCTOU，并在真正替换 link 的同一临界区重核关键 identity。
2. `--expected-manifest-sha256` 只防止调用期间换文件，不证明 manifest 来自受保护 CI 或被签名。当前 `beta` 分支未启用平台 branch protection，Git ref 名字本身不能充当审批权威。
3. schema 的 `state` 只强制 `release_target` 和 `runtime_tree_sha256`；`process`、`files`、private env/config SHA 可省略，files 也可为空。若 wrapper 允许这种 manifest，验证会“合法地少查”。生产入口必须额外要求这些字段完整，或在合入前收紧 schema/validator。
4. backup receipt 只校验 `verified=true`、同 region 标签和 object/readback SHA 相等；它不查询对象是否仍存在、是否 private、provider 的真实 region 或恢复可用性。operator 仍需从同区 private object store 做真实 readback，并把控制面回执绑定到 manifest。
5. `route_contract` 是深比较，但 snapshot 若由不可信脚本伪造，guard 无法辨别。capture wrapper 必须从有效 Nginx/systemd配置与公开能力响应生成，而非手填。
6. guard 当前只接受 `kokoro|quickread|core-api`，不接受 `core-audio-monitor`。它可接业务核心发布，不能直接拿来批准本 monitor 的首次安装；本文件第 3 节的 absent-state CAS 是暂时的安装门禁。
7. protected process 角色和值由 manifest 提供；只有 Kokoro 发布 wrapper 才应强制 clone/Nari 两个角色完整且 PID/start/cwd 前后相同。通用 verifier 不知道业务角色语义。

因此，新 guard 是发布事务中的必要比较器，还不是完整发布控制面。接入现有 `deploy-cn.sh` 之前必须先补可信 snapshot capture、不可省字段、同区备份在线验证和失败回滚触发；不能仅把一条 `node verify-cas.mjs` 命令插入脚本就宣称生产发布已被约束。
