# CastReader iOS 中国区双网关严格测试计划

状态：代码准备与本地验证阶段，**未部署、未改 DNS、未上传 TestFlight、未提交审核**。

## 1. 三个彼此独立的对象

本轮必须分清三个概念，任何实现和测试都不得混用：

1. **旧已发布 iOS 二进制**：继续使用它编译时固化的多域名合同。它不读取新版线路配置，
   也不是新版 App 的一个可选线路。
2. **新版产品区域 `AppRegion`**：决定中国/全球产品体验。中国体验默认引导微信读书、
   显示手机号登录并隐藏 Google 登录入口；Kindle、YouTube、Google Books、Kobo、
   O'Reilly 等书架平台连接，以及 Apple、邮箱登录仍全部保留。
3. **新版服务线路 `ServiceRoute`**：只有 `global` 和 `cn` 两个值。通用自有业务走线路
   网关；中国 QuickRead 使用同线路下单独备案的直连入口。它不改变 Apple、Google、COS
   或书架平台的第三方域名。

产品区域和服务线路独立，是为了覆盖以下四个测试组合：

| 产品体验 | 服务线路 | 用途 |
|---|---|---|
| 中国 | `global` | 验证中国 UI 在全球统一网关下可用 |
| 中国 | `cn` | 验证中国 UI 与备案网关完整链路 |
| 全球 | `global` | 新版全球基线回归 |
| 全球 | `cn` | 仅内部负向/隔离测试，不作为正式发布策略 |

## 2. 不可破坏的旧版合同

旧版基线以仓库快照 `e56d234`（1.2.22 build 36）为准：

| 旧版能力 | 固化合同 |
|---|---|
| 文档、STS、上传、TTS、音色目录 | `https://api.castreader.ai` |
| 账号、Pro、额度 | `https://castreader.ai` |
| QuickRead | 旧远程配置，兜底 `https://qr.castreader.ai` |
| TTS 节点 | 旧远程配置；大陆时区可直连旧 CN 节点并回退 `.ai` |
| 本地账号、device、session、额度键 | 旧无后缀键 |

服务端只能以**新增 route/path/table/column**的方式支持新版。不得删除、改义或强制重定向
上表中的旧路径；旧客户端也不得被后台线路开关影响。

特别注意上传兼容面：旧版 `GET /sts` 没有 Authorization 或 Build header，无法可靠识别
客户端版本。旧合同若恢复，必须保持原 wire contract，同时把临时凭证限制在随机独立前缀、
短 TTL、仅 `PutObject` 简单上传和 20 MB 对象上限（不签发 multipart 权限），并增加可信入口
IP 频控；长期 COS 主密钥
只能来自服务端环境变量，绝不能复制仓库历史中的硬编码凭据。新版改用独立的
`/api/mobile/upload/sts` + `cms_` 会话，不把匿名合同继续扩散到新架构。

## 3. 新版双网关合同

| 新版线路 | 通用 CastReader 自有业务入口 | QuickRead 入口 | 客户端跨线回退 |
|---|---|---|---|
| `global` | `https://api.castreader.ai` | `https://api.castreader.ai` | 禁止 |
| `cn` | `https://api.castreader.cn` | `https://quickread.castreader.cn` | 禁止 |

“通用自有业务”包括账号、手机号、mobile session、Pro/额度、Apple 交易同步、埋点、文档、
上传控制、TTS 和音色目录。QuickRead 仍只发送线路绑定的 `cms_` session，但 CN 文档内容
直接发往 `quickread.castreader.cn`，不得先到 `api.castreader.cn` 再转
`quickread.castreader.ai`/`qr.castreader.ai`。法务展示页可在 `castreader.com` 打开，但不得
携带网关 session 或业务请求体。

两网关可以连接不同应用进程和上游，但必须共享以下权威：

- canonical `user.id` 与手机号/Google/Apple/email identity；
- subscription、order、payment、Apple notification shadow；
- 唯一的 `originalTransactionId` ownership 与 Apple webhook；
- Pro 权益规则和同一份业务数据。

共享 canonical 权威不等于共享客户端登录态。`global` 与 `cn` 必须分别保存账号资料、
`cms_` session、provider token 和本地内容命名空间；任何一方的 bearer token 都不得发送到
另一方入口。用户首次切到另一条线路时登录该线路账号，切回后可恢复原线路已保存的会话。
即使两次登录最终解析为同一个 canonical `user.id`，本地历史、书架、Cookie 与缓存仍按
`ServiceRoute × canonical account` 隔离。

中国 QuickRead 公共入口必须验证 CN `cms_` 会话并使用显式、allowlist、非递归的私有 CN
origin；缺少配置时 503，绝不能回退 `.ai` QuickRead。其他中国网关业务若代理境外上游，
仍需单独验收数据驻留、隐私告知和数据跨境合规。

## 4. 线路选择、后台控制和 App 切换

新版解析优先级：

1. 内部启动参数 `-CastReaderServiceRoute global|cn`；
2. Debug 或显式签名的 Internal 测试包设置页本地覆盖；
3. 后台对 CHN 产品区域和目标 Build 发布的有效配置；
4. 安全默认 `global`。

规则：

- 启动参数和后台 payload 只接受严格的 `global|cn`；历史 Debug 缓存中的 `legacy` 仅可
  一次性迁移为 `global`，不得成为服务器公开值。
- 线路在进程启动时冻结。设置或后台刷新只改变“下次完整启动”，不得在登录、支付、上传、
  TTS、QuickRead 或 Safari job 中途热切。
- 后台发布 `cn` 必须同时限制最小和最大 Build；建议测试期两者等于唯一测试 Build。
- 404、超时、5xx、非法 JSON、未知 schema、非法 route、Build 不匹配和缓存过期均回到
  `global`。
- 后台开关只控制新版中国产品客户端；旧二进制和全球产品客户端不读取该结果。
- App Store 正式包隐藏并清除持久化测试开关；Debug 包默认显示。非 Debug 包只有在构建时
  显式开启 Internal 标志且运行于 sandbox receipt 环境时才显示，单凭 TestFlight/App Review
  的 sandbox receipt、启动参数、账号或历史缓存都不能开放。测试界面显示产品区域、服务线路、
  当前/下次启动线路、配置来源和四类实际 host。
- 控制面只返回枚举、Build 范围和缓存时间，不下发任意 URL、token 或 API key。

## 5. 身份、额度、QuickRead 与 Safari 边界

客户端按线路隔离以下本地状态，避免把一个入口签发的 token 发到另一个入口：

- 登录资料与 provider token；
- `cms_` mobile session；
- device/visitor id；
- 免费额度缓存；
- Analytics 待发队列和死信队列。

`global` 继续读历史本地键，保证升级不丢登录；`cn` 使用独立后缀。切线后允许要求用户重新
登录，但同一身份在服务端必须解析为完全相同的 canonical `user.id`。

新版 Pro v2、上传 STS 和 QuickRead 必须只信任线路绑定的 `cms_` 会话：

- 客户端提交的 `user_id`、email、device id 或 route 不能改变服务端身份；
- 服务端从请求的精确 public host 判定 `global|cn`，不信任客户端 route 或可伪造的
  forwarding header；未知 host 失败关闭；
- App、v2 status/listen 与 QuickRead 使用 canonical user + ingress route 的同一额度主体；
- QuickRead capability 只在 background/native 边界出现，数据库只存 SHA-256，绑定用户和
  ingress；跨用户、跨入口 continuation/asset 返回 404；
- 新 iOS Safari 的 `global` 和 `cn` 都从 native background 获取各自 session。token 不进入
  content script、页面世界、扩展 storage、URL 或日志；
- Chrome、Firefox、macOS Safari 和旧 iOS Safari 继续原有直连合同，不被新版 Safari 路径
  强制迁移。

## 6. 支付合同

- StoreKit 2 是 iOS 唯一购买通道，线路切换不改变产品 ID、订阅组或价格来源。
- Build 39+ 的 `appAccountToken` 只由 canonical `user.id` 派生，使用 UUIDv8，不能包含线路；
  同一账号切线前后必须完全一致。
- 两网关共享 Apple billing authority。相同 `originalTransactionId` 只能有一个 owner，不能
  因切线或伪造 user/device 转移。
- webhook 验签失败返回 400；Apple 暂不可用或验签后持久化失败返回 no-store 503，让 Apple
  重试；refund/revoke tombstone 不能被旧通知复活。
- 本机 StoreKit 权益、服务端 Pro、Safari 权益和额度解除必须同时一致。

历史 UUIDv4/nil `appAccountToken` 无法在设备端证明 CastReader 账号归属。当前兼容策略必须用
共享服务端 `originalTransactionId` 唯一约束兜底，并以“同一 Sandbox Apple ID + 两个
CastReader 账号”做 No-Go 测试；只看到本机 `isPro=true` 不算通过。

## 7. 自动化测试门（当前允许执行）

### A. 旧版不回归

- [x] 从 `e56d234` 提取 endpoint 快照并锁定，不把旧二进制映射为新版 `ServiceRoute`。
- [x] 旧 Google/Apple social body、mobile session DELETE、公开 Pro v1、TTS、文档和旧
  QuickRead 合同继续响应。
- [x] 旧 `/api/pro/status`、`/api/pro/listen-track`、`/api/auth/sign-in/social`、旧 Safari/
  Chrome/Firefox 代码无破坏性 diff。
- [x] 所有数据库迁移向前兼容；未运行迁移时旧服务仍可启动。

### B. 线路与网络

- [x] `ServiceRoute.allCases == [global, cn]`，未知/`legacy` 启动参数失败到 global。
- [x] 启动参数 > 本地覆盖 > 后台 > global；CHN/非 CHN、Build 窗口、TTL、损坏缓存矩阵齐全。
- [x] 当前进程冻结；修改设置后所有已初始化服务仍保持原 host。
- [x] 新 `global` 自有 endpoint 为 `api.castreader.ai`；新 `cn` 通用 endpoint 为
  `api.castreader.cn`，QuickRead 精确为 `quickread.castreader.cn`。
- [x] CN QuickRead 首次请求、401 同线路刷新、continuation 与资源 URL 均不触达
  `api.castreader.cn`、`api.castreader.ai`、`quickread.castreader.ai` 或
  `qr.castreader.ai`；私有 origin 缺失、未 allowlist 或指向公开入口时失败关闭。
- [x] 首个自有请求、HTTP redirect 和 response-provided URL 均不能跨网关；第三方书架、
  OAuth、COS/CDN 保持原行为。
- [x] 两路线 TTS 都无客户端 fallback；旧时区 TTS 配置不再参与新版。
- [x] Analytics 新事件只发 `global|cn`，ingest 仍可接收历史排队的 `legacy`/无 route 事件。

### C. 后台控制面

- [x] 公共配置缺失、损坏或 DB 失败时 200 + global；响应 no-store 且无 URL/secret。
- [x] 管理 GET/PUT 只接受独立 `MOBILE_ROUTING_ADMIN_SECRET`；错密钥、未配置或仅有
  `CRON_SECRET` 不能写。
- [x] PUT 带 expectedRevision；并发同 revision 仅一个成功，另一个 409。
- [x] `cn` 缺 Build 任一边界拒绝；global 可不限定 Build。
- [x] Pulse 密钥只保存在当前 tab 的 sessionStorage，不进 URL、localStorage 或日志。

### D. 账号、手机号、额度、支付与扩展

- [x] Google、Apple、email 与 phone 在两入口得到相同 canonical `user.id`。
- [ ] 手机号并发首次验证只创建一个 user/identity；验证码只能消费一次；删除账号立即吊销
  全部 session/device link。
- [x] v2 status/listen、QuickRead、Safari capability 的伪造身份、轮换 device、跨入口和跨用户
  测试全部失败关闭。
- [x] Apple ownership、webhook retry、refund/revoke/reversal、周期推进和错误回滚测试通过。
- [x] 新 `/api/mobile/upload/sts` 无 session 为 401，route/session 不匹配失败，策略前缀和权限
  最小化；旧 `/sts` 单独做兼容与限流测试。
- [x] Kindle、微信读书、Google Books、Kobo、O'Reilly、YouTube 全部仍在中国体验可连接，
  仅微信读书排序/默认引导改变。
- [x] 账号注销向用户准确显示处理时限；Google/Apple/email/phone 均能发起。Sign in with
  Apple 删除流程保存并撤销 Apple 授权凭据，不只删除 CastReader 本地 session。

### 本轮本地执行记录（2026-08-14）

以下结果只证明代码、构建产物和本地合同门禁，不替代第 9 节的真实环境测试：

- CN QuickRead 独立入口增量门禁：iOS 路由/区域/endpoint 聚焦测试 62/62；其中最终
  ServiceRouting 复跑 46/46。readout-web host/session/private-origin 合同 27/27，TypeScript
  严格检查通过；Safari 发布门禁 140/140、Chrome 一致性 257/257。以上均为 mock/本地产物，
  尚未证明 `quickread.castreader.cn` 的真实 DNS/TLS、SSE 和完整认证转发链路。
- 独立 Nginx vhost 与发布回滚门禁 7/7：`quickread.castreader.cn` 有自己的 ACME/443 配置，
  只开放 `/api/quickread/`，保留 public Host、覆盖伪造 X-Forwarded-For、关闭请求/响应缓冲与
  capability access log；部署激活必须观察到未登录请求在该 host 返回 401，否则自动回滚。
- DeepSeek 官方 API 隔离 A/B：`gemini-3.5-flash` 与 `deepseek-v4-flash` 使用完全相同的
  生产 plan prompt、温度 0.7、8K 输出上限、关闭思考且无 fallback；5 份公开/合成材料
  （4 中文场景 + 1 英文论文）各重复 3 次。两者请求均 15/15 成功；原始首轮 JSON 可解析率
  分别为 86.7% / 100%，完整 plan 结构率均为 86.7%；平均 TTFT 为 1.196s / 1.067s，平均
  完整 JSON 为 2.752s / 3.101s。DeepSeek 两次“合法 JSON 但结构不完整”已推动新增 plan
  语义门禁：总块数、块序号及正文/skip 段落必须恰好覆盖一次，否则只对同一线路模型重试。
  这组小样本只说明纯文本没有观察到明显质量断层，不构成真实 CN E2E 或多模态等价证明。

- iOS 全量单元测试：853 项，847 通过、6 项按环境条件跳过、0 失败；其中双线路、线路冻结、
  401 同线路刷新、账号/额度、StoreKit ownership 和书架排序均已覆盖。
- iOS 核心 UI：最终 6 个场景全部通过，包括设置页中国/全球产品区与 `global`/`cn` 线路、
  中国手机号入口、StoreKit 付费页、微信读书默认引导，以及 Kindle、微信读书、Google Books、
  Kobo、O'Reilly、YouTube 均保留。
- iOS Release 模拟器构建成功；正式分发产物内测试开关为 `NO`，可安装并启动。Debug/Internal
  测试设置与 Release 隐藏策略分别验证。
- 新后端全量单元/契约测试：276 项，274 通过、2 项隔离 PostgreSQL 并发测试按环境条件跳过、
  0 失败；另外旧版 `e56d234` 兼容合同专项 116/116 通过。
- 手工迁移套件已在隔离 PostgreSQL 17.11 实际回放：新库全套连续两次、legacy 0014/0015 后
  再跑全套两次均成功；畸形 phone 表按预期失败关闭，最终核对 11 张必需表。该结果不替代
  目标 staging 的备份、迁移与回滚演练。
- 新后端 TypeScript 严格类型检查和 Next.js 生产构建均成功。构建仅有依赖版本与 chunk 大小
  提示，没有编译错误。
- iOS Safari 双线路合同、Pro/额度/会话刷新合同均通过；Safari 发布门禁 140/140、Safari 与
  Chrome 产物一致性门禁 257/257 通过。iOS 产物不包含 QuickRead API key 或旧直连路径。
- 三个工作区 `git diff --check` 通过；本轮没有 commit、push、部署、迁移真实数据库、修改 DNS、
  上传 TestFlight 或提交 App Store。

尚未通过、因此继续保持 **No-Go**：真实短信、真实 Apple Sandbox 购买/恢复/退款、真实 CN
网关全链路（含 `quickread.castreader.cn` → allowlist 私有 CN origin → DeepSeek）、隔离 staging
迁移与回滚、线上旧二进制抓包并行回归，以及备案接入控制台核查。

## 8. 本地与模拟器人工测试门（当前允许执行）

先使用 mock/本地后端，不发送真实短信、不写生产数据库：

1. Debug 包分别以“中国+global”“中国+cn”“全球+global”冷启动。
2. 在设置页切线，确认当前 host 不变、下次启动 host 全量切换。
3. 中国首启默认微信读书；所有其他书架和 YouTube 入口仍可见。
4. 用本地预设短信码只走 UI 测试模式；Release/TestFlight 中该兜底必须关闭。
5. 拍照 OCR、PDF/EPUB/DOCX/文本全部走端上解析并完成朗读/解读界面流程。
6. 用 URLProtocol/假后端覆盖登录、401 refresh、SSE、超时、5xx、断网和跨 host redirect。
7. 用 StoreKit Configuration 覆盖月/年购买、pending、取消、恢复、过期和退款 UI 状态。

这一步只能证明客户端和合同正确，不能证明真实短信、真实 Apple Sandbox 或备案网关可用。

## 9. 需要再次授权的真实环境测试门

在用户明确授权前，不执行以下任何动作：部署后端、运行生产迁移、修改 DNS/Nginx/证书、
上传 TestFlight、提交 App Store。

真实 E2E 至少需要一个隔离测试窗口，只部署**新增路径和向前兼容迁移**，后台初始值保持
`global`，CN 仅允许唯一测试 Build。随后在中国网络真机测试：

- 两路线手机号真实短信、登录/退出/重启恢复和账号删除；
- TTS 首段/连续播放/弱网/前后台，QuickRead plan/extract/compose/SSE/asset；
- 新认证 STS、上传通知、文档列表；
- iOS Safari page/cinematic 全流程与 App 共用额度；
- 至少两个 Sandbox Apple ID：global 购买切 cn 恢复、cn 购买切 global 恢复、手机号购买、
  pending/取消/退款/过期/grace/换机；
- 当前线上旧版同时做登录、Pro、TTS、文档和 QuickRead 回归，抓包证明它没有访问 `.cn`。
- App Store Connect 主分类保持 Education、次分类 Productivity；简体中文备案元数据与
  `沪ICP备14008512号-12A` 完全一致。审核说明明确 CastReader 是用户输入驱动的 TTS/
  辅助阅读工具，不运营图书或期刊内容目录；如 Apple/主管部门仍要求专项许可，先取得书面
  结论，不以分类名称自行推定豁免。

测试通过后，仍需用户再次明确授权正式部署和 App Store 提交。

## 10. 当前环境事实与阻断（2026-08-14）

只读探测确认：

- `api.castreader.cn` 已解析到 `106.54.47.163`，TLS 有效；本轮没有改 DNS。
- 旧账号、Pro status、TTS、文档列表和 `qr.castreader.ai` 仍有符合预期的 HTTP 合同响应，
  且对应旧 route 文件没有本轮破坏性修改。
- `api.castreader.ai` 与 `api.castreader.cn` 的文档列表和 TTS 已能响应。
- 两域 `/sts` 均为 404；`/async-md-upload-by-url` 均为 404；POST `/upload` 命中网页 HTML，
  不是 reader API。这是现存上传网关迁移缺口，不能算通过。
- 新 runtime-config、Pro v2、global authenticated QuickRead、phone/mobile-auth 等新增合同尚未在
  两个真实入口完整可用；在“不部署”的约束下只能做本地和 mock 验证。
- 当前 readout-web 没有可直接复用的 COS STS 环境配置；旧 reader-service 源码中的硬编码
  长期凭据不得复制。必须在后续获批部署前创建/轮换最小权限凭据并显式配置。

因此当前交付目标是“代码、自动化、模拟器和部署前门禁就绪”，不是宣称中国线路已经完成
真实 E2E。上述任一真实入口缺口未关闭时均为 No-Go。

## 11. 备案 IP 核查

备案材料 IP `49.234.54.42` 与 `api.castreader.cn` 当前 IP `106.54.47.163` 都属于腾讯云中国
网络，但“同一主体”本身不能替代接入核查。腾讯云说明，非经营性服务在腾讯云内更换腾讯云
IP 通常无需重新备案；专项核查仍可能提示解析 IP 与备案接入信息不一致，并要求整改或变更。

正式开放前必须在腾讯云备案控制台确认该域名接入状态正常并保存截图；如控制台要求变更、
涉及经营性备案或实际接入商变化，应先完成对应手续。

官方参考：

- <https://cloud.tencent.com/document/faq/243/19617>
- <https://cloud.tencent.com/document/product/243/76768>

## 12. 最终 Go / No-Go

只有以下条件全部满足才允许正式部署或送审：

- 自动化无失败；跳过项都有真机等价记录。
- 旧版、新 global、新 cn 三套抓包和功能矩阵通过。
- 真实短信、真实上传、QuickRead、Safari、Apple Sandbox 支付/恢复/退款通过。
- 两入口 canonical user、billing-authority fingerprint、Apple ownership 与业务数据一致。
- 后台默认/一键回退均为 global，CN 只命中获批 Build。
- 日志不含短信码、手机号、Bearer、QuickRead capability、Apple JWS、管理密钥或长期凭据。
- 备案接入核查正常。
- 用户明确确认测试通过，并分别授权正式部署和 App Store 提交。
