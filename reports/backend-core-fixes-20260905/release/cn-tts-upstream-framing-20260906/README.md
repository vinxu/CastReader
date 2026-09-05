# 中国区 TTS upstream framing 连续性修复

## 问题与修复

中国区公开 `/api/captioned_speech_partly` 在客户端省略 `stream` 时会把省略值继续传给 Kokoro。模型默认返回多条 NDJSON；网关把完整响应当单个 JSON 解析，重试后返回 502。相同请求显式 `stream:false` 可返回完整 MP3，因此故障属于网关与模型的 framing 合同不一致，不是模型生成失败。

候选源码严格从中国区生产提交 `62386e902cb7201919e9680e56c82c8627b47110` 构建，只叠加提交 `9d652ec87d48a65d05e088d4655e806777dead12` 的两个文件：

- `src/shared/lib/tts-gateway.ts`：发给普通 Kokoro 的当前分段固定为 `stream:false`，完整读取并解析单个 JSON；
- `src/shared/lib/tts-gateway.test.ts`：覆盖客户端省略、`true`、`false` 三种输入，确认都得到完整音频而不是 NDJSON 首段。

克隆模型、区域路由、数据库、COS、QuickRead 和 GPU 进程没有代码变更。

## 候选与验证

- 源提交：`9d652ec87d48a65d05e088d4655e806777dead12`
- 干净归档：`/tmp/castreader-cn-tts-framing-9d652ec87d48/release-20260906014729.clean.tar.gz`
- 归档 SHA-256：`9bd9372292efd01f4d5bc91839b02d3d033eab297ece82504fb5b88a287dc2a0`
- 归档大小：41,225,604 字节
- 远端候选：`/opt/castreader/release-20260906014729`
- 文件树 SHA-256：`e6946fa061db2e203311b9d7a36c7b4539a28c4314b98c5cada79a36c6c8277f`，7,214 个常规文件、36 个符号链接、无 `.env`、无 `._` 文件

最初由 macOS `tar` 生成的归档携带扩展属性，Linux 解包后出现 8,447 个 `._` 文件。该归档已被拒绝，不是审批目标。最终归档由 Python `tarfile` 生成，不含扩展属性；本地重解包树与远端候选逐文件一致。

隔离候选在 `127.0.0.1:3102` 使用固定非用户正文和基础音色 `zf_001` 验证一次省略 `stream` 的请求：HTTP 200，MP3 24 kHz 单声道、65,664 samples、2.736 秒，完整 ffmpeg 解码；43 字输入精确推进为 12 字已处理和 31 字余文；时间戳单调；上游区域为 `cn`、节点为中国 4090。候选随后停止，3102 已释放。

源码验证通过：TTS gateway 25/25、speech budget 与区域路由 19/19、voice clone 合同 206/206、中国区发布/存储/鉴权回归 94/94、TypeScript、Next production build。发布包装的精确副本另通过 11/11 activation 回归。

## 回滚与切换结果

切换前旧版本、Nginx、systemd drop-ins 和 `/etc/castreader` 私有配置已经打包至上海私有 COS，并完整 GET 回读：43,320,534 字节，SHA-256 `5957aa8545e9587687f99565d1f9bff6d3cf8e09532e0884cdf5e64389f124e8`，ACL private。

不可变备份与现场再次比对：旧 release 聚合 SHA-256 `47f94a64144ffd559953b4c84ca3be32c374b0d9b4707e1f2474e343e940489c`（7,216 文件、36 链接、根目录 uid/gid 998/998、0700）；私有配置聚合 SHA-256 `67821b02cb448cf3b4f7b077acca6663c43a5601a37aabd0a02d92ac8ee4c5c3`（27 文件）。配置清单只记录路径、哈希、uid/gid 和 mode，不记录值。

发布包装保留原账本、数据库 schema、公开健康、QuickRead、克隆合同和 TTS 健康门，并补齐：

- `EXIT`、`ERR`、`INT`、`TERM`、`HUP` 在提交前统一回滚；
- 内层已回滚时外层识别旧进程和四份旧配置，不重复重启；
- 内层提交后固定后验失败时，外层仍能恢复旧软链、Nginx 和 20/27/30 drop-ins；
- 成功后保留全部旧 release，不按 mtime 删除回滚资产。

首次切换在 2026-09-05 18:24 UTC 被运行时配置闸门拒绝并完整恢复旧版本。失败进程只存活约 0.589 秒，退出后无法再读取其环境，因此“`Type=simple` 已 active，但 Node 尚未语义就绪”是现场证据和 systemd 行为共同支持的最强推断，不是已捕获具体失败字段的事实；没有证据表明生产配置策略不匹配。首轮证据和 root-only 外层备份 `/tmp/castreader-cn-tts-framing-outer-rollback.U1pYxU` 均保留。

修正发布器后，第二次切换于 2026-09-05 18:50:14–18:50:21 UTC 成功。正式生产现在是 `/opt/castreader/release-20260906014729`，源码提交 `9d652ec87d48a65d05e088d4655e806777dead12`，Next PID `1630406`。切换前连续三次空闲；切换期间 capabilities 采样 16 次，14 次 HTTP 200、1 次 HTTP 502、1 次超时，相邻成功响应的最大间隔为 3.750 秒。该服务使用 restart 切换，因此这里只报告实际观测窗口，不声称零停机。

切换后的本地定时监控自动完成两轮多段全文验证，无需另发人工合成探针：18:52:32.133 UTC 产生恢复事件，18:57:43.813 UTC 再次 healthy。每轮按 `stream` 省略、`true`、`false` 三种合同连续请求，余文字符数从 45 降到 23、再归零；三段 MP3 均完整解码，总计 216,324 字节、13.44 秒，时间戳健康。每段响应都标明 `upstreamRegion=cn`、`upstreamNode=castreader-cn4090`、`upstreamSource=cn-environment`。响应里的 `gateway=vercel-r2` 是历史固定标签，不是地理路由证据；本次请求由中国区入口、本区 Next 进程和上述 CN 上游字段共同证明区域链路。

切换后新 release 与 `/etc/castreader`、Nginx、systemd 配置再次写入上海私有 COS 并完整 GET 回读：41,046,123 字节，SHA-256 与 readback SHA-256 均为 `f2096aa02cbb173076f6a544aa023b5186c392a2d331cc282268da9ce470f04d`，`public=false`。

QuickRead PID `1608646`、Kokoro 隧道 PID `1029281`、克隆隧道 PID `2090236` 和 monitor release `f6eb6691-7a2c0b1f` 在本次 Next 切换中保持不变。

已把同一套语义就绪、退出回滚、失败备份保留和旧 release 保留规则独立提交到 canonical 发布工具：`ec117d38d935cacdc4300d86b76467cd2a9ea848`，15/15 回归通过。该提交只修改发布工具，没有再次部署生产应用。

## 证据

- `final-clean-candidate-cas.json`：当前生产、候选、路由、QuickRead、隧道、monitor 和 staged 文件最终 CAS。
- `prebackup-private-config-manifest.json`：不可变备份与现场旧代码/私有配置逐字节比对。
- `candidate-omitted-stream-probe.json`：3102 省略 stream 的同区真实候选探针。
- `pre-release-shanghai-cos-backup.json`：上海私有 COS 上传与完整回读回执。
- `post-release-shanghai-cos-backup.json`：切换后上海私有 COS 上传与完整回读回执。
- `activation-wrapper-tests.json` 与 `activation-wrapper-tests.tap`：发布包装 11/11 回归。
- `activate-cn-release-ready-rollback.sh.txt`：带语义就绪和完整回滚的最终内层包装。
- `cn-cutover-attempt2.sh.txt`：固定 SHA、固定 PID、固定配置和完整外层回滚的成功切换脚本。
- `cutover-attempt2-activation.log` 与 `cutover-attempt2-availability-summary.json`：正式切换和真实可用窗口。
- `../monitor-legacy-contracts-20260906/cn-post-gateway-recovery-readback.json`：两轮自动多段全文恢复证据。
- `production-rollout-receipt.json`：最终生产、播放连续性、未变服务、备份与 canonical 工具摘要。
