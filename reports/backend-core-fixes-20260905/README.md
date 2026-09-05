# 核心音频稳定性迭代与上线记录

本轮始于 2026-09-05，记录继续更新至 2026-09-06。依据是上一轮[完整生产审计](../backend-architecture-review-20260905/README.md)，不是根据旧架构文档推断线上版本。用户已授权修复、验证和部署；新增付费 GPU 与缺失的区域控制入口另行确认。

## 验收顺序

1. 修复已定位的 Kokoro 供给失败和 QuickRead 续块失败。
2. 固定完整区域生产版本；发布必须校验文件、配置、运行进程、备份和当前入口，保留精确回滚目标。
3. 统一生成超时与同任务恢复，接入已验证的同区备用。
4. 独立发布核心音频，持续验证真实多段音频供给。

原则：音频和正文完整性优先；高亮、marks、时间戳和非关键统计不能停止播放。业务身份和额度规则保留。中国区与国际区不互相兜底，不用另一地区的录音、模型或配置恢复本区。

## 已完成上线

**中国区和国际区持续供给监控**已分别安装在各自区域的控制服务器，5 分钟运行一次。初次上线源版本为 `272d3148d6a93cec079d7dc649a78d406e5fe36f`。

- 手动验证和定时验证均完成 3 段真实 MP3 合成、完整解码与余文闭合：`45 → 23 → 0`。
- 固定非用户诊断文，固定 `zf_001`；请求与上游均验证为中国区。
- 时间戳异常单独记作对齐降级，不把可播放音频判为供给失败。
- 不调用重启服务；没有外发告警，仅本地记录异常与恢复。
- 安装前后 Next、QuickRead、Nginx 和相关业务服务的进程及配置未变化。
- 国际区固定 `af_heart`，真实连续两段、余文 `211 → 0`，总音频 37.464 秒；手动及定时运行均验证通过。

完整证据见[中国区上线回执](release/cn-monitor-rollout-receipt.json)和[国际区上线回执](release/us-monitor-rollout-receipt.json)。这是后端多段供给验证，不等同于四端播放器、Kindle 翻页或克隆音色的端到端验证。

**两区监控均已部署旧客户端请求合同检查**：源版本 `f6eb669178c665defff239fd8a60210b54894aeb`，沿既有余文段依次检查省略 stream、true、false，不为覆盖合同而额外生成段；同段失败仍按原预算重试。2026-09-05 18:08 UTC 的上线实测准确捕获旧 Global 网关 `http_502 / stream_omitted`，不能再沿用旧监控 healthy 的结论。业务进程和配置未变。见[监控升级回执](release/monitor-legacy-contracts-20260906/README.md)。CN 同一升级也已完成：18:31 UTC 同样准确捕获 `http_502 / stream_omitted`，业务进程和配置前后相同。这两次上线探针都在首段失败，尚未执行后续 true/false；它们证明监控能识别真实故障，不证明三种合同在生产已全部通过。

**中国区网关切换后，监控已自动恢复**：18:52:32 UTC 记录恢复事件，18:57:43 UTC 下一自动周期再次成功。两次都完成三段真实音频和全部余文，合同为省略 stream → true → false，余文 `45 → 23 → 0`，216,324 字节、13.44 秒音频完整解码。本次只回读已存在的自动结果，没有额外启动探针。见[中国区修复后监控回读](release/monitor-legacy-contracts-20260906/cn-post-gateway-recovery-readback.json)。国际区正式入口的对应故障仍待发布修复。

**中国区 TTS 网关完整音频响应修复已上线**：18:50:14–18:50:21 UTC 切换到 `release-20260906014729` / `9d652ec87d48a65d05e088d4655e806777dead12`，新 Next PID 为 `1630406`。公网回读版本和 CN 路线一致；原有账务、schema、鉴权、克隆、解读和 TTS 发布检查全部保留并通过。切换采样共 16 次，14 次 200、一次 502、一次超时，相邻成功样本最大间隔 3.750 秒；不宣称零停机。QuickRead、两个 GPU 隧道、Nginx master 和监控版本均保持原身份。切换后的完整 release 与私有运行配置已在上海私有 COS 完整上传、读回并核对 SHA，41,046,123 字节，19:03:15 UTC 验证完成。见[切换日志](release/cn-tts-upstream-framing-20260906/cutover-attempt2-activation.log)和[生产备份回执](release/cn-tts-upstream-framing-20260906/post-release-shanghai-cos-backup.json)。

**国际区 Kokoro R132 已切换生产**：2026-09-05 16:38:43 UTC 完成切换和生产 GPU 验证。7 组真实 PCM 验证通过，包括原缺失发音、两种音色、带/不带时间戳和长文本尾部完整性。这仅证明生产 GPU worker 入口；当时 `api.castreader.ai` 的省略 stream 请求仍然 502，未据此证明公网网关、四端播放器或克隆链正常。克隆与 Nari 服务进程身份保持不变。150 毫秒间隔的本机探测测得，旧实例不可用至新实例健康之间为 23.095 秒；这是单实例重启的供给空窗测量，不能宣称零停机，也不等于已确认每个客户端中断 23 秒。同区恢复集由已完整读回的不可变基座和切换后完整读回的 R132 增量组成；额外重复下载基座因限速停止，没有计入成功。完整证据见 [R132 上线回执](release/us-r132-rollout.json)，证据提交 `680133c24fa2bca7ba052ba89730cdd9caaca4a4`。

**国际区 QuickRead 恢复修复已上线**：2026-09-05 17:45 UTC 完成生产后端验证。在生产机本地入口使用已发布的 `extract-block` 请求合同，真实 Gemini 生成首块与后续块均成功，已持有任务句柄的调用可复用持久化状态，同块重复调用命中相同内容。公网验证健康与鉴权合同，未运行真实旧客户端二进制做端到端验证。切换采样观测到短暂 502：失败样本跨度 150 毫秒，前后成功样本保守括号 340 毫秒，不宣称零停机。完整证据见 [QuickRead US 上线回执](release/quickread-playback-continuity-20260906/us-production-rollout-receipt.json)。

**中国区 QuickRead 恢复修复已上线**：生产机本地入口的真实 DeepSeek 首块、已发布接口合同续块、同块缓存重复验证全部通过，生产仍使用中国入口与本区配置。公网验证健康与鉴权合同，未运行真实旧客户端二进制做端到端验证。切换时公网捕获 1 个 502 样本，前后健康鉴权响应的保守括号为 130 毫秒。部署后的完整源码已在上海私有 COS 上传并完整读回校验。见 [QuickRead CN 上线回执](release/quickread-playback-continuity-20260906/cn-production-rollout-receipt.json)。

## 源版本与上线状态

| 改动 | 完整源版本 | 验证和上线状态 |
|---|---|---|
| Kokoro 英文发音恢复 | `dd613e1c6dab280d6110455f7b721301ddbbb857` | US R132 已上线，生产 GPU 7/7 通过；CN GPU 控制入口不可达，尚未更新 CN |
| Global 网关完整音频响应合同 | `26d0832c7da8a604792abc7592e110cc6f2755e1` | PR #24 已合并为 `186e20b745b0b89f426d27d7f9ddb44f979dcae2`；候选实音频三种 stream 参数均成功，正式维护发布被过期 CI 令牌阻塞，尚未上线 |
| 中国区网关完整音频响应合同 | `9d652ec87d48a65d05e088d4655e806777dead12` | 基于 CN 原生产 `62386e`，仅移植两文件修复；第一次切换回滚，第二次切换已成功，公网版本一致、自动监控连续两轮三段完整解码成功、上海私有生产备份完整读回 |
| 中国区正式发布脚本的就绪与回滚保护 | `ec117d38d935cacdc4300d86b76467cd2a9ea848` | 已独立提交且复核通过，15 项测试通过；与成功切换使用的脚本执行逻辑一致，只改变发布工具，生产应用仍为 `9d652ec` |
| QuickRead 超时、断线和续块恢复 | `3d68d82e307cba36710f1a8100f80ea50a1f178b` | 80 项测试；US/CN 均已上线，分别完成真实 Gemini/DeepSeek 续块、公开鉴权合同及各自私有存储备份读回 |
| 扩展 SSE 主动恢复 | `15f4e72aaa9db197a0d4c1ce551c6a162febc614` | 独立提交，合同测试与构建通过；未发布，不计入纯后端上线 |
| 完整发布清单与 CAS 校验 | `4b39d32fd35d910a2b4b99e7b7b0d2ba5df0b12c` | 通用合同已提交；US Kokoro 与两区 QuickRead 本次切换已执行真实文件/进程 CAS 和事务回滚保护；仓库权限层的收口仍未完成 |
| 核心音频独立制品 | `18929fa7a38042cf1c7f65ab23af5f6263a33957` | 独立 Vercel 候选已同步网关修复并部署；普通音色连续两段和三种 stream 参数完整音频均通过，生产入口未切换 |
| 独立候选发布保护 | `7b7ec0a6a07fa7e25635af736ff19cdc297fb97d` | 拒绝制品额外文件、根环境文件、错误部署 ID；缺少 GitHub 控制面保护时失败；未推送启用 |

Kokoro 的已证实触发原因是发音前端对某些独立词元返回空音素；原有音频回退也无法生成该词元，最终 500。本次仅恢复缺失发音，保持同模型、同音色、原文和完整音频协议。已正确发音的词元以及显式静音标记保持原合同。

另一个独立且两区均复现的 502 原因位于网关：Kokoro 默认流式响应会返回多条 JSON 音频记录，网关却把整份响应作为单条 JSON 解析，导致已经生成音频仍被判为失败并重复生成。修复在普通音色的上游请求中明确要求完整 JSON，保留全部音频，不只取第一条记录；客户端逐段接口、余文推进、克隆分支与区域路由保持原合同。中国区已上线并通过多段验证，国际区正式网关尚未更新。

中国区第一次切换未保留失败新进程的字段快照，不能断言具体哪项配置不匹配。证据最支持 `Type=simple` 的启动时序竞态：隔离验证使用相同 EnvironmentFiles 和启动方式，新版本约 4 秒后才真正就绪，随后原配置检查全部通过。正式脚本现要求本机响应前后为同一 PID，进程、工作目录、发布版本、源码和 CN 路线全部匹配后，才执行原有业务检查；失败和退出均回滚，回滚不完整保留私有备份，不按修改时间删除旧版本。这些保护只用于发布，不增加用户播放时的闸门。

QuickRead 不再把供应商/持久化/超时等技术错误一律返回 400，让旧客户端误以为内容已经结束。同一任务与同一块复用生成；已持久化的首块可在进程恢复后继续。两区生产后端已按已发布的 `extract-block` 请求合同验证恢复和同块缓存复用，未做真实旧客户端二进制端到端验证。若客户端在收到并保存 `job_id/block0` 之前断线，服务器无法替它恢复已丢失的任务句柄；扩展主动恢复改动尚未发包，原生端同等早期 SSE 恢复也仍需后续客户端版本。不能把本次后端上线表述为这部分客户端能力已具备。

## 独立发布与资源边界

新 Global Vercel 项目为 `castreader-core-audio`，ID `prj_EknF8IKAv8mDy4QEGb2z4VoX6n2f`，Node 22，显式 Global 路线，`iad1` 构建制品。音频候选入口只构建明确的核心路由，不包含营销页面、MDX 或 SEO 中间件；未登记的核心路径不回退到网站代码。

最新实际候选为 `dpl_46biYYh2Lj8jMeZnii5JynpFWBKG`，已核对 baked commit、source SHA、Global 区域和实际部署 ID，并完成普通音色连续供给、未登录克隆接口 401、未知核心接口本地 404。原失败文本的 stream 省略/true/false 三组均为 200、77,997 字节音频、完整解码 116,928 个采样。证据见[候选验证](release/global-core-candidate-preset-attestation.json)。`api.castreader.ai` 仍指向原生产版本，不能把独立候选成功当作旧网关 502 已在线修好。

2026-09-05 19:01:49 UTC 的公网 `/api/capabilities` 回读仍为 `dpl_58jqfHzCrV91FpC8s2unBG7XXcfX` / `3ce12a7c794e3d9788a7982a66a62f70a9407678`，clone/gift 路线为 Global。CLI `vercel whoami` 同轮复核成功；缺失的是正式发布所需的专用凭据与配置，不是找不到项目登录方式。

候选 workflow 固定项目 ID、完整源 SHA、每个文件的 SHA 和真实多段音频验证；默认不切生产域名。当前 GitHub `beta` 未保护、Production 没有必审人和受保护分支限制；现有账号无仓库管理权限。因此 workflow 按设计在使用 Vercel 凭据前失败，尚未推送启用。这不是已经完成的发布权限收口；详见[入口审查](release/core-audio-candidate-workflow-review.md)。

已找到用户提供项目中的 [Vercel 登录记录](/Users/xuxuheng/Documents/MyProject/readout-web/MEMORY.md)，CLI 登录正常。新项目所需的部分生产值在旧 Vercel 中标记为 Sensitive，合法导出得到 `[SENSITIVE]`；这些占位符不会被部署成密钥。现有 GitHub production secrets 可以供应其中几项，其余来源核对见[配置来源证据](release/global-vercel-private-config-source-audit.md)。

后续已从已验证的 Global 源迁移 8 项配置到新 core 项目，见[受控迁移回执](release/global-core-authoritative-configuration-migration.json)。原 worker 公钥证书已从 Caddy 的实际 TLS 终止配置找到，指纹与公开入口相同，并通过证书校验。新 core 运行配置仍缺原 `VOICE_CLONE_ENCRYPTION_KEY`，以及在 GitHub Production 有可注入来源但尚未配置的 `VOICE_CLONE_WEB_BRIDGE_SECRET`。不能生成替代录音加密值，否则已有克隆参考录音无法解密。没有修改现有生产项目的密钥。

另已证实 CI 凭据失效：GitHub `VERCEL_TOKEN` 在 2026-09-05 00:56 UTC 更新，一秒后启动的发布成功；维护发布 `33979932773` 随后因该令牌无效在候选构建前停止。Vercel 同期 CLI OAuth token 于 08:27 UTC 到期，与误存 8 小时 access token 的时间线高度吻合；GitHub 不允许读回 secret，尚未做逐值比较。当前 CLI 会话可正常部署，但官方创建专用 PAT 的接口返回 `403: Cannot create tokens for this app.`；未把另一枚短时 OAuth 或 refresh token写进 CI。需由账号 Dashboard 配置只限旧 `readout-web` 的专用发布 PAT 后重跑同一版本。记录见[CI 凭据诊断](release/tts-gateway-framing-20260906/ci-token-provisioning.json)。新 core workflow 另使用 `VERCEL_CORE_AUDIO_TOKEN`，避免共用网站发布凭据；该独立 token 尚未配置。

US 目前没有已经验证的暖备用 GPU；新增约 $305/月的同区节点已向用户询问预算。CN 备用节点和主 GPU 控制入口仍缺当前可用控制权限。不能把未购买、未恢复或不能连接的机器记为可接管备用，也不能把单机重试宣称为高可用。

剩余交付条件集中如下：旧站专用长期 Vercel PAT、新 core 独立 PAT、GitHub 管理权限及实际生效的分支/Production 保护规则、上述两项克隆配置、US 同区暖备用预算、CN 备用资源预算和主 GPU 控制入口。现有 CLI 登录不能替代这些缺失项；完整路线尚未全部交付。

## 发布依据

[完整发布基线与切换合同](release/README.md) 记录生产文件差异、备份、排空、精确切换和回滚要求。US 与 CN QuickRead 的 `extract-content.mjs` 当前真实字节不同，本次必须分别从各自生产基线构造完整制品；禁止整文件跨区覆盖。
