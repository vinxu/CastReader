# 中国克隆时间戳管线：部署与恢复

## 当前版本：v3（2026-09-08 23:38:27 +08:00）

正式 `current` 已原子切换为
`/root/autodl-tmp/castreader-alignment/releases/20260908-qwen-pcm-v3-r1`，
健康版本应为 `qwen-pcm-measured-groups-v3`。只重启独立 alignment 程序；
原 Nari、Kokoro、clone Worker 以及控制机 Next/Nginx/SSH 配置在本次切换中均未改变。
v2 路径保留，是直接回滚目标。下面原 v2 部署结构与共享模型恢复集仍是基础依赖。

同一私有 COS 前缀下新增三个完整回读成功的组合归档：

| 对象 | 字节数 | SHA-256 |
|---|---:|---|
| `v3-pre.tar.gz` | 13,701 | `3d2535c71fd2dfc977f78fe625760367d0625884a645c5fb221983e16d91e5b2` |
| `v3-candidate.tar.gz` | 13,479 | `f1cedb59d1d1a53362df78dc0ecb9fe0b574d50756ab6803e9bf83eba24a2e87` |
| `v3-post.tar.gz` | 6,768 | `b1071a64cfd7a375c395c851a409d9b2d704aa2b63d99b8d3c840731d0075815` |

`v3-pre` 包含精确旧 v2 release、当前控制机配置及已验证共享恢复集回执。
`v3-candidate` 包含完整新 release、逐成员 SHA、资格摘要、恢复 recipe 及共享/回滚回执；
内部 `v3-release.tar.gz` 的 SHA 为
`368346e45bb882c4b2219978d507e62a6163d60dce547d6c6a594b298ac2c27d`。
`v3-post` 包含切换脚本/记录、生产实际请求证据、current/服务状态及两个前置回执。
所有 `.receipt.json` 自身亦由同一 helper 上传并完整回读；不要覆盖这些不可变对象。

控制机回执路径为 `/tmp/cn-alignment-v3-{pre,candidate,post}-20260908.receipt.json`。
新机器恢复时先恢复本文共享原运行时/模型/overlay，再在新空目录展开完整 v3 release 并逐项验证。
不依赖只包含 diff 的补丁，也不重复下载相同模型。

从 v3 回滚仅需排空请求，使用私有 Supervisor 停止 `castreader-clone-alignment`，
原子将 `current` 指回保留的 v2-r1，然后启动同一程序并要求 v2 health 与真实 caption 请求通过。
不要执行下文“撤销整个私网路由”的完整回滚，除非明确要退出整个对齐服务。
操作前重新核对其他任务是否已对原 Worker 作独立变更，不能将 23:38 的 PID 快照当作永久事实。

## 上线范围

2026-09-08 21:21:41 +08:00，仅中国区切换。对齐版本为
`qwen-pcm-measured-groups-v2`。Next 控制面仍是
`release-20260906014729` / `9d652ec87d48a65d05e088d4655e806777dead12`，
没有重新构建或发布 Web，没有修改其发布门禁，也没有提交或推送 Git。

生产控制面的 `VOICE_CLONE_WORKER_URL` 保持 `http://127.0.0.1:18890`。
该私网入口由 Nginx 按路径转发：

- `/v1/captioned-speech` → 控制机 18891 → 中国 GPU 18891 新对齐服务。
- 其余路径 → 控制机 18892 → 原中国 GPU 18890 Worker。
- 新对齐服务只调用原 Worker `/v1/speech`，继续使用原调度器、合成模型、声音和鉴权。
- 只有时间戳后处理与 MP3 编码改变；JSON 四字段保持兼容。
- 原音色创建、删除、prompt 恢复、WAV 接口不经过新对齐服务。
- 没有部署本地准备的 Next 路由/计费补丁；控制面仍用原有扣量逻辑，不能称为已按新 PCM 时长头结算。

## 运行对象

- GPU current：`/root/autodl-tmp/castreader-alignment/current`
- GPU release：`/root/autodl-tmp/castreader-alignment/releases/20260908-qwen-pcm-v2-r1`
- GPU 独立 Supervisor：`/root/autodl-tmp/castreader-alignment/run/supervisor.sock`
- 模型：`/root/autodl-tmp/alignment-pipeline-20260908/model`
- 依赖 overlay：`/root/autodl-tmp/alignment-pipeline-20260908/venv`
- 原依赖：`/root/autodl-tmp/nari-staging/venv`
- 中国控制机新隧道：`castreader-cn-clone-raw-tunnel.service`，同一个 SSH 连接转发 18891/18892。
- 中国控制机启动检查：`/etc/castreader/ensure-cn-alignment-remote.sh`，复用 SSH 控制 socket，避免额外连接限制。
- 原 `castreader-cn-clone-tunnel.service` 已停止、禁用，保留配置以便回滚。
- Nginx：`/etc/nginx/conf.d/castreader-cn-clone-private-route.conf`
- 专用日志：`/var/log/nginx/castreader-clone-alignment.log`，只记请求 ID、状态、耗时、管线版本及模式，不记正文、音频或凭据。

GPU 现有中国隧道公钥仅新增 `permitopen="127.0.0.1:18891"`；其余限制原样保留。
新服务绑定 loopback，不开放公网端口。启动要求至少 6 GiB 空闲显存；没有放宽原服务安全线。
独立 Supervisor 不修改平台 Supervisor 或原 Nari/Kokoro watchdog。

## 完整恢复集

私有 COS：`castreader-voice-1323065328`，区域 `ap-shanghai`。
对象前缀：`runtime-backups/20260904/alignment-20260908/`。

1. `cn-controller-pre.tar.gz`：43,433,362 字节，SHA-256
   `ebb710720effba0dfa5d892a06e5b2f21f0b00680d2a5d67481479a00e5bdb88`。
2. `clone-and-alignment-runtime.tar.gz`：3,647,682,733 字节，SHA-256
   `23c3372892d3eafdbfe0fe1b3cb814437171804bc1aa7782254341f3d15b02d9`。
   包含原 Nari 模型、Worker、质量/降噪资产、声音、启动文件、发布记录，
   新 Qwen 模型、依赖 overlay、版本锁定清单和逐文件 SHA。
3. `r1-delta.tar.gz`：11,134 字节，SHA-256
   `d1bd48ee3aef625c9fcdfaaa637fa3f583e9b8d7a120b53bf81a4b66520c7811`。
   包含完整 r1 代码与启动文件、修改前 authorized_keys 及精确端口授权脚本。
4. `cn-cutover-post.tar.gz`：上线后的控制机配置、GPU current/源码清单、公钥、运行状态、验收证据及本文。
   精确大小与 SHA 见同名前缀的 `.receipt.json`。

每个归档及回执自身均须验证 `public:false`、`verified:true`、字节数和完整回读 SHA。
不要将 multipart ETag 当作文件 SHA。共享模型归档不重复上传；保留所有组合回执引用的对象。

在新空目录先验证并展开恢复集，不覆盖正在使用的 release。按原 runtime requirements
重建 Python 3.12 / CUDA 基础依赖，再恢复 overlay；`.pth` 依赖原 Nari venv，不能只复制 overlay。
恢复路径需与上述路径一致，或统一修订全部启动文件、依赖 `.pth` 与清单后重新验收。
先恢复并验证原 Worker/Nari，再启动独立对齐服务，最后配置私网代理。不要重启无关 GPU 服务。

## 回滚

保留当前配置副本，将 `castreader-cn-clone-private-route.conf` 移出 Nginx include 目录，
执行 `nginx -t` 与 `systemctl reload nginx`，随后
`systemctl enable --now castreader-cn-clone-tunnel.service`。
确认 18890 由原 SSH 隧道监听、原 Worker 健康且实际 clone 请求成功后，
再停止新 raw 隧道及本次独立对齐 Supervisor。不得停止平台 Supervisor、Nari 或 Kokoro。

## 验收限制

客户端既有 MP3 解码差异仍须纳入验收：Apple 实测有 24ms 信号偏移及 48ms 额外解码时长。
不能对所有客户端统一加 24ms。中/日/韩保持原段级模式；少数零时长短词合并为测得的词组，
不伪造单词时长。超时/过载保留音频、不给不可信时间戳。
用户最新明确要求停止进一步真机/合成回归、国际区直接统一 V3，已按该新指令完成国际部署。
国际最终状态和恢复坐标见 `RESTORE-US-ALIGNMENT-20260909.md`。
部署健康与路由检查不是额外的声学精度证明；不得把未执行的后续测试记为通过。
