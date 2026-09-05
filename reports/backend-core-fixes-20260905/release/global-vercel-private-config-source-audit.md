# Global Vercel 私有配置来源核对

核对时间：2026-09-06 00:08 CST。范围仅限已有项目链接、明确部署文档、GitHub Actions secret 名称和本地 env 的“存在/占位”状态；没有读取、复制或输出任何变量值，也没有把 CN 配置用于 Global。

## 结论

项目里有两类**明确且可合法调用**的 Global 配置来源，但合起来仍不是新 core project 的完整私有运行配置：

1. GitHub `scmyyan/readout-web` 的 `production` Environment Secrets 是当前发布流程明确使用的私密注入源。可确认存在的名称为 `TTS_OPS_ADMIN_SECRET`、`TTS_RUNTIME_METRICS_SECRET`、`VERCEL_ORG_ID`、`VERCEL_PROJECT_ID`、`VERCEL_TOKEN`、`VOICE_CLONE_WEB_BRIDGE_SECRET`、`VOICE_GIFT_E2E_BRIDGE_SECRET`。值不可读，但 GitHub workflow 可以在受保护 job 内消费。2026-09-02 的 production release run `33589009978` 和 2026-09-05 的 maintenance run `33934272517` 均成功，证明对应流程当时可用。
2. 已有 Vercel production project `readout-web` 是其余运行变量的部署权威。当前 CLI 登录为 `vinxucn-5010`，仓库 [.vercel/project.json](/Users/xuxuheng/Documents/MyProject/readout-web/.vercel/project.json) 精确链接现有 Global project；但 Vercel 对标为 Sensitive 的值在 `vercel pull` 中只返回 `[SENSITIVE]`，所以登录和 project link 只证明控制面访问，不能恢复这些明文。

没有找到另一份文档化、完整、当前且可导出的 Global core 私有配置包。新 project 若需要下列只存在于旧 Vercel Sensitive 环境中的值，必须由拥有原始值的人重新注入或按正式流程轮换；不能从占位文件、CN env、production function 或日志绕过提取。

## 明确的 GitHub 注入源

[backend-production-release.yml](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-release-guard-20260905/.github/workflows/backend-production-release.yml:23) 把 release job 绑定到 `environment: production`。第 100–112 行用 Environment Secrets 登录并精确链接旧 Global project；第 114–138 行直接从 `TTS_RUNTIME_METRICS_SECRET` 与 `TTS_OPS_ADMIN_SECRET` 注入 Vercel Sensitive 变量，同时写入公开的 upstream config。第 168–179 行也从 `VOICE_GIFT_E2E_BRIDGE_SECRET` 注入候选环境。

仓库的 `production` Environment 当前只列出以下 secret 名称（GitHub API 不返回值）：

| Secret 名称 | 最后更新时间（UTC） | 对新 core project 的作用 |
|---|---:|---|
| `TTS_RUNTIME_METRICS_SECRET` | 2026-09-01 09:13:39 | 可由 workflow 无明文搬运到新 project |
| `TTS_OPS_ADMIN_SECRET` | 2026-09-01 09:13:41 | 可由 workflow 无明文搬运到新 project |
| `VOICE_CLONE_WEB_BRIDGE_SECRET` | 2026-08-31 20:08:51 | 可由 workflow 无明文注入；需确认新 core 是否保留该入口 |
| `VOICE_GIFT_E2E_BRIDGE_SECRET` | 2026-08-31 08:48:42 | 仅候选 E2E/Voice Gift 合同使用 |
| `VERCEL_TOKEN` | 2026-09-05 00:56:21 | 部署控制面登录；不是应用 runtime secret |
| `VERCEL_ORG_ID` | 2026-08-29 03:06:43 | 当前 workflow 的目标选择 |
| `VERCEL_PROJECT_ID` | 2026-08-29 03:06:44 | 当前值绑定旧 `readout-web`，不能原样用于新 project |

[voice-gift-candidate-e2e.mts](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-release-guard-20260905/scripts/voice-gift-candidate-e2e.mts:861) 第 869–874 行明确记录了这一设计：Vercel pull 会隐藏 Sensitive 值，因此受保护 release environment 必须独立提供 bridge secret。这是项目内最直接的私有配置来源说明。

## 旧 Global Vercel pull 的可用范围

以下状态来自已链接旧 production project 的
`/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-regional-continuity/.vercel/.env.production.local`。只解析 key 名和占位状态，没有读取输出值。

可用的非占位配置包括：

- `TTS_RUNTIME_NODE_ALLOWLIST_JSON`
- `TTS_UPSTREAM_NODE_ID`
- `TTS_UPSTREAM_RECEIPT_SHA256`
- `TTS_UPSTREAM_RELEASE_ID`
- `TTS_UPSTREAM_URL`
- `DATABASE_URL`、`AUTH_SECRET`、`CRON_SECRET`
- 旧项目的 KV/Redis 连接变量

这些值来自旧 project pull，可以用于比对配置合同；是否适合拆到新 core project 仍需逐项确认最小权限、数据所有权和服务边界。

下列 core 相关 key 在 pull 文件中是 Sensitive 占位，**不可用作迁移输入**：

- `TTS_OPS_ADMIN_SECRET`
- `TTS_RUNTIME_METRICS_SECRET`
- `PIPELINE_API_KEY`
- `QUICKREAD_API_KEY`
- `PRO_INTERNAL_SECRET`
- `VOICE_CLONE_ENCRYPTION_KEY`
- `VOICE_CLONE_SUPABASE_BUCKET`
- `VOICE_CLONE_SUPABASE_SERVICE_ROLE_KEY`
- `VOICE_CLONE_SUPABASE_URL`
- `VOICE_CLONE_WEB_BRIDGE_SECRET`
- `VOICE_CLONE_WORKER_CA_CERT`
- `VOICE_CLONE_WORKER_TOKEN`
- `VOICE_CLONE_WORKER_URL`

其中前两个和 Web bridge 有 GitHub Environment Secret 来源；worker token/CA/URL、clone encryption、Supabase service role、QuickRead/Pro 内部 secret 没有出现在当前 GitHub `production` Environment Secret 列表中。这里能证明的是“当前可见配置源缺失”，不能推断它们从未在别处保存。

## 本地 `.env.local` 的边界

`/Users/xuxuheng/Documents/MyProject/readout-web/.env.local` 是 gitignored 文件，修改时间为 2026-08-08。按等号两侧去空格重新解析，当前有 36 个声明；其中第 19 行是带空格写法 `AUTH_SECRET =…`，值非空且不是已知占位，但本次没有读取或输出该值。文件还含 `DATABASE_URL` 和部分旧 LLM/邮件/支付变量，但没有当前 TTS runtime secret、TTS upstream contract 或新的 voice-clone worker/加密变量。只按等号切割且不清理变量名空格的检查会漏掉该声明。

它不是受审生产发布权威。现行 workflow 在 pull/build 前后都执行 `test ! -e .env.local`，见 [backend-maintenance-release.yml](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-release-guard-20260905/.github/workflows/backend-maintenance-release.yml:125)，防止本地文件污染 production build。因此它可以作为“曾保存过一部分旧配置”的线索，不能整文件复制到新 core project，也不能证明其中值仍与线上一致。

## 新 project 可直接推进与仍需输入的部分

可以直接推进：

- 复用现有 Vercel CLI 登录和 team，精确链接新 project；
- 在单独受保护 workflow 中，把 GitHub `production` Environment 里的两项 TTS secret 无明文注入新 project；
- 从旧 production pull 读取并审阅非 Sensitive 的 TTS upstream contract；
- 以 key 名/配置指纹验证新旧，不输出值。

仍需明确原始值或执行轮换：

- 新 core 实际需要、但只在旧 Vercel 中以 `[SENSITIVE]` 存在且没有 GitHub Environment Secret 副本的变量；
- 新 project 独立 DB/KV/对象存储时的最小权限连接，而不是默认复制旧全站权限；
- 新 `VERCEL_PROJECT_ID` 的 workflow 绑定，必须与旧 production project 分开，避免部署脚本误投旧项目。

因此，“已经登录 Vercel”解决了控制面权限，但没有解决 Sensitive 值可迁移性。当前安全路径是优先复用 GitHub Environment 中已有的少数 secret，其余由用户/管理员从原始密钥管理位置重新配置或轮换；没有证据支持从任何本地占位文件自动恢复完整配置。

## Team Shared Environment Variables 排除结果

2026-09-06 00:18 CST 使用当前已登录 CLI 对 `castreader` team 的只读 `GET /v1/env` 进行核对，只保留 id、key、target 和关联 project id，不读取或输出变量值。当前共有 5 个 Shared Environment Variables：`MYSQL_HOST`、`MYSQL_PORT`、`MYSQL_DATABASE`、`MYSQL_USER`、`MYSQL_PASSWORD`；五项的关联 project id 列表均为空。没有 TTS、voice clone、QuickRead、Pro、对象存储或运行时控制变量，因此现有 shared env 不能补齐新 core project 的私有配置。脱敏证据见 [global-vercel-shared-env-metadata.json](/Users/xuxuheng/Documents/CastReader/reports/backend-core-fixes-20260905/release/global-vercel-shared-env-metadata.json)。
