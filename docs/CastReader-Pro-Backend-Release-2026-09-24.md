# CastReader Pro 后端发布与验证回执

> 阶段记录归档：本文保留当时的计划、验证与发布状态。2026-09-25 后续客户端修复、送审状态及用户核查结论，以 [本轮交付汇总](CastReader-Pro-Release-Closure-2026-09-25.md) 和现行 [Pro 一致性标准](Pro一致性标准.md) 为准；早期到期计时器等设想不覆盖最终移动端实现。

最终更新：2026-09-25，Asia/Shanghai。本轮服务端修复已全部发布并完成上线回读：官网、全球 API、中国区 QuickRead。范围是已确认的服务端判权、身份归一、错误隔离和中国区错误账本查询；不是整个 Pro 审计项目全部完成，也没有发布扩展、iOS 或 Android 新包。客户支付、订阅、赠额和设备归属没有手工修改。

## 发布状态

| 服务 | 状态 | 不可变源码 / 产物 |
|---|---|---|
| castreader.com / www | 已上线并回读 | `3b054ed2c195246880e61ac4744098cfc7af8d78` / `dpl_4AqP1KPV4mrvhkDmH6KhRGRmsD8T` |
| api.castreader.ai / castreader.ai 兼容入口 | 已上线，两域回读同一验收产物 | `95c32ff74e29a7e6a729a103c48ce6baaf1451e8` / `dpl_FWfxYHyCNpbK6LDykRHLqZosfCCZ` |
| CN QuickRead | 已上线并回读 | `cbd956713ae66d5fdc0f2a8cf269badf91701e0f` / `20260924-pro-account-realm` |

## 实际改变

1. 官网取消自行添加的 Stripe past_due 三天 Pro 宽限。有效订阅、未到期取消续费、有效试用保留 Pro；到期、欠费等返回非 Pro。共享纯策略及 status / entitlement / consume handler，版本和 SHA-256 在两个仓库的 CI 检查。
2. 展示和解读准入复用 canonical 账号解析。明确的账号身份不能继承旧设备会员；账号查询不修改绑定。
3. 保留 30 秒权益缓存、并发查询合并与 `fresh=1`；已知有效期到达时缓存立即失效。Pro 跳过免费额度查询和扣减；Free 的暂时查询故障保持可重试，不伪装成余额零或会员撤销。
4. 移动端历史安装归属冲突不再吞掉真实会员结果；别人的赠额不会被转移。其他 Free 额度依赖故障保留原有 503 语义。
5. 免费解读的最后一份额度用原子有界 upsert 决定准入。该改动不声称为任意新建任务重试增加了完整幂等键；同一任务续块、恢复沿用现有免重复扣费实现。
6. CN Nginx 仅对旧 API-key worker 入口写入服务端私有标记，覆盖客户端同名头。worker 仅接受 loopback + 匹配标记，按全球账号查询 `.com`；CN 原生会话代理重建请求头，继续使用本地账本。计算线路、模型、TTS 路径没有迁移。

## 已取得的证据

- 官网候选：4 类真实账本状态 × ID / 邮箱 / Google subject / 内部不消费查询，共 16 项一致；付费、试用 true，过期、past_due false。
- 官网生产：同样 4 类状态的 12 次公开身份查询一致；8 项页面、商店链接、checkout 登录门禁及过期样本检查通过；30 分钟 error 日志查询未返回记录。
- API 独立候选线上探针：5 类公开真实会员样本通过；历史安装归属冲突下的认证 status 正常，最终阶段 `mobile-conflict-marker` 通过；账单写入 0。Kindle 专项重测的 QA 清理出现客户端传输失败，随后只读 SQL 确认仅该 QA scope、候选为 rejected、没有已发布策略。
- API 本地：41 项 Pro 检查、真实隔离 PostgreSQL 身份/过期/封禁测试，以及 20 并发争最后一份免费额度的断言通过。移动候选只开放显式启用的精确候选主机上的只读 status 路径。
- CN：89 项测试通过，覆盖内部查询故障不误拒、续块免扣、断线恢复、任务持久化等。
- CN 候选及生产：同一真实付费账号在全球库为 true、中国库为 false；修复后经中国计算入口成功生成 block0 / done，resume-plan、extract-block、compose-block 均 200。生产完整探针耗时 7.41 秒，日志观察到 `realm=global pro=Y`，没有权益查询失败。
- CN 存量任务：重启后恢复原讲解，持久状态文件不变；两个 CN 原生入口的伪造标记匿名请求仍返回 401。
- CN TTS：真实 HTTP 200，48,812 字节 MP3，经 ffprobe 确认为 3.048 秒，6 个时间戳。
- CN 切换前确认队列、活动任务和连接清空；新任务准入短暂停止 1.22 秒，原账号 API 进程不变；没有重启 TTS。变更前后完整私有备份均上传上海 COS，完整下载 SHA-256 及回执回读通过。
- 最终 API 受保护发布 [36032768374](https://github.com/scmyyan/readout-web/actions/runs/36032768374) 成功：真实候选 TTS、Voice Gift、Kindle 9 项检查及 QA 清理、Reading Fix 持久化、5 类 Pro 样本及认证历史安装冲突均通过。切换后两个 API 兼容域名返回同一源码及产物，真实 TTS 再次通过。
- 最终生产跨服务验证：`.com` 与 `api.castreader.ai` 共 30 项公开身份和内部不消费查询通过，active / trialing 为 true，expired / past_due 为 false。当前 active 样本没有 Google subject，因此该状态仅检查 canonical / email / internal，未把缺失的两项计为通过。
- 最终生产认证回归：投诉样本的历史设备组合共 9 次 status 查询全部 HTTP 200、全部为数据库对应的 false；前后订阅、设备关联及赠额记录完全相同。官网两域仍指向已验收的官网产物；CN current、worker 哈希、Nginx 哈希及健康检查符合已发布版本。

## 发布流程中发现的阻碍

API 最初因另一已验收版本先上线，被生产基线比较拦截；已合入最新 Mac Safari 等改动，未覆盖他人功能。随后遇到 TTS 测试时序问题及真实 Kindle 模型 503；当时保留原生产产物，未绕过门禁。历史失败工作流：[36016408711](https://github.com/scmyyan/readout-web/actions/runs/36016408711)。这些阻碍已按下节完成排查，最终完整工作流通过并上线；历史阻塞不代表当前仍未发布。

## 9 月 25 日追加排查

原 API 候选未改模型或配置，Kindle 真实模型 9 项复测恢复通过，清理 verified；详见 [Gemini 503 排查](CastReader-Gemini-503-Investigation-2026-09-25.md)。完整门禁另复现 TTS 退避等待丢失 TimeoutError / 调用方取消原因，已在 [PR #49](https://github.com/scmyyan/readout-web/pull/49) 修正，新增两项测试对旧实现均失败，修复后 48 项 TTS 测试通过。CI 的 HTTP 连接关闭测试另出现两次 500ms 观察超时；独立 macOS / Linux Node 22 均未复现。[PR #50](https://github.com/scmyyan/readout-web/pull/50) 仅让测试服务先消费请求体，并把异步对端关闭观察窗口改为 2 秒、增加安全诊断；同步取消、实际关闭和成功音频断言保留。生产播放时限和重试次数均未改变。包含这两项的最新 protected beta 源码已完成全套门禁和生产切换。

## 上线后日志中的独立问题

该产物最近 15 分钟 error 日志回读包含监控 Redis 超额、旧 `.ai` 中文页面缺少文案，以及预期的 Voice Gift 无效草稿负例。未观察到 Pro 验证对应的错误。Upstash 报告请求上限 500,000、使用量 500,006；原生产产物 `dpl_CzWYAEXjZF791eW9iEHZJbmTXo8K` 的切换前日志亦出现相同错误，不是本次新增代码引入。监控上报先写 PostgreSQL，缓存失败被捕获，接口仍返回 201；真实 TTS 验收通过。但 Redis 容量告警及其其他调用方的影响仍需单独处理，不能宣称全站零错误，也没有擅自升级付费套餐。

## 没有声称已经完成的部分

- 60 分钟真实弱网听书、各旧客户端 UI 和系统本地商店 OR 状态闭环仍未验收。本轮没有增加逐段、逐块权益查询，也不等于完成小时级实机稳定性验证。
- 离线或持有旧缓存的客户端只能在下一次成功刷新时收到更新；旧版扩展 402 清理漏释放播放占用属于客户端缺陷，需另发包，服务端不能改掉已安装代码。
- 支付事件幂等/乱序/退款范围及多商户对账仍是独立待完成阶段；本轮没有批量重写账本。
- 发现 Apple 一条有效状态记录的 current_period_start 在未来，可能是续订周期投影，尚未核清；本轮不据此新增起点拒绝、避免误撤。不能把旧的 104 项审计基线或未来起点断言标成全绿。
- 已发布匿名 TTS、可自报身份的旧 API-key 协议、人工/审核授权及商店合法 grace 的既有边界保持，不把兼容提示升级为强认证。
- Gemini 的有限退避和更完整脱敏错误分类尚未实现；本轮确认间歇性恢复并通过真实模型门禁，未将其表述为永久解决上游 503。

## 回滚

官网两域同时回退到 `dpl_CqQDaTh4NU3KCLx6ZEK9Uqpg2G7D`（`castreader-content-m7sorm3jt-castreader.vercel.app`）。CN 回到旧 current `20260908-cn-response-recovery-1660a11`，恢复备份中的 Nginx 配置并去掉新增的 Pro environment drop-in，仅重启 QuickRead；保留当前持久任务目录。API 按受保护工作流保存的两域基线逐一恢复到 `dpl_CzWYAEXjZF791eW9iEHZJbmTXo8K` / `0079d124f87d57ac00d5ad8b6eb56093c15d0699`，不能回到过时的 `0a4c32ed` 丢失最新功能。

私有客户数据和运行证据保存在本机受限审计目录；本回执只包含版本、脱敏结果及已知边界。
