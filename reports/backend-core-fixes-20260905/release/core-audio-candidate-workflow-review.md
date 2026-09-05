# Core audio candidate workflow 独立复核

复核对象：`/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-service-isolation-20260905` 中提交 `a1691c343b7c21d4824b15b1aa798ee0e45415d0`；只读复核，没有修改该工作树。复核时间：2026-09-06 00:24 CST。

## 结论

固定新 Vercel project、`--skip-domain`、无 cron、源码 manifest、真实普通 Kokoro 多段解码检查这几个方向成立；它可以安全地继续作为**未切流候选**。当前仍有三个发布门禁缺口，其中第一个必须在让 workflow 接触 Production secret 前修复。

本复核不重复 root 已发现的 Vercel CLI 59.10 agent-mode stdout 可能是 JSON deployment envelope、不能原样当 URL 的问题。

## [P0] `release_sha` 可指向仓库任意提交，但 job 直接取得 Production Vercel token

[core-audio-candidate.yml](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-service-isolation-20260905/.github/workflows/core-audio-candidate.yml:23) 第 23 行进入 `production` Environment；第 31–34 行按用户输入的 40 位 SHA checkout；第 47 行只验证“输入等于 checkout HEAD”，没有验证该 SHA 属于受审分支、受审 tag 或允许的 release manifest；第 68 行随后把 `secrets.VERCEL_TOKEN` 提供给 job，并在第 74–75 行执行刚才那个任意提交里的 Node 脚本和 Vercel build。

现场控制面进一步放大了这个缺口：`scmyyan/readout-web` 的 `Production` Environment 当前 `protection_rules=[]`、`deployment_branch_policy=null`，`beta` 分支 `protected=false`。因此“必须是 exact SHA”只解决可复现性，没有建立 SHA 的可信来源。具备 workflow dispatch/写入权限的人可以让未评审提交中的构建脚本在 Production token 存在时运行；即使 workflow 本身不 promote，该 token 和新 project 仍暴露在未受信源码的执行边界中。

最低门禁应由 workflow 自身的固定 shell/可信 action 完成，且不能调用待审 SHA 内的脚本来证明待审 SHA可信：例如只接受已合并到一个受保护 release ref 的 SHA，或接受由独立签名/审批流程产生且绑定 commit + artifact digest 的 release manifest；同时给 Production Environment 增加 reviewer/branch policy。项目 ID 固定校验不能代替源码信任门禁。

## [P1] “验证每一个 artifact 文件”只验证 manifest 列出的文件，不拒绝额外文件

[verify-core-audio-artifact.mjs](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-service-isolation-20260905/scripts/verify-core-audio-artifact.mjs:24) 第 24–39 行遍历 `manifest.files` 并检查这些文件的 bytes/SHA，但没有枚举 artifact 根目录并与 manifest 做集合相等比较。因此额外的未登记 route、脚本或配置不会参与 `sourceSha256`，仍能通过验证。

独立无网络复现：从当前 clean commit 生成正常 artifact，在 manifest 写完后新增 `src/app/api/unlisted-review-probe/route.ts`，随后运行原验证器，退出码仍为 0，并输出 `ok:true`。现有 9 项 artifact/deployment/routes 测试全过，但没有覆盖未登记文件。

修复时应在第一次验证（尚未执行 `vercel pull/build`）要求 artifact 实际文件集合严格等于 `manifest.files + core-audio-manifest.json`。第二次验证需要只额外允许预期的 `.vercel/project.json`/Vercel metadata；不能简单忽略任意隐藏目录或生成目录。

## [P1] 部署身份没有与当前 candidate deployment ID 做外部绑定

[verify-core-audio-deployment.mjs](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-service-isolation-20260905/scripts/verify-core-audio-deployment.mjs:52) 第 52–55 行读取 identity 后调用 `assertCoreIdentity(identity, manifest)`，没有传 `expectedReleaseId`。而 [verify-core-audio-artifact.mjs](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-service-isolation-20260905/scripts/verify-core-audio-artifact.mjs:46) 第 46–51 行只有在 caller 提供 `expectedReleaseId` 时才比对；当前只要求返回值长得像任意 `dpl_*`。

候选 URL 已严格限定为 `.vercel.app` 且 `vercel curl --deployment` 不跟随 redirect，这降低了误命中概率，但 attestation 没有独立证明“这份 identity 的 releaseId 就是 workflow 刚创建的 deployment”。应从结构化 deploy envelope 或 `vercel inspect` 获取实际 deployment ID，把它作为参数传给验证器并写入安全 attestation；后续 ingress CAS 才能绑定到同一 target。

## 生产切流仍需独立门禁（当前 README 已承认，不算候选构建 bug）

[verify-core-audio-deployment.mjs](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-service-isolation-20260905/scripts/verify-core-audio-deployment.mjs:56) 当前只验证两个 clone 列表端点无身份时返回 401、一个未知 QuickRead route 本地 404，以及普通 Kokoro 多段连续供给。它没有验证 clone 合成、voice upload/STS、QuickRead 创建与 continuation、documents、Pro/额度和既有兼容 URL。当前新 project 又缺 clone/QuickRead 等 Sensitive 配置，所以普通多段通过不能被表述为“完整 core 可切流”。

[services/core-audio/README.md](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-service-isolation-20260905/services/core-audio/README.md:58) 第 58–65 行已经准确说明这是 candidate-only、不会 promote，clone/QuickRead E2E 与 fresh ingress CAS 仍是迁移门禁。只要后续 promotion 流程强制消费这些独立 attestation，此边界可保留；如果未来把本 workflow 的 `ok:true` 直接作为切流许可，就会形成错误放行。

## 已确认成立的部分

- 固定 org/project/name 校验会拒绝旧 website project；workflow 的 Vercel link 指向 dedicated project。
- `--prod --skip-domain` 是 Vercel CLI 59.10 的有效参数，创建 production-environment candidate 但不自动 alias。
- 生成 artifact 的 `vercel.json` 明确 `crons:[]`，不会与旧站 Vercel TTS cron 重复调度。
- candidate URL 限定 HTTPS `.vercel.app`、无端口/path/query，底层 curl 不带 `--location/-L`。
- 普通供给检查会跟完 `unprocessed_text`，至少两段，逐段 ffmpeg 解码，并强制 `global` 区域响应。
- 本地 `build/verify/deployment/routes` 9 项定向测试全部通过；上述 P1 额外文件缺口是现有测试未覆盖的真实反例。
