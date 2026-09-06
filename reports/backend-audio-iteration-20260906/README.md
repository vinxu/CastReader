# 核心音频迭代与上线后 24 小时观察

用户已授权继续修复、部署，并在迭代后观察 24 小时。本轮从上次[部署后数据审计](../backend-postdeploy-observation-20260906/README.md)继续。**截至 2026-09-06 10:20 北京时间（02:20 UTC）身份回读，24 小时正式验收尚未开始；旧移动端 direct gateway 修复已上线，Global 主网关仍是旧版。** 身份、发布记录和凭据更新时间见[最新只读回执](release/latest-global-status.json)。

## 已明确的问题与迭代

| 服务 | 证据与修复 | 当前状态 |
|---|---|---|
| `api.castreader.ai` Global 网关 | 默认上游流式返回多条 JSON，被单 JSON 解析器拒绝；明确要求上游完整音频 JSON。已审定源 `186e20b745b0b89f426d27d7f9ddb44f979dcae2` | 正式维护发布 `33979932773` 在使用过期 `VERCEL_TOKEN` 时失败；生产仍是 `3ce12a7c` / `dpl_58jqfHzCrV91FpC8s2unBG7XXcfX`。已向用户请求更新 GitHub production 发布凭据；保留原流程全部验证，不绕过 |
| `tts.castreader.ai` 旧移动普通音色入口 | 原网关只取上游第一条 JSON，可能 HTTP 200 却丢尾音频；改为明确要求完整音频并解析整个 JSON。源 `339a49fe201609ca4aa51055e360607cc2eb0656` | **已上线**：UTC 01:59:23 首次新流量，01:59:29 完成；8 项合同测试与独立复核、5 项发布故障注入通过；候选、原端口与公网真实 MP3 验证通过。见[生产回执](direct-gateway/status-receipt.json) |
| US Kokoro 英文短单元 | 重复数字 `00` 在原发音恢复分支仍可能空音素；将兜底拼读中的 ASCII 数字转为明确数字名，保留完整原文与两个零的发音。源 `ca857ee91c3367999fb905de1f0924a6e28edd81` | 62 项相关测试通过，同 US 不可变 R133 候选已准备，7 个隔离 CPU 真实音频案例完整解码通过；3.325 GB 原版完整恢复集已逐件读回核对。生产仍为 R132，未切换。见[候选证据](us-kokoro/README.md) |
| Android / iOS 播放 | 旧客户端严格解析附属时间戳，单个坏字段可使有效音频一起解码失败；增加附属字段降级、普通音色同区有界恢复和 Kindle 页面确认恢复 | Android `0663a5b`，iOS TTS `09dcb64`、Kindle `814030a` 已在各自线上基线的独立 worktree 提交；Android 两区各 12/12、iOS 94/94 定向测试通过。未发包，旧二进制尚未获得这些行为。见[客户端证据与边界](clients/README.md) |

所有音频修复保留原文完整性；时间戳、高亮和 marks 属于附属能力，不应拦截可播放音频。业务身份、非会员与额度限制保留。区域之间不互相兜底。

## 尚未完成的两项后端上线条件

1. Global 主网关：恢复 GitHub production 的有效长期 Vercel 发布凭据，并通过既有维护发布的全部验证。当前 CLI 已登录，但它不能创建所需长期令牌；已向用户明确请求更新 CI secret。
2. US Kokoro R133：完成同 US 的连续供给切换方案后才能替换生产。当前只有一个正式 GPU 实例；CPU 候选已停止、没有公网映射，也未经过并发容量验证，不能充当已就绪备用。旧 R132 同类切换曾实测 23.095 秒供给空窗，这不是本次 R133 的实测或承诺。本轮没有为追求上线状态而重启生产，也没有购买第二台机器。见[容量与切换边界](us-kokoro/r133-capacity-cutover-assessment.json)。

代码修复、候选验证和真正生产切换分别记录。Global 凭据恢复后，不能自动跳过第二项、把单实例重启当成连续供给发布；自动化会保留这个剩余条件。

## 新增定位证据

Android 1.0.45 的普通音色实际先请求 `tts.castreader.ai/api/captioned_speech_partly`，并明确发送 `stream:false`；仅运输错误或 5xx 才回退同区 `api.castreader.ai`。之前单查 Vercel 无法覆盖该首入口。

此前失败附近 `2026-09-05T23:49:45Z–23:53:30Z`，旧 direct gateway 记录 **70 条 Android 1.0.45 请求，全部 HTTP 200**。日志无设备关联，不能断言它们全部来自失败设备；也不能仅凭 HTTP 200 判定播放成功。当前固定非用户西语 `ef_dora` 样本 200、38,445 字节 MP3 完整解码，时间戳结构正常；它不是原失败正文，不能证明当时的响应也正常。见 [direct gateway 证据](direct-gateway/android-failure-window.json)与[当前固定样本](direct-gateway/es-synthetic-probe.json)。

## 兼容入口发布保护

候选仍运行在同一 US 控制机、使用原 US GPU 上游。原源码、systemd unit、Caddy 配置与进程身份均固定。完整原版备份已在原 US 主机创建，并直接上传到已批准的 Global 私有存储，再完整读回核对：4,130 字节，SHA-256 `1bfc6c479149c8b82bbe2c4b67684dfaf793bc2020e82a0576d47788b6d06917`。见[备份回执](direct-gateway/offhost-readback.json)。

切换已按蓝绿流程完成：先将新请求路由到已验证候选，等待原实例在途请求结束，再替换原实例；原端口验证成功后恢复原 Caddy 配置并等待候选排空。事务由服务端 systemd 持久进程执行，最终 `Result=success / ExecMainStatus=0`。正式 gateway PID 从 `374442` 变为 `553831`；Caddy PID `4980`、QuickRead PID `543663` 保持不变。Caddy 原配置字节完全恢复，实际运行路由核对为 `127.0.0.1:7778`，临时实例已排空停止。没有连续高频端到端可用性采样，不额外宣称零停机。

UTC 02:06:59 公网验证完成：英文省略 stream / true / false 均 200、132,141 字节 MP3、198,144 个 PCM 采样，余文为零；西语 `ef_dora` 为 200、38,445 字节 MP3、57,600 个采样。全部完整解码，请求从同一 US 主机发出。见[公网音频验证](direct-gateway/public-production-probe.json)。切换后的完整生产源码、服务配置和回执也已在 Global 私有存储完整上传并读回：5,061 字节，SHA-256 `524f7f00133d281f76deb48a2df53bf3d4d4a3849b2e1b14f9f9dc723e180774`；见[生产备份回执](direct-gateway/offhost-production-readback.json)。

## 24 小时观察

本任务已创建每小时唤醒的自动化 **“核心音频迭代后24小时验收”**，ID `24`；服务器原有探针仍每约 5 分钟运行。验收状态唯一来源为 [acceptance-state.json](monitoring/acceptance-state.json)。

监控工具 28/28 定向测试通过，默认等待状态实际运行仍为零生产查询、零观察秒数。客户端证据必须配对同平台、同会话且时间顺序正确的“开始朗读 → 首音频”；只有开始、没有首音频只能记为证据不足，不能通过。自动化的配置与等待边界见[记录](release/automation-receipt.json)。

- `waiting_release`：正式上线前，不启动 24 小時計时，不把旧部署故障算作新版本观察。只检查发布阻塞是否解除。
- `observing`：记录已验证生产版本、真实 UTC 起点和固定 24 小时终点。每小时读取两区现有探针、Global 服务端接收时间的客户端事件、Vercel 核心 5xx 与旧 direct gateway 日志；额外只读核对 Global 当前 deployment/commit 和 US Kokoro 的真实 release 路径及文件 SHA，发现其他分支覆盖版本时不能继续按原版验收。
- 到期汇总实际覆盖、客户端失败、业务限制和数据缺口，并暂停自动化；不因样本不足自动延长。

供给监控正常与用户完整听完是不同指标。自动结论仅针对已接入的数据源；它不能单独认证 Web、扩展、全部克隆/解读分支以及完整无跨境。样本不足、任何采集缺口、版本漂移、未满 24 小时都必须保留，不能用“没有错误日志”推断全链路稳定；没有请求关联也不能给出未经证实的单次故障归因。观察期间只读，不额外合成、不重启业务、不外发客户消息。

## 发布凭据恢复后的明确下一步

只在 GitHub `production/VERCEL_TOKEN` 元数据已更新、`beta` 顶端仍为上述已审定 SHA、生产仍为已固定基线且没有并行发布时，通过原 `backend-maintenance-release.yml` 重跑已审定版本。保留所有测试、候选真实音频、业务鉴权、精确生产身份核对与回滚。若源或生产已被其他任务改变，先重新审查，不自动发布新源。

本机 Vercel CLI 登录已有效；障碍不是找不到登录方式。官方接口以当前 CLI 会话创建长期令牌返回权限错误，浏览器控制连续超时，因此需要用户在 Vercel Dashboard 创建专用发布令牌并更新 GitHub production secret。不得把短期 OAuth 再作为长期 CI 凭据，也不把密钥写入聊天或报告。
