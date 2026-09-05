# Global core 私有配置来源补充核对

核对时间：2026-09-06 CST。范围是现有 Vercel 项目、已批准的本地运维工具、正在运行的 Global QuickRead/clone 服务以及源码配置合同。初始核对只读。随后主任务通过受控进程和标准输入，向新 core 项目补入 8 项已有权威来源的配置；旧生产项目和服务配置没有修改。密钥值未进入聊天、Git 或报告。实际写入清单见[迁移回执](global-core-authoritative-configuration-migration.json)。

## 直接结论

新 `castreader-core-audio` project 目前不能作为完整的 clone/QuickRead 生产入口。现有来源可以安全补齐 Supabase 存储三项、worker token 和非秘密 worker URL；QuickRead 两项可从当前正式 QuickRead 服务的 root-only 环境直接迁移。原 `VOICE_CLONE_ENCRYPTION_KEY` 仍缺少可读取的权威来源。`VOICE_CLONE_WORKER_CA_CERT` 已在后续核对中定位为 US GPU Caddy 使用的原自签名公钥证书，已验证外部 TLS 和指纹并迁移，不再阻塞；没有读取私钥或轮换证书。

其中 `VOICE_CLONE_ENCRYPTION_KEY` 是切换 clone 流量前的硬阻塞。代码要求它解码后严格为 32 字节，且原值用于解密已经保存的 voice reference；生成新值会使旧数据不可读。[storage.ts](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-service-isolation-20260905/src/shared/voice-clone/storage.ts:235)

## 迁移时的来源矩阵（状态以迁移回执为准）

| 目标变量 | 当前结论 | 可接受来源和边界 |
|---|---|---|
| `VOICE_CLONE_SUPABASE_URL` | 可迁移 | 已审 launcher 把目标固定到唯一批准的 Supabase project，并验证 legacy source 中的 URL 与固定 origin 相等；不得从任意 env 接受其他 project。[with-storage-environment.mjs](/Users/xuxuheng/Documents/MyProject/castreader-tts-compatible-fix/verification/with-storage-environment.mjs:8) |
| `VOICE_CLONE_SUPABASE_BUCKET` | 可迁移 | read-only metadata 已确认 `castreader-voice-clones` 存在且 `public:false`；备份 bucket 的 3.325GB 完整 GET/SHA readback 也验证相同 project。bucket 名本身不是 secret。 |
| `VOICE_CLONE_SUPABASE_SERVICE_ROLE_KEY` | 可做一次受控迁移 | launcher 优先使用受控进程 env；缺失时从 private legacy repo 的固定文件取值，只传给固定 child process，既不进 argv 也不输出。[with-storage-environment.mjs](/Users/xuxuheng/Documents/MyProject/castreader-tts-compatible-fix/verification/with-storage-environment.mjs:13) 可用同一方式通过 stdin 送入 Vercel Sensitive 配置。legacy 文件被 Git 跟踪且本地 mode 0644，是需要后续轮换和清理的安全债务，不能作为长期 secret manager。 |
| `VOICE_CLONE_ENCRYPTION_KEY` | **阻塞** | 本地项目、launcher、GPU 进程均没有权威副本；旧 Vercel 只返回 Sensitive 占位。必须由原始密钥管理位置重新提供原值，或另立受审的数据重加密迁移；本轮禁止从 production function、日志或占位文件绕过提取。 |
| `VOICE_CLONE_WORKER_URL` | 可配置非秘密合同 | Global 源码将允许值固定为唯一 HTTPS 地址，并拒绝其他 origin。[worker-regional-routing.ts](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-service-isolation-20260905/src/shared/voice-clone/worker-regional-routing.ts:3) GPU 的本地 listener 只证明服务存在，正式切流前仍须从外部入口验证 TLS identity 和 health。 |
| `VOICE_CLONE_WORKER_TOKEN` | 可迁移 | 当前 US GPU clone 进程的权威是 root-owned、mode 0600、非 symlink 的 token file，由进程通过 `CLONE_TOKEN_FILE` 加载。可在受控 secret channel 中直接映射到 Vercel Sensitive 变量；不得复制到普通 env、报告或聊天。 |
| `VOICE_CLONE_WORKER_CA_CERT` | 已迁移并验证 TLS | 实际 TLS 在 GPU 的 Caddy 进程终止，使用 `/workspace/castreader-clone/tls/origin-cert.pem`。该自签名 leaf 是客户端信任锚，非单独 CA 文件；SHA-256 `f0079767d403595d110541cf4fbe9ffb389bd8ef55acf6b8c06ba14244df7086` 与公开入口证书逐字节相同。原证书经 IP SAN 和可信连接验证后迁移。仅检查 clone uvicorn 进程会漏掉此来源；未读取 origin-key.pem、未替换证书。 |
| `VOICE_CLONE_WEB_BRIDGE_SECRET` | 条件可迁移 | GitHub `production` Environment 中存在同名 secret，受保护 workflow 可无明文注入。当前仓库 production environment/branch 保护不足，因此在控制面 gate 修好前不能把“值存在”写成“安全发布入口已经成立”。 |
| `QUICKREAD_API_KEY` | 可从正式运行配置迁移 | 迁移时的权威来源是 US QuickRead 当时 release 的 `/root/castreader/routing-releases/20260904-quickread-gif-retirement/.env`，owner `root:root`、mode 0600。生产 PID 的 cwd 是同一 release；invalid body 返回 400、wrong key 返回 401，证明运行服务已加载该 key。不能使用候选目录里误带出的 `.env.bak-*` 副本。应从 live source 经 stdin 直接写入 Vercel Sensitive，不落地普通文件。 |
| `PRO_INTERNAL_SECRET` | 可从正式运行配置迁移 | 同一 root-only live env 中该项非空；该 release 日志已有 4,331 次 `[pro-gate] allow`，证明 secret 实际参与同区 entitlement 调用。服务启动后自行加载 `.env`，所以 `/proc` 初始 env 为空不代表未加载。它必须与当前 QuickRead 调用方和 `/api/pro/entitlement` 接收方保持同值。[entitlement route](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-service-isolation-20260905/src/app/api/pro/entitlement/route.ts:23) 只能从正式 live env 直接迁移。 |
| `QUICKREAD_UPSTREAM_BASE_URL` | 不需要秘密恢复 | Global 代理缺省并严格限定 `https://qr.castreader.ai`，不是 Sensitive 输入；`QUICKREAD_API_KEY` 才是必需 secret。[mobile-quickread-proxy.ts](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-service-isolation-20260905/src/shared/quickread/mobile-quickread-proxy.ts:65) |

## Storage launcher 实际证明范围

[with-storage-environment.mjs](/Users/xuxuheng/Documents/MyProject/castreader-tts-compatible-fix/verification/with-storage-environment.mjs:1) 只做三件事：固定 Supabase origin、取得 service-role credential、把两项 storage env 仅传给固定 verification 目录下的 Python child。它没有 clone encryption key、worker token/CA、QuickRead key 或 Pro internal secret。

[supabase_tus_keepalive.py](/Users/xuxuheng/Documents/MyProject/castreader-tts-compatible-fix/verification/supabase_tus_keepalive.py:80) 复用相同 storage credential，并把 HTTPS host 限定在该 project 的 API/storage host，校验证书且不允许 redirect。已有完整 readback receipt 证明这一存储凭据能访问私有备份对象，但这不等于它能解密 voice reference，也不证明其他服务 secret。

launcher fallback 的 service-role 明文来自 private git repo 中一个 mode 0644 的 tracked Python 文件。它当前能完成经授权的恢复验证，却不符合长期密钥治理标准。后续应在新 core 稳定且保留回滚窗口后，单独轮换 service-role，并把 legacy 明文从工作树和历史处置流程中移除；本次核对没有执行轮换。

## 明确排除的伪来源

- `/tmp/castreader-qr-continuity-20260906-1605/us-after/.env.bak-pro-url-20260709072757` 是候选制品误包含的旧 production 快照。它不是批准的迁移来源，相关发布方已冻结该制品并重建排除所有 `.env*`。
- 任何 `.vercel/.env.production.local` 中的 `[SENSITIVE]` 只是占位，不能作为值或证明值可恢复。
- `/Users/xuxuheng/Documents/MyProject/readout-web/.env.local` 当前有一部分旧 web 配置，但没有 clone/QuickRead 所需变量，也不是生产发布权威；不能整文件复制到新 project。
- Team Shared Environment Variables 当前只有未关联的 MySQL 五项，没有 TTS、clone、QuickRead、Pro 或 storage 配置。
- CN 的 env、token、对象存储或 worker 配置不能用于补 Global 缺口。

## 已执行的迁移顺序与剩余验收

1. 仍需补齐原 `VOICE_CLONE_ENCRYPTION_KEY`；在此之前不切 clone 流量。原 worker 公钥证书已经从 TLS 终止进程找到并迁移。
2. 已把 Supabase 三项从固定 launcher/source 通过 root-only 进程和 stdin 写入 Vercel Sensitive；不生成中间明文文件。
3. 已从 US GPU root-only token file 直接迁移 worker token；worker URL使用源码固定合同。
4. 已从 US QuickRead 当时 root-only live env 直接迁移 `QUICKREAD_API_KEY` 与 `PRO_INTERNAL_SECRET`；source path、owner、mode 和生产进程加载关系已经只读核实，实际写入通过受控 stdin 完成。
5. 只在新 project 的 masked capability、worker TLS/identity、私有 storage decrypt、QuickRead auth/entitlement 都通过后，才把其视为可接生产流量。

初始核对与后续实际迁移分开留证；当前已写入的 8 个变量及剩余缺口以[迁移回执](global-core-authoritative-configuration-migration.json)为准。最初的 names-only 计划保存在 `/tmp/castreader-core-audio-config-source-plan-20260906.json`，不含值、连接串或 credential hash。

2026-09-06 后续核对：Vercel 官方共享变量流程要求提供值或关联已有团队变量，没有找到把该项目 Sensitive 值直接转为团队变量的受支持入口；官方说明 Sensitive 值不可读回。现有团队变量也未包含缺失项，因此此路线未用于迁移。[Shared environment variables](https://vercel.com/docs/environment-variables/shared-environment-variables)、[Sensitive environment variables](https://vercel.com/docs/environment-variables/sensitive-environment-variables)。
