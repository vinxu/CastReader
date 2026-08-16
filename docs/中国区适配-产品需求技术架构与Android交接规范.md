# CastReader 中国区适配：产品需求、技术架构与 Android 交接规范

> 文档状态：**当前唯一权威规范（SSOT）**
>
> 基线日期：2026-08-14
>
> 适用范围：iOS、Android、CastReader 中国/全球网关、QuickRead、TTS、账号、短信、支付、文档与上传、书架平台、合规与发布
>
> iOS 发布候选：**1.2.24 (Build 39)**，代码基线 `2ecb07d`
>
> 后端发布候选：`6a275aa6` + `3f71b023`
>
> 当前执行状态：iOS/后端候选代码已提交；全球与中国双域名部署、探针与打包前验收正在进行。runtime 仍保持 `global`，**尚未最终将中国线路限定开给 Build 39**。Android 本轮仅作详细交接，不执行改造。

## 0. 文档用途与解释优先级

本文档把中国区适配中已经确认的产品决策、iOS 当前实现、后端真实状态、Android 后续必须遵守的技术合同、测试和发布门禁统一到一处。后续 Android 设计、开发、测试和验收均以本文档为起点，不再从聊天记录或旧方案中拼接需求。

出现冲突时，解释优先级如下：

1. 用户最新明确确认的产品要求；
2. 本文档中的“规范性要求”；
3. 当前 iOS 已验证行为与后端公开合同；
4. 其他历史文档；
5. 历史代码注释。

本文使用以下状态，不能混写：

| 状态 | 含义 |
|---|---|
| **目标规范** | iOS、Android 和服务端最终都必须满足 |
| **iOS 已实现** | iOS 发布候选提交 `2ecb07d` 已有相应实现，不代表已正式发布 |
| **后端候选已提交** | 能力已进入 `6a275aa6` / `3f71b023`，仍需区分“已提交”、“已部署”和“双域已验收” |
| **真实环境已验证** | 已通过真机或公开入口验证，仍可能未正式灰度 |
| **部署中** | 发布候选正在真实环境激活/探针，在通过前不得把候选状态写成已上线 |
| **待完成 / No-Go** | 未完成前不得宣称对应的发布范围已验收；不在 Build 39 范围内的 Android/网盘能力按各自后续门禁管理 |

## 1. 最终产品目标

中国区适配按以下四项优先级执行，顺序不可倒置：

1. **可在中国大陆 App Store / Android 应用市场合法提交并稳定运行。**
2. **中国区提供手机号登录。**
3. **支付、恢复权益和跨端 Pro 状态必须正确。**
4. **除默认引导改为微信读书外，保留现有全部内容入口和书架平台。**

对应的非目标：

- 不把 CastReader 改成图书内容商店。CastReader 仍是用户输入驱动的 TTS / 辅助阅读工具。
- 不因为中国区适配移除 Kindle、Google Play 图书、Kobo、O’Reilly 或 YouTube。
- 不让客户端直接持有 DeepSeek、QuickRead、腾讯云短信或支付商户密钥。
- 不让中国线路故障时由客户端把正文、token 或支付请求自动回退到全球线路。
- 不用一次热切换同时改变产品 UI、登录账号和业务网关。
- 不破坏线上旧版本仍在使用的接口。

### 1.1 原始需求追踪

| 已确认需求 | 本文落点 |
|---|---|
| 中国大陆可上架、备案信息一致 | 第 14、20 节 |
| 增加手机号登录 | 第 6、7、8 节 |
| 支付和跨端 Pro 不出问题 | 第 12、19、20 节 |
| 保留全部书架/YouTube，仅默认微信读书 | 第 3、13 节 |
| `api.castreader.cn` 与 `api.castreader.ai` 并存 | 第 2、4、5 节 |
| 旧线上版本不受新网络架构影响 | 第 5、19、20 节 |
| App/后台可在测试期选择线路，冷启动生效 | 第 4.3、8.6、17.3 节 |
| 中国 QuickRead 直连 `quickread.castreader.cn` | 第 4、9 节 |
| 中国生产模型用 `deepseek-v4-pro` | 第 9.5 节 |
| block0/首个正式块/TTS 不重复 | 第 9.4、19 节 |
| 中国区隐藏 Google 和邮箱，iOS 保留手机 + Apple | 第 3.1、6 节 |
| 协议单句、链接可点、同意后继续原登录动作 | 第 6.2、17.7 节 |
| 中国区九语本地化 | 第 3.3、19.2 节 |
| 后续 Android 按同一框架适配 | 第 16–19 节 |

## 2. 三个必须分离的状态

中国区架构的核心不是“换一个域名”，而是把三个不同问题明确拆开。

### 2.1 发行区域 `DistributionRegion / AppRegion`

回答“用户看到哪套产品、适用哪套登录和合规规则”。

- iOS：以 App Store storefront 为权威；`CHN` 为中国大陆，`HKG/TWN/MAC` 仍属于全球体验。
- Android：以独立 `cn/global` product flavor、安装渠道或签名发行元数据为权威。
- IP、时区、SIM、当前网络能否访问 Google、当前请求域名都不能成为永久发行区域。
- UI 语言独立于发行区域。中国区可以使用英文、日文等界面；全球区也可以使用简体中文。

### 2.2 服务线路 `ServiceRoute`

回答“CastReader 自有业务进入哪个网关”。

| 路线 | 通用 API / Web / TTS | QuickRead |
|---|---|---|
| `global` | `https://api.castreader.ai` | `https://api.castreader.ai` |
| `cn` | `https://api.castreader.cn` | `https://quickread.castreader.cn` |

服务线路只影响 CastReader 自有业务。Apple、Google、微信读书、Kindle、Kobo、O’Reilly、YouTube、COS 等第三方域名不由 `ServiceRoute` 改写。

### 2.3 账号内容域 `AccountContentScope`

回答“这份本地历史、书架、Cookie、缓存和播放状态属于谁”。

目标主键的精确生成合同：

~~~text
identity = "backend:<canonicalId>"
scopeID  = SHA-256("<route>|<identity>")
~~~

后端 canonical user 尚未取得时，可以临时使用：

~~~text
identity = "provider:<provider>:<providerUserId>"
scopeID  = SHA-256("<route>|<identity>")
~~~

`backend:` / `provider:` 前缀是防止不同命名空间碰撞的合同，不能省略。`SHA-256("<route>|<raw-id>")` 是不合格实现：即使当前数据中的 id 恰好不冲突，也丧失了命名空间证明。取得 canonical user 后必须通过 alias 迁移到稳定 scope，不能让同一账号因为 provider 换绑而出现两份历史；alias 的 key 和 value 也都只能保存上述 SHA-256 opaque id，不保存 raw canonical id、provider user id、手机号或 email。

### 2.4 三者不能互相推导

允许的内部测试组合：

| 产品区域 | 服务线路 | 用途 |
|---|---|---|
| 中国 | `global` | 中国 UI + 旧/全球网关的回归基线 |
| 中国 | `cn` | 中国 UI + 备案网关完整验收 |
| 全球 | `global` | 正式全球基线 |
| 全球 | `cn` | 仅内部隔离/负向测试，不是发布策略 |

从 `global` 切到 `cn` 不代表同一个本地登录态继续有效。目标线路只有在持有该线路有效 `cms_` session 时才能恢复账号，否则必须显示登录墙。切回原线路时可恢复原线路保存的账号和数据。

## 3. 产品能力矩阵

### 3.1 登录渠道

| 平台与区域 | 主入口 | 次入口 | 明确隐藏 |
|---|---|---|---|
| iOS 全球 | Google 全宽按钮 | Apple、邮箱小图标 | 手机号 |
| iOS 中国 | 手机号全宽按钮 | Apple 小图标 | Google、邮箱 |
| Android 全球 | Google；邮箱为兜底 | 由全球版现有产品决定 | 手机号 |
| Android 中国首期 | 手机号全宽按钮 | 暂无 | Google、邮箱 |

说明：

- “Apple 小图标”是 iOS 当前明确的产品规则，Apple 与邮箱使用相同尺寸层级，不能把 Apple 单独做成第二个全宽主按钮；仍须使用合规 Apple 标志、至少 44×44pt 点击区和完整无障碍标签。
- Android 原生没有等价的 AuthenticationServices。若后续要求 Android 用户登录其 iOS Apple 账号，应另立 Sign in with Apple Web OAuth / Apple JS 合同并接入同一 canonical user；在该方案完成前不得显示一个无法完成的 Apple 入口。
- 中国区邮件登录已明确取消。不能只隐藏 UI 而保留可由深链或旧状态触发的邮件动作；执行层也必须做区域 guard。

### 3.2 书架、内容入口与默认值

两区都保留：

1. Kindle
2. 微信读书
3. Google Play 图书
4. Kobo
5. O’Reilly
6. YouTube
7. PDF、EPUB、DOCX、文本、网页、拍照 OCR 等本地/用户输入入口

区域差异仅为：

- 全球首启/无选择默认：Kindle。
- 中国首启/无选择默认：微信读书。
- 中国区书架来源顺序：微信读书置前，其余平台继续保留。
- 用户已经显式选择过且仍可用的来源，不得因区域或线路切换被强制覆盖。
- “默认微信读书”不等于重排整个首页 rail；现有首页其它模块保持不变。

### 3.3 本地化

产品区与语言独立。iOS 和 Android 的目标语言集合统一为：

- English
- 简体中文
- 日本語
- Español
- Français
- Deutsch
- Português (Brasil)
- Italiano
- हिन्दी

中国区新增的登录、协议、手机号、错误、微信读书引导、支付和退款/取消文案必须覆盖九种语言。不能让非中英文用户继承 Google Play、自动续费或英文占位文案。

iOS Build 39 已实现上述 **9 种正式 App 语言**的资源和中国登录关键 key；这是“已实现/静态审计通过”，不等于九语中国区真机矩阵已全部验证。当前不得把已有简体中文真机证据外推为九语验收完成。

“9 种 App UI 语言”与“App Store Connect 版本元数据 locale”不是同一计数：1.2.24 商店侧使用 11 个 locale（包含商店地区化变体），不能把商店 locale 数量当作 App 内真机语言覆盖证据。

## 4. 网络架构

### 4.1 目标拓扑

~~~text
                                      ┌─────────────────────────────┐
                                      │ canonical user / billing DB │
                                      │ 统一账号、订单、订阅与权益    │
                                      └──────────────┬──────────────┘
                                                     │
               ┌─────────────────────────────────────┴──────────────────────────────┐
               │                                                                    │
     global process                                                          cn process
               │                                                                    │
      api.castreader.ai                                                   api.castreader.cn
       ├─ mobile auth                                                      ├─ mobile auth / SMS
       ├─ Pro / quota                                                      ├─ Pro / quota / Alipay
       ├─ documents / upload（旧版兼容/后续云能力）                         ├─ documents / upload（旧版兼容/后续云能力）
       ├─ TTS / voice catalog                                              ├─ TTS / voice catalog
       ├─ events                                                           └─ events
       └─ QuickRead
                                                                             │
                                                            quickread.castreader.cn
                                                             └─ authenticated CN ingress
                                                                 └─ private allowlisted CN origin
                                                                     └─ DeepSeek
~~~

**Build 39 的实际文档数据路径不是上传链路：**

~~~text
拍照 / 系统文件选择器
  → iOS 本地 OCR / PDF / EPUB / DOCX / Text / Image 解析
  → ReadingDocument
  → 当前 route 的 TTS / QuickRead
~~~

Build 39 用户可达入口不请求 `/api/mobile/documents`、`/api/mobile/upload/sts`、`/api/mobile/upload/notify`，也不回退旧 `/documents`、`/sts`、`/upload` 或 `/async-md-upload-by-url`。因此上图中 documents/upload 是旧版兼容和后续网盘/云同步的目标面，不是本次 iOS 包的运行依赖。

### 4.2 新客户端端点合同

| 能力 | 路径 | 鉴权 |
|---|---|---|
| runtime config | `GET /api/mobile/runtime-config/v1` | 无；只返回枚举和版本窗口 |
| mobile session | `POST /api/mobile-auth/session` | provider credential → `cms_` |
| session revoke | `DELETE /api/mobile-auth/session` | Bearer `cms_` |
| 短信发送 | `POST /api/mobile-auth/sms/send` | 无 session；服务端频控 |
| 短信验证 | `POST /api/mobile-auth/sms/verify` | 验证码成功后返回 `cms_` |
| 账号注销 | `POST /api/mobile-auth/account/delete` | Bearer `cms_` |
| Pro 状态 | `GET /api/mobile/pro/status/v2` | Bearer `cms_` |
| 朗读用量 | `POST /api/mobile/pro/listen-track/v2` | Bearer `cms_` |
| Apple 交易同步 | `POST /api/pro/verify-apple` | Bearer `cms_` + 服务端验签 |
| 文档列表 | `GET /api/mobile/documents` | Bearer `cms_` |
| 上传凭证 | `GET /api/mobile/upload/sts` | Bearer `cms_` |
| 上传完成通知 | `POST /api/mobile/upload/notify` | Bearer `cms_` |
| TTS | `POST /api/captioned_speech_partly` | **现状公开、无 `cms_` 硬鉴权；目标新客户端为 Bearer `cms_` + 服务端原子额度** |
| 音色目录 | `GET /api/tts/catalog?contract=tts-voice-catalog-v1` | 当前线路 |
| QuickRead | `/api/quickread/extract-plan` 等 | Bearer `cms_` |
| 埋点 | `POST /api/events` | 当前线路；不含敏感正文 |

客户端不得继续把 `user_id`、email、device id 当作 v2 判权依据。服务端身份必须来自经验证的 `cms_` principal。为兼容诊断而保留的字段也必须被服务端忽略，不能改变账号、Pro 或额度主体。

表中 documents/upload 是后续云能力的规范性合同；不能由此推导它们已进入 Build 39 或已随后端提交 `6a275aa6` 部署。

### 4.3 线路解析与冷启动冻结

目标优先级：

1. 内部启动参数；
2. Debug 或显式签名 Internal 包的本地覆盖；
3. 权威中国发行区域可读取的后台灰度配置；
4. 安全默认 `global`。

规则：

- route 只接受 `global|cn`。
- 缺失、超时、损坏、未知 schema、非法 route、缓存过期或版本不在窗口内时，下一次启动使用 `global`。
- 启用 `cn` 必须同时指定最小和最大 build/versionCode。
- `cacheSeconds` 是必填整数；字段缺失或类型不可解析时整份配置无效、清除不可用缓存并 fail closed 到 `global`。只有成功解码的整数才 clamp 到 **300 秒～604800 秒（5 分钟～7 天）**；低于/高于边界分别按边界处理。Android 必须与 iOS 使用同一合同，并覆盖缺失、错误类型、299/300/604800/604801 的测试。
- 不得将“缺少 `cacheSeconds`”解释为使用默认 TTL；这种响应不能写入新缓存，也不能继续信任一份已过期的 CN 缓存。
- 当前进程 route 一旦冻结不可改变。设置或后台刷新只写入“下次完整启动”。
- 登录、支付、上传、TTS、QuickRead、文档同步过程中禁止热切线路。
- 正式 Release 必须隐藏并忽略历史 Debug/Internal 覆盖；账号、手机号或审核账号不能授权测试开关。

当前后台 v1 仅有 iOS 字段。Android 接入时应采用**向后兼容的增量字段**，不能改坏 iOS：

~~~json
{
  "schemaVersion": 1,
  "iosChinaServiceRoute": "global",
  "minimumBuild": null,
  "maximumBuild": null,
  "androidChinaServiceRoute": "global",
  "minimumVersionCode": null,
  "maximumVersionCode": null,
  "cacheSeconds": 604800
}
~~~

现有 iOS 会忽略 Android 新字段。Android 只读取 Android 字段；不能复用 iOS build 窗口。

### 4.4 重定向和动态 URL 边界

对携带 bearer 或正文的 CastReader 自有请求：

- 只允许 HTTPS。
- 只允许 443/无显式非标准端口。
- 只允许停留在当前 route 的精确 host。
- `.ai ↔ .cn` 跨 host 重定向必须拒绝。
- 中国 QuickRead 只允许 `quickread.castreader.cn/api/quickread/*`。
- **CN TTS 必须遵守唯一、精确的 URL allowlist：**生成请求只能是 `POST https://api.castreader.cn/api/captioned_speech_partly`；音色目录和服务端返回的 TTS 资产 URL 只能位于标准 HTTPS 的精确 host `api.castreader.cn` 且 path 以 `/api/tts/` 开头。这两类路径不得扩张为任意 `/api/*`。
- response-provided owned URL 默认失败关闭。当前 iOS 唯一中国区兼容改写是：仅将标准 HTTPS、精确 host 为 `api.castreader.ai`、path 以 `/api/tts/` 开头的响应 URL **保留 path/query** 改写为 `https://api.castreader.cn/api/tts/*`；它必须与 CN Nginx 的 `/api/tts/` allowlist 同步。不得泛化为任意 `.ai → .cn`、其它 path、其它 scheme/port 或 QuickRead URL 的改写。
- 第三方公开资源 URL 保持原样，但不得附带 CastReader bearer。
- OkHttp/URLSession 都要显式验证最终 URL，不能依赖库的默认“会移除 Authorization”作为全部安全边界。

### 4.5 客户端禁止跨线回退

- 中国 TTS 失败时，只能在 `api.castreader.cn` 内做有限重试；不能改写到 `api.castreader.ai`。
- 中国 QuickRead 失败时，只能在 `quickread.castreader.cn` 内重试；不能转到任何 `.ai` QuickRead。
- 上游容灾可以由网关在服务端完成，但必须经过数据跨境、隐私和备案评估，并对客户端保持同一公共 host。
- DNS、超时、5xx 不是登出依据，也不是跨线依据。

## 5. 旧版本并存与迁移原则

新架构上线时，旧 iOS/Android 仍会在一段时间内使用历史端点。服务端必须采取“新增而不破坏”策略。

### 5.1 不可破坏的旧合同

- 不删除旧 `/sts`、旧文档、旧上传、旧 Pro v1、旧 social sign-in、旧 TTS 和旧 QuickRead 合同，直到线上版本占比和抓包证明可以退役。
- 不把旧请求强制 301/302 到新 host。
- 不修改旧响应字段含义来迁就新客户端。
- 数据库迁移必须向前兼容；新表/新列/新唯一约束要经过 legacy 数据审计。
- 新后台 route 开关只影响显式读取它的新版本。

### 5.2 新客户端迁移

1. 安装升级后先保留全球历史 key，避免全球用户被无故登出。
2. 中国线路使用独立 route key。
3. Build 39 的新合同范围是 route-local mobile auth/session、Pro v2、StoreKit 验证与 QuickRead；用户文件仍端上解析，不改用 mobile documents/upload。
4. 先部署并验证服务端新增合同，再让受限 build 读取 `cn`。
5. 旧、新 global、新 cn 三套客户端并行抓包回归。
6. 任何回滚只把下一启动 route 设回 `global`，不得删除用户另一线路的本地数据。

## 6. 登录墙与隐私协议

### 6.1 根登录墙

- 没有“当前 route 有效账号资料 + 当前 route 有效 `cms_` session”时，只显示登录墙。
- 不能只凭本地 account profile 放行；这正是“手机号登录后看到上一个账号内容”类严重串号问题的根源之一。
- 权威发行区域必须在渲染登录渠道前确定。iOS Build 39 由 `AppStartupCoordinator` 先准备 storefront，再冻结 route 并创建依赖 route 的单例/根 UI；Android 必须保留这个启动 gate，不得先渲染错误渠道后再热切。
- 登录成功前不创建会读取旧账号内容的主页面。

### 6.2 中国区协议 UI

目标样式：

- checkbox 与整句文案组成一个整体，水平居中。
- checkbox 与文案垂直居中对齐。
- 只保留一行/一个自然换行段落，不在底部重复放“服务条款”“隐私政策”两个按钮。
- “服务条款”“隐私政策”在同一句 `AttributedString/AnnotatedString` 内有颜色、下划线且分别可点击。
- 默认未勾选。

目标状态机：

~~~text
idle(hasAgreed=false)
  └─ 点登录方式 A
       └─ pendingAction=A + 显示协议弹框
            ├─ 不同意：pendingAction=nil，不登录
            └─ 同意：hasAgreed=true，取出 A，只执行一次 A
~~~

补充规则：

- 用户手动取消勾选后，下一次登录必须重新提示。
- 同意后执行的是“刚才点击的入口”，不能默认改成手机号或 Apple。
- sheet 内仍要有防御性检查，避免外层状态被绕过。
- Global 不要求这套显式勾选 gate，但法务链接仍须可访问。

当前 iOS 的 consent 仅为内存状态，没有协议版本、时间戳或服务端回执。正式合规设计应补充：

~~~text
consentVersion, acceptedAt, locale, distributionRegion, authChannel,
opaqueDeviceId, canonicalUserId(登录成功后补写)
~~~

是否必须持久化/服务端审计由法务最终确认；Android 设计时必须预留版本化接口，不能把“一个 Boolean”写死成永久合同。

### 6.3 法务链接

- 服务条款和隐私政策是内容站链接，不属于业务网关 route。
- 当前指向 `castreader.com`；中文界面使用 `/zh/...`，其它语言使用英文页。
- 打开法务页时不得附带 `cms_`、手机号、正文、邮箱或其它身份参数。
- 必须在中国大陆真实网络验证 DNS、TLS、首屏和完整正文可达。
- 如果九语没有独立法务文本，UI 应明确落到可用的中/英文正式版本，不能产生 404。

## 7. 手机号登录与腾讯云短信

### 7.1 客户端输入合同

- 仅中国发行区域展示。
- 当前只支持中国大陆 `+86`。
- 允许用户输入空格、短横线、`+86`、`0086` 或 `86` 前缀，发送前统一为 E.164。
- 本地号必须为 11 位，首位 `1`，第二位 `3-9`。
- 验证码为 6 位数字，输入时过滤其它字符并截断。
- 验证码输入框从页面初次出现就可见，不能等“发送成功”后才显示。
- 发送失败或被限流不能抹掉用户已经收到且尚未过期的验证码，也不能禁用验证入口。
- 原始手机号只允许在当前登录表单内存和 HTTPS 请求体中短暂存在，禁止写入 UserDefaults/DataStore、账号 profile、文件缓存、日志、埋点或崩溃报告。`UserAccount`/Android account model 只保存服务端返回或客户端生成的掩码，例如 `139****1416`。
- `textContentType/.oneTimeCode` 或 Android SMS autofill 只作为体验增强，不改变验证合同。

### 7.2 API 合同

发送：

~~~http
POST /api/mobile-auth/sms/send
Content-Type: application/json

{
  "phone": "+8613xxxxxxxxx",
  "scene": "sign_in",
  "deviceId": "<route-scoped opaque id>"
}
~~~

成功：

~~~json
{
  "code": 0,
  "data": {
    "ttl": 300,
    "resendAfter": 60
  }
}
~~~

验证：

~~~http
POST /api/mobile-auth/sms/verify
Content-Type: application/json

{
  "phone": "+8613xxxxxxxxx",
  "code": "123456",
  "deviceId": "<route-scoped opaque id>"
}
~~~

成功：

~~~json
{
  "code": 0,
  "data": {
    "sessionToken": "cms_...",
    "userId": "<canonical user id>",
    "isNewUser": false,
    "displayName": "139****1416",
    "expiresAt": "<ISO-8601>"
  }
}
~~~

### 7.3 错误语义

| 语义 | 客户端行为 |
|---|---|
| `invalid_phone` | 保留页面，提示手机号格式 |
| `invalid_code` | 保留手机号和验证码输入 |
| `code_expired` | 提示重新获取；输入框继续可见 |
| `rate_limited` + `retryAfter` | 使用服务端秒数倒计时，不自行写死 60 秒 |
| `sms_unavailable` | 明确服务暂不可用，不伪造“已发送” |
| 网络/超时 | 不登出其它账号，不启用生产直通码 |
| 401 + `INVALID_SESSION` / `SESSION_EXPIRED` | 按第 8.2 节只处理当前 route session |
| 409 + `account_pending_deletion`（手机号）/ `ACCOUNT_PENDING_DELETION`（session exchange） | 账号正在注销；保留明确状态并阻止登录，展示处理时限；不得当作 401 清 session 或自动重试 |

### 7.4 服务端短信安全

当前腾讯云配置基线（不是密钥）：

| 项目 | 值 |
|---|---|
| SMS SDKAppID | `1401172963` |
| 验证码模板 ID | `2397344` |
| 已确认签名内容 | `上海包子信息科技` |
| 模板参数 | `{1} = code` |
| 默认 region | `ap-guangzhou` |

服务端环境变量：

- `TENCENT_SMS_SECRET_ID`
- `TENCENT_SMS_SECRET_KEY`
- `TENCENT_SMS_SDK_APP_ID`
- `TENCENT_SMS_SIGN_NAME`
- `TENCENT_SMS_TEMPLATE_ID`
- `TENCENT_SMS_TEMPLATE_PARAMS=code`
- `TENCENT_SMS_REGION`
- `PHONE_AUTH_SMS_LIVE`
- `PHONE_AUTH_CODE_SECRET`

安全要求：

- Secret 只存在服务端 secret manager/systemd environment，不进 App、仓库、文档和日志。
- 6 位码使用 CSPRNG。
- 数据库只存手机号和验证码的 HMAC/哈希，不存明文验证码。
- 同手机号 + scene 同时只允许一个有效 challenge。
- 成功消费必须原子、只能一次；最大尝试次数 5。
- 参考现有限制：手机号每小时 5 次、IP 每小时 20 次、TTL 300 秒、重发 60 秒；最终数值由风控配置管理。
- 腾讯云 HTTP 200 不等于发送成功，必须检查 `SendStatusSet[].Code == "Ok"`。
- 新 challenge 必须在腾讯云确认发送成功后才提交为当前有效 challenge；也可以事务性暂存并在失败时恢复旧 challenge。任何发送失败都不能覆盖仍有效的旧验证码。
- 不记录手机号、验证码、腾讯云原始 Message、请求签名或 Secret。
- 审核直通号只能是服务端精确白名单，并且仍须先创建一次性 challenge；正式客户端绝不能包含通用 `888888`。

### 7.5 当前关键结论

- iOS 真机已经收到真实短信。
- 后端候选提交 `6a275aa6` 已把 `/sms/send` 改为“腾讯云确认发送成功后才持久化新 challenge”；provider 失败保留旧 challenge，并已有发送路由测试。这项实现缺口已关闭，但仍须在双域候选部署后做真实环境发送/故障探针，不得把“代码已修复”写成“生产已验收”。
- Android 当前 release 可走 `888888` / `cms_local_` 的实现属于 **P0 No-Go**；后续适配必须删除或严格限制为 Debug 编译期测试，Release 产物和测试都要反向证明其不存在。
- 用户曾通过聊天渠道提供过 DeepSeek secret。生产前应把该 secret 视为已暴露并轮换；本文档不记录其值。

## 8. Session、账号和本地内容隔离

### 8.1 `cms_` session 合同

- session 是服务端生成的高熵随机 token，前缀 `cms_`。
- session 必须包含/绑定 canonical user 与 `serviceRoute` audience。
- 旧的无 route session 只能解释为 global，不能自动升级成 CN session。
- global 与 cn 分别存储 token、provider、identity credential、过期时间和账号 profile。
- token 最大长度受限；客户端拒绝 `cms_local_` 或其它本地伪造前缀。
- 手机号验证成功直接 adopt 服务端返回的 `cms_`；Google/Apple/email 先向当前 route 的 `/api/mobile-auth/session` exchange。
- 手机号没有可离线重放的 provider credential。session 真正过期且后端不提供 refresh token 时，应要求重新收短信登录，不能拿 global token 续 CN。

现有后端基线为 30 天 session，剩余不足 7 天时可滚动续期。客户端仍必须以服务端返回和错误码为准，不能自行延长。

### 8.2 401 状态机

| 服务端错误 | 含义 | 客户端动作 |
|---|---|---|
| `AUTH_PROVIDER_REQUIRED` | 请求漏了 `X-Auth-Provider: session` | 修复当前请求，不盲目跨线/清账号 |
| `INVALID_SESSION` | token 非法 | 仅清当前 route session，显示当前 route 登录墙 |
| `SESSION_EXPIRED` | session 过期 | 同 route 有 provider credential 时最多 refresh/retry 一次；手机号要求重新登录 |
| `SESSION_ROUTE_MISMATCH` | token audience 与 public host 不符 | 清当前 route 错误 token，禁止换 host 重试 |
| HTTP 409 + `ACCOUNT_PENDING_DELETION` | canonical 账号正在注销 | 阻止登录/换绑并显示注销处理中；不按 401 清 token 或循环重试 |
| 网络、DNS、TLS、超时、5xx | 传输/服务故障 | 保留登录态，同 route 有界重试或展示错误 |

竞态要求：

1. 每次登录/登出/账号切换递增 `accountGeneration`。
2. 请求捕获 generation、route、发出时 token。
3. 迟到 401 只有在三者仍与当前状态一致时才能清 session。
4. 账号 A 的迟到响应不能登出账号 B。
5. 登出先同步 detach 本地 session 与账号，再异步请求服务端 revoke。
6. revoke 失败不能把刚登录的新 session 清掉。

### 8.3 账号发布顺序

登录成功必须遵循：

~~~text
1. 验证 route-local cms_
2. 解析 canonical user
3. 计算 AccountContentScope
4. 递增 accountGeneration
5. 停止并清空旧播放器 / Reader / QuickRead / pending tasks
6. 激活新 scope 的所有持久化与缓存
7. 恢复新 scope 的本地数据
8. 最后 publish account，让主界面出现
~~~

严禁先 publish 新手机号账号，再让首页继续读取全局单例里的旧账号书架。根视图应以 account boundary id/key 重建。

### 8.4 必须按 `route × account` 隔离的数据

- account profile 与 provider credential
- `cms_` session
- Pro 服务端快照与免费额度
- 播放队列、now playing、Reader/QuickRead 状态
- 历史、阅读进度、最近内容
- 云文档与上传任务
- YouTube transcript/cache/progress/pending share
- 语音克隆与选中的账号拥有音色
- Kindle、微信读书、Google Play 图书、Kobo、O’Reilly 的本地书架投影
- 第三方 WebView cookies、localStorage、IndexedDB 与会话
- 提醒和通知中的书名/进度

WebView 无法建立真正多 profile 时，最低安全方案是在账号边界完全清除该 provider 的 Web 数据并要求重新绑定；不能让两个 CastReader 账号共享同一套第三方登录 Cookie 后又展示为“账号隔离”。

**只按 `route` 隔离、不能误做成 `route × account` 的状态：**

- `StableDeviceID` 是 route-scoped，同一线路不同账号共享同一个设备 ID；它不是账号身份，也不能单独授予 Pro。
- Analytics queue/dead letter 当前也是 route-scoped；匿名 install id 甚至可能设备共享。事件仍不得携带 raw account、手机号或正文。
- quota 的权威主体由服务端 canonical user + route 决定；设备 ID 只用于匿名/兼容维度，不能把 route-scoped device id 当成账号 scope key。

### 8.5 可以设备级共享的数据

以下数据可以设备级共享，但必须明确写入隐私和产品设计，不能笼统声称“全部本地数据完全隔离”：

- UI 语言
- 无账号属性的一般外观/辅助设置
- 是否看过通用 onboarding（是否应按账号共享需产品决定）
- 无身份内容的诊断偏好
- 匿名 analytics install id（是否允许跨 route 关联需隐私评审）

`last sign-in provider`、书架 onboarding 进度和匿名 analytics id 当前 iOS 为设备共享；这是有意识的产品选择还是遗留缺口，需要后续单独确认。

### 8.6 切线路的用户体验

~~~text
当前 global 已登录
  └─ 内部设置选择 cn
       └─ 提示“下次完整启动生效”
            └─ 冷启动
                 ├─ CN 有 route-local account + cms：恢复 CN
                 └─ CN 无有效 session：CN 登录墙

再次选择 global 并冷启动
  └─ 恢复原 global account + global 本地内容
~~~

切线路不是“注销所有账号”。用户原线路的持久数据继续保留，只有当前内存态必须彻底销毁。

## 9. QuickRead（解读）合同

### 9.1 中国和全球链路

~~~text
Global:
App → api.castreader.ai/api/quickread/* → global worker → Gemini

China:
App → quickread.castreader.cn/api/quickread/*
    → 验证 CN cms_ / canonical user / route quota
    → 映射高熵 qrc capability
    → allowlist private CN origin
    → CN worker → deepseek-v4-pro
~~~

客户端请求头：

~~~http
Authorization: Bearer cms_...
X-Auth-Provider: session
x-client-platform: ios | android
x-local-date: yyyy-MM-dd
x-quickread-continuation: true   # 仅 continuation
~~~

客户端不得发送：

- provider API key / `x-api-key`
- 可作为身份的 `x-user-id`、`x-email`、`x-device-id`
- 任意 QuickRead base URL
- 另一线路 token

服务端从 public host 和 `cms_` 确定 route 与 principal。`x-client-platform` 只能经过 `ios|android` allowlist 透传，不能硬编码为 iOS。

### 9.2 API

| 操作 | 协议 | 成功终点 |
|---|---|---|
| `POST /api/quickread/extract-plan` | SSE | `block0` + 权威 `done` |
| `POST /api/quickread/extract-block` | JSON | 指定后续块 |
| `POST /api/quickread/compose-block` | JSON | 用 TTS timestamps 回填 marks |
| `POST /api/quickread/fast-block0` | JSON | 极速首段 |
| `GET /api/quickread/qrc_.../...` | bearer capability URL | 当前以“持有高熵 URL + route + TTL”为读取权限 |

公开 `qrc_*`：

- 必须高熵、不可枚举；URL 本身就是 bearer secret，任何持有者在有效期内都可能读取。
- 服务端元数据会绑定 canonical user、route、quota subject 和内部 job，但**当前资产 GET 不要求 `cms_`、也不校验请求者是否 owner**；因此不能声称“跨账号 GET 一定 404”。
- 当前设计 TTL 2 小时；route 不符、过期或传内部 `qr_*` 返回 404。
- `/extract-block`、`/compose-block` 等 continuation POST 仍须用 `cms_` 校验 canonical principal/route/quota，不能因为有 qrc URL 就跳过。
- 如果目标升级为 owner-authenticated asset GET，这是后端与客户端共同的未来变更：客户端媒体请求必须附当前 route bearer，服务端再做 owner + route + TTL 校验；在该变更验收前只能按 capability 模型评估风险。
- URL 本身按敏感 capability 处理，不进日志、埋点、Referer 或崩溃报告。

### 9.3 SSE 完成条件

只有同时满足以下条件才算 plan 成功：

1. 收到可解码的 `block0`；
2. 收到 `done`；
3. `done.total_blocks >= 1`；
4. `block0.job_id == done.job_id`；
5. block index 连续、无重复；
6. 已收到的 job/capability 与当前 account generation 和 route 一致。

流结束但缺 `done` 必须判为截断并进入同 route 有界恢复，不能把 total 默认为 1 后“假完成”。

SSE parser 不能依赖事件之间一定存在空行。遇到新的 `event:`、空行或 EOF 时要正确 flush 前一个事件，并对截断 JSON 失败关闭。

### 9.4 极速首段与正式计划的交接

目标流程：

~~~text
openingParagraphs ── fast-block0 ── TTS ── 立即播放 block 0

remainingParagraphs ── extract-plan
  请求中带 prev_summary = fast narration
  服务端从正式 block 1 开始规划
~~~

硬要求：

- 正式 plan 的输入必须是**严格去掉 opening 的 remaining paragraphs**。
- `prev_summary` 只能作为已讲内容的记忆，不能再次当正文复述。
- 客户端对每个 `(jobId, blockIndex)` 只允许一次 TTS 生成、一次入队。
- fast 成功后，正式 plan 返回的“第一个块”逻辑编号必须偏移到 1，不能再作为 block 0 入队。
- fast/TTS 失败时可以退回完整 plan，但不能先播放 fast 再退回完整输入。
- 切模式、切账号、切文档后，旧 generation 的 fast/plan/TTS 回调全部丢弃。

CN 服务端当前已有 exact/near duplicate 检测和再生成，但这不替代客户端 scope 固化；语义复述仍需用开头与余文明显不同的 fixture 回归。

### 9.5 模型策略

- CN 生产：固定 `deepseek-v4-pro`，不回退 Gemini，也不允许客户端覆盖模型。
- Global：当前 Gemini 路线。
- provider key 只在 worker 环境变量。
- 早期小样本 A/B 测试对象是 `deepseek-v4-flash`；该结果只作为历史工程参考，**不是当前生产模型配置**，也不能外推为 V4 Pro 与 Gemini 的永久质量等价证明。
- CN 当前以端上 OCR/文本为输入，不把照片像素直接发送给 DeepSeek。
- 每次改 prompt、模型版本、thinking、temperature、输出 schema 或 continuation 策略都要重跑相同 fixture。

基线 A/B 记录（5 份公开/合成文本，每份各重复 3 次）：

| 指标 | Gemini 当前路线 | `deepseek-v4-flash`（历史评估） |
|---|---:|---:|
| API 成功 | 15/15 | 15/15 |
| 首轮 JSON 可解析 | 86.7% | 100% |
| 完整 plan 结构通过 | 86.7% | 86.7% |
| 平均 TTFT | 1.196s | 1.067s |
| 平均完整 JSON | 2.752s | 3.101s |

结论是“这批纯文本没有观察到大的结构和可用性差距”，不是“效果永久等价”。DeepSeek 两次合法 JSON 但结构不完整的样本已经转化为总块数、块序号、段落覆盖和同模型重试门禁。

### 9.6 QuickRead 重试与失败

- 网络、408、429、5xx、SSE 截断、可判定瞬时解码问题：同 route 最多有限次数，指数退避并尊重 `Retry-After`。
- 401：按第 8.2 节处理；不能用 `try? / getOrNull` 吞掉。
- 402：明确展示额度/Pro，不包装成网络错误。
- asset GET 返回 404：capability 非法/过期、内部 `qr_*` 或 route 不符，重新建立 job；当前 GET 不读取 owner。
- continuation POST 返回 404：除 job/route 问题外，还可能是 principal owner/quota 不匹配，不得换账号或跨线重试。
- 某块、TTS 或 compose 失败时不能继续跳块并最终显示“完成”。
- continuation 重试必须有幂等/lineage 设计，不能把两次不同 `job_id` 的 block 混用。

### 9.7 iOS 当前仍需保留在风险清单的事项

这些是目标规范与当前实现之间的差距，Android 不得照抄：

- SSE 缺 `done` 时当前部分路径仍可能误判成功。
- 长文切批需要正确重置 `block0Claimed / planFailed / planSettled`。
- fast/compose 的 401 不得被静默吞掉。
- TTS 返回空 segments 必须显式失败，不能让播放器永久等待。
- CN TTS 需要同 host 瞬时错误重试。

## 10. TTS 合同

### 10.1 请求与响应

核心请求：

~~~json
{
  "model": "kokoro",
  "input": "需要朗读的文本",
  "voice": "voice-id",
  "voice_code": "voice-id",
  "response_format": "mp3",
  "return_timestamps": true,
  "speed": 1.0,
  "stream": false,
  "language": "zh"
}
~~~

响应至少包含音频、逐词 timestamps、`processed_text` 和 `unprocessed_text`。

客户端直接渲染 `processed_text` 并在其中按 timestamps 高亮；不要把 timestamps 再映射回原文，否则服务端的标点和空格规范化会造成漂移。

**鉴权与额度现状/目标必须分开描述：**

- 当前 `/api/captioned_speech_partly` 是公开接口，不要求 `cms_`；正式免费用量主要依赖客户端后续调用 listen-track，上游生成本身没有服务端硬闸门，因此可以绕过。
- 目标新客户端 TTS 必须由服务端验证当前 route 的 `cms_` principal，并在生成前原子预占/消费额度，失败或取消按明确规则结算；客户端上报只做补充观测，不能作为权威计费。
- 为保持旧版本并存，不能未经版本窗口直接让既有公开路径强制 401。服务端应采用版本化受保护路径，或只对可识别的新客户端合同启用鉴权；迁移完成前旧公开入口必须有独立限流、监控和下线日期。

### 10.2 播放稳定性

- 每个段落可能返回多个 AudioSegment，按服务端顺序入队。
- 生成开始前 `moreSegmentsExpected=true`，结束或失败必须恢复 false。
- 队列暂空但仍期待后续段时等待，不触发整段完成。
- 0 个 segment 是错误，不是成功。
- 同一 `(accountGeneration, documentId, mode, paragraph/block)` 的迟到音频不得进入新会话。
- QuickRead TTS 按 `(jobId, blockIndex)` 去重。
- 只对 DNS、超时、429、5xx 等瞬时错误在同一公共 host 内有限重试。

### 10.3 中国链路当前事实

客户端目标是：

~~~text
iOS/Android CN → api.castreader.cn/api/captioned_speech_partly
~~~

但 2026-08-14 的服务端实际配置仍由 CN Nginx 将 TTS 代理到 `api.castreader.ai`，后者还可能使用境外计算上游。因此“客户端只连接备案域名”不等于“正文和音频全程境内处理”。

正式放量前必须做明确选择并记录：

1. 接受服务端跨境代理：完成数据跨境、隐私告知、供应商和保留策略评估；或
2. 部署境内 TTS private origin：由 `api.castreader.cn` 只连接境内处理链路。

在没有合规结论前，不能在审核说明或隐私政策中宣称“所有数据均在中国境内处理”。

## 11. 文档、上传与本地解析

### 11.1 Build 39 发布合同：全本地导入

拍照 OCR、PDF、EPUB、DOCX、纯文本和图片由 iOS 端上处理并构建 `ReadingDocument`。Build 39 已移除 Home 文件导入到远端 `ImportViewModel`/上传回退的用户可达路径，且不接受会让系统误选不支持文件的泛化 `.data` 类型。

Build 39 发布包必须保持：

- 用户可达文件导入不访问 `/api/mobile/documents`、`/api/mobile/upload/sts`、`/api/mobile/upload/notify`。
- 不访问旧 `/documents`、`/sts`、`/upload`、`/async-md-upload-by-url`。
- `cloudStorageEnabled=false`；Google Drive / Dropbox / OneDrive 未完成代码不进入本次 release commit / Sources phase。
- 文档正文只在用户主动发起 TTS/QuickRead 时发送到当前已冻结 route；“本地导入”不等于“本地 TTS/LLM”。

因此 CN STS/upload 是网盘/云同步后续版本的独立能力，不是 Build 39 打包或上架的前置依赖。对 Build 39 的验收方式是抓包反向证明这些端点没有被调用，不是为本次包强行开通云上传。

### 11.2 后续云文档/网盘的目标接口（不属于 Build 39）

~~~text
GET    /api/mobile/documents
GET    /api/mobile/documents/{id}
DELETE /api/mobile/documents/{id}
GET    /api/mobile/upload/sts
POST   /api/mobile/upload/notify
~~~

STS 要求：

- 必须有当前 route `cms_`。
- 临时凭证 TTL 900–1800 秒。
- 仅允许 `cos:PutObject`。
- 最大对象 20 MB。
- 禁止 multipart 权限。
- 服务端生成并校验前缀：

~~~text
user/<global|cn>/<canonical-account-hash>/<uuid>/
~~~

- 当前 `/api/mobile/upload/notify` 只接受 `.epub`、`.pdf`；multipart 业务字段为 `filename`、`filepath`、`voice_id`，服务端自行注入 canonical user 和 route。
- DOCX、TXT/Markdown 等可继续端上解析，但在后端扩展并验收 MIME/后缀/解析安全前，不属于当前 mobile cloud notify 上传合同。
- 客户端不能自报 user id 或改前缀访问另一账号。
- 503 时明确提示云上传暂不可用，不得回退匿名旧 `/sts`。

后端发布候选 `6a275aa6` 不包含 mobile documents/upload/COS 这组能力；Android 后续也不得仅根据本节接口表就假定生产已可用。网盘模块启动时需要独立的后端提交、数据迁移、跨账号/跨 route 安全测试和发布窗口。

### 11.3 旧上传兼容

旧客户端仍可能使用 `/sts`、`/documents`、`/async-md-upload-by-url` 或 `/upload`。这些合同若继续支持，必须单独限流、最小权限、短 TTL 和对象大小，且不能把长期 COS 凭据从历史代码复制回服务器。

这些旧合同是已发布旧二进制的服务端兼容责任，不是 Build 39 的 fallback。旧上传故障的回归与 Build 39 “本地导入不受影响”应分别记录，不能互相替代。

## 12. Pro、免费额度与支付

### 12.1 统一账号与权益权威

Global 与 CN 可以有不同进程和 session，但必须共享：

- canonical `user.id`
- provider identity 归一化
- subscription/order/payment
- Apple `originalTransactionId` ownership
- Google Play purchase token ownership
- Alipay trade/agreement ownership
- refund/revoke/tombstone
- Pro 计算规则与对账

本地商店权益用于即时体验，服务端 canonical entitlement 用于跨端同步。不能按 route 建两套互不相认的 Apple 或支付宝账本。

Build 39 候选发布的已验证现状是：

- Global Vercel 入口与 CN `106.54.47.163` 入口的只读探针指向**同一 canonical 数据库端点**，核心账号/session/subscription 计数一致。
- 双入口的 `billing_authority` fingerprint 一致，Apple `originalTransactionId` ownership、订阅和 revoke/tombstone 不是 CN 独立账本。
- `6a275aa6` 的 CN 激活脚本会在切换 release 前校验预期 billing-authority fingerprint；不匹配必须失败关闭并回滚。
- Apple SIWA client/key 与 OAuth token 加密权威已按同一账号模型为双入口候选环境配置；真实 Apple 登录、交易同步和注销 revoke 仍须在本轮双域部署后完成行为探针。

因此本次不需要做“CN 数据库迁回 Global”或两库合并；部署门禁是证明两个 public ingress 仍指向同一 canonical DB/Apple authority，而不是根据环境变量字符表面是否完全一致做推测。

### 12.2 Pro v2

~~~text
GET  /api/mobile/pro/status/v2
POST /api/mobile/pro/listen-track/v2
~~~

两端均只信 `cms_` 中的 canonical user。目标响应示意：

~~~json
{
  "code": 0,
  "data": {
    "pro": false,
    "plan": null,
    "freeRemaining": 3,
    "freeMax": 3,
    "listenSeconds": 0,
    "listenLimit": 1200,
    "listenRemaining": 1200,
    "contract": "mobile-pro-v2",
    "proIdentity": "authenticated_user_id",
    "quotaIdentity": "authenticated_user_route"
  }
}
~~~

规则：

- Pro 权益按 canonical user 跨线路共享。
- 免费额度按 `canonical user × serviceRoute` 隔离。
- 不允许通过轮换 device id 重置额度。
- 当前业务基线：免费解读 3 次/日，朗读 1200 秒/日；数值必须由统一配置/响应驱动。
- 中国配额日切目标为 `Asia/Shanghai` 零点，服务端不信客户端日期。
- “检查剩余后再 +1”必须由单条条件更新/事务原子消费，避免并发超额。
- 正式 TTS 额度不能只靠客户端自觉上报，否则接口可被绕过。

后端候选 `6a275aa6` 没有把现有 UTC 分桶全面迁到 `Asia/Shanghai`，QuickRead 并发 consume 也尚未完成全部原子化；这是第 20.2 节的后续服务强化缺口。Build 39 和审核资料不得宣称这两项已实现。

### 12.3 iOS 中国区支付

- iOS 中国区只使用 StoreKit 2，不在 App 内接支付宝。
- 产品 ID、订阅组、价格来自 App Store Connect。
- `appAccountToken` 只由 canonical user 稳定派生，不包含 route。
- 相同 `originalTransactionId` 只能有一个 canonical owner。
- Global 购买后切 CN 能恢复；CN 购买后切 Global 也能恢复。
- pending、grace、过期、退款、撤销和换机均以 StoreKit + 共享服务端账本协调。
- 账号注销需解释订阅取消与账单关系；Sign in with Apple 账号删除应在服务端撤销 Apple token。

### 12.4 Android Global 支付

- Global 使用 Google Play Billing。
- 价格、币种、billing period、trial 和 offer 来自 Play Billing，不硬编码。
- 目标后端需提供 `cms_` authenticated verify v2：
  - 校验 package、product、purchase token；
  - 校验 obfuscated account id 与 canonical user；
  - purchase token 全局唯一 owner；
  - 忽略客户端 user/device/email 身份声明；
  - RTDN 验证 Pub/Sub OIDC；
  - 临时错误返回 5xx 让 Pub/Sub 重试。

现有旧 `/api/pro/verify-android` 接收 Google id token 和 device/user/email，不应作为中国区新架构的模板。

### 12.5 Android 中国区支付宝

目标接口：

~~~text
GET  /api/pro/plans?provider=alipay
POST /api/pro/alipay/checkout
POST /api/pro/alipay/confirm
POST /api/pro/alipay/cancel
POST /api/pro/alipay/notify
POST /api/pro/alipay/gateway
~~~

安全合同：

- 套餐和金额只由服务端决定。
- 客户端不持有商户私钥，不拼签名。
- 服务端签好的 `orderStr` 原样交给支付宝 SDK。
- checkout、confirm、cancel 是 Android 可调用接口，均以当前 `cms_` principal 为 owner。
- notify、gateway 是支付宝 → 服务端的公开签名回调，不使用 `cms_`，Android 绝不能主动调用；“公开”只表示回调入口可达，不表示可跳过支付宝签名、订单和金额校验。
- SDK 返回 `9000` 只表示客户端支付流程返回，不直接授予 Pro。
- 服务端通过异步通知验签或 `alipay.trade.query` 确认。
- 通知验 RSA/RSA2、`app_id`、商户/卖家、金额、币种、订单 owner 和订单当前状态。
- settle 使用条件更新/事务，重复通知只结算一次。
- 退款/撤销写入统一 entitlement/tombstone。
- 自动续费 cron 如启用，必须有分布式抢占锁和幂等键。

**支付披露必须以服务端计划字段为准：**

| 字段 | UI 行为 |
|---|---|
| `mode=onetime, autoRenew=false` | 明确“一次性购买/有效期”，不得写自动续费 |
| `mode=subscription, autoRenew=true` | 明确周期、扣款、取消方式和下次扣款 |
| 字段缺失/非法 | 购买按钮不可用，提示套餐暂不可用 |

2026-08-14 公开套餐实际为：

- 月：¥28
- 年：¥198
- 两者当前都为 `onetime`、`autoRenew=false`

价格只作为当前只读事实，文档不能成为硬编码价格源。

当前 Android 通用 Paywall 仍显示“Google Play 自动续订/在 Google Play 管理”，设置页也打开 Play 订阅 URL，且 CN 代码丢弃 `mode/autoRenew`。这是消费披露和审核 **P0/P1 No-Go**。后续必须按 flavor 和 plan 动态展示；一次性计划不显示“管理自动续费”，取消入口只在存在可取消协议时显示。

### 12.6 恢复与账号要求

- 手机号账号没有 email 也必须能识别 `serverPro`、购买、恢复和取消。
- email 是可选 profile，不是中国区付款前置条件。
- Android 当前 `ProViewModel/ProManager` 把 email 非空作为 Pro/购买条件，导致手机号用户无法正确购买或恢复，后续必须改为 `backendUserId + cms_`。
- 支付成功但服务端 entitlement 尚未到达时显示“处理中”，不乐观永久解锁，也不宣称失败。

## 13. 书架平台与第三方会话

### 13.1 保留原则

发行区域只改变默认值和排序，不能用“在中国可能访问困难”直接隐藏已有平台。连接页应保留原有错误、重试和断开能力。

Android 当前 CN 从 `availableBoundLibraries` 中排除了 Google Play 图书，并缺少 O’Reilly；这与本文最终产品要求不一致。后续至少要保留入口，并在真实网络不可用时给出明确错误，而不是静默消失。

### 13.2 第三方凭据边界

- 不保存用户第三方密码。
- WebView bridge 只提取公开书架元数据、可见正文或阅读进度所需最小信息。
- 第三方 Cookie 不上传到 CastReader 后端。
- 断开某一个书架只清该书架在当前 account scope 的状态，不误清其它 provider。
- 切 CastReader 账号/route 时，第三方 Web 数据按第 8 节隔离或清空。
- 原始 provider account evidence 在持久化前规范化并不可逆哈希；UI 只显示安全标签。

### 13.3 微信读书首启

中国区首启：

1. 说明“让微信读书里的书能听”；
2. 用户主动连接；
3. 同一 WebView 完成登录/扫码，不因 phase 切换重建；
4. 选择示例/自己的书；
5. 实际播放达到验收阈值后完成引导；
6. 每阶段保留“稍后/跳过”，但不能因此删除其它书架。

二维码、Cookie、密码和整本正文不进入 CastReader 日志或分析。

## 14. 合规与商店提交框架

本节是工程发布门禁，不是法律意见。涉及出版、新闻、宗教、医疗等资质边界时，应取得专业法律/主管部门书面结论。

### 14.1 中国大陆 App 备案

- 在中国境内提供互联网信息服务的 App 应完成 APP 备案。
- 当前备案号：`沪ICP备14008512号-12A`。
- App Store Connect 简体中文元数据、App 名称、主体信息、Bundle ID/包名和备案信息必须与工信部记录一致。
- Android 国内分发也必须使用与备案一致的包名 `com.same.castreader`；不能为了 flavor 随意增加后缀。
- App 内“关于/设置”按分发平台要求展示备案号并可链接工信部备案查询页。
- 正式提交前保存备案控制台状态截图和商店填写截图。

备案材料曾显示资源 IP `49.234.54.42`，当前 `api.castreader.cn` 和 `quickread.castreader.cn` 的公开服务 IP 为 `106.54.47.163`。即使同主体、同腾讯云，也不能自行推定接入备案一定无影响。必须在腾讯云备案控制台或官方工单确认接入状态，必要时完成变更。

### 14.2 Apple 中国区元数据

- App Store Connect 的 China mainland availability / ICP 字段按官方要求填写。
- ICP 号与简体中文本地化元数据必须匹配；无简体中文时匹配主语言。
- 主体中文名称和统一社会信用代码应与开发者账号/D‑U‑N‑S 合规信息一致。
- 审核说明明确 CastReader 是用户输入驱动的 TTS / 辅助阅读工具，不运营自有图书或期刊目录。
- 如果 Apple 判断应用属于书刊内容、新闻、宗教等需专项许可范围，不以“工具”自我描述替代书面确认。
- 登录、后台和 IAP 在审核期间必须真实可用；提供审核手机号/一次性验证码方案或经 Apple 接受的 demo mode。
- 中国区 iOS 数字功能仍使用 StoreKit IAP，不能在 App 内引导支付宝/网页购买。
- 支持账号创建就必须在 App 内提供易发现的完整账号注销。

官方依据见第 24 节。

### 14.3 隐私和权限

- 首次请求相机、相册、通知、麦克风等权限前说明用途；不用的权限不声明。
- Android CN manifest 不应继承 Play Billing、Play Services query 或无用 Google 依赖。
- 相册/文件优先使用系统 Picker/SAF scoped URI。
- 隐私政策列明手机号、设备标识、用户输入文本、TTS/QuickRead 处理方、存储位置、保留周期、删除方式和跨境情况。
- 日志不得包含正文、手机号、验证码、email、`cms_`、`qrc_`、支付订单串、音频 base64、第三方 Cookie 或 provider Secret。
- Analytics 只发送枚举、耗时、错误分类和聚合数量；中国事件发送当前 `api.castreader.cn/api/events`，不硬编码 `castreader.ai`。

### 14.4 账号注销

- 设置页中易发现。
- 二次确认可以有，但不能要求打电话/发邮件才能开始。
- 服务端成功接受后再清本地并说明处理时限；服务端失败不能谎称已删除。
- 注销立即吊销所有 route sessions/device link，冻结新登录，异步清理个人数据。
- Apple 用户同时处理 Apple token revocation；支付记录仅按法律和财务必要期限保留。
- 说明 App 账号删除不等于商店订阅自动退款/取消，并提供正确管理方式。

## 15. Build 39 发布状态快照（2026-08-14）

### 15.1 已冻结的候选基线

| 层 | 候选基线 | 已完成证据 |
|---|---|---|
| iOS | Build 39 中国区基线 + 右上角头像回归修复 | Release 模拟器编译通过；完整单元测试 **895 个，6 个跳过，0 失败**；头像 UI 回归测试通过 |
| Backend | `6a275aa6` — mobile auth/routing/Pro/Apple/QuickRead/CN deployment contracts | TypeScript `tsc --noEmit` 通过；后端测试 **205 个，203 通过，2 个有意跳过的 integration，0 失败** |
| Content build closure | `3f71b023` — 博客图片从已退役 COS 迁到现有公开对象宿主 | `NEXT_PUBLIC_APP_URL=https://api.castreader.ai pnpm build` 通过 |

候选分支已包含中国区基线 `2ecb07d` 与今日 UI 优化；右上角账号入口恢复 UI 分支介入前的 28pt 头像 / 30pt 布局尺寸，不显示 Pro 描边或角标。未完成 Google Drive / Dropbox / OneDrive 网盘模块没有进入本次提交范围，Build 39 的用户文件入口已按第 11 节固定为本地导入。

已确认的环境事实：

- `api.castreader.cn` 与 `quickread.castreader.cn` 公开 DNS 均指向 `106.54.47.163`，独立 TLS 有效。
- Global Vercel 与 CN 入口使用同一 canonical DB 端点和相同 billing/Apple authority fingerprint，不存在需要合并的两套用户/订阅库。
- iOS 真机已收到真实腾讯云验证码；短信签名是“上海包子信息科技”，不是 `same`。
- CN QuickRead 的生产模型路线是 `deepseek-v4-pro`，不回退 Gemini；Build 39 客户端已修复 block0 与首个正式 block/TTS 重复入队。

### 15.2 正在进行的部署和线路切换

| 项目 | 本文快照时状态 | 安全边界 |
|---|---|---|
| Global 候选 | Vercel preview/production 部署和 API 探针进行中 | 未通过前不宣称 `6a275aa6 + 3f71b023` 已在 `api.castreader.ai` 生效 |
| CN 候选 | `106.54.47.163` 原子 release 激活/回滚探针进行中 | 激活必须校验 route、TLS、401/422 边界和 billing fingerprint |
| runtime control plane | 仍是 `iosChinaServiceRoute=global`，无 CN build 窗口 | **尚未最终切换**；只有双域部署探针通过后才能设 `cn + minimumBuild=39 + maximumBuild=39` |
| 旧版 iOS | 仍走原全球链路 | 即使 Build 39 开 CN，Build 38 及更旧 build 仍必须因版本窗口不匹配而保持 global |
| App Store | 打包前验收进行中 | 本快照不将“已提交代码”写成“已上传/已送审” |

runtime 切换是最后一个服务开关，不能为了测试提前扩大窗口。发生回滚时只把下一启动线路设回 `global`，不删除 CN route-local 账号与内容。

### 15.3 iOS Build 39 实际实现

| 模块 | Build 39 实现 | 发布验收状态/留意 |
|---|---|---|
| 启动/产品区 | `AppStartupCoordinator` 先解析 StoreKit storefront，`CHN` 为 CN，HKG/TWN/MAC 为 Global | 无缓存且 storefront 超时时本进程安全使用 global；不热切 UI |
| 服务线路 | `ServiceRouting` 与产品区分离，冷启动冻结 | production runtime 仍 global，Build 39 限定窗口待双域探针后开启 |
| 登录渠道 | CN 手机全宽 + Apple 小图标，无 Google/邮箱；Global Google 全宽 + Apple/邮箱小图标 | 真短信已收到；候选部署后回归 Apple/手机/session 过期 |
| 协议 | checkbox 与单句整体居中，条款/隐私有颜色下划线且可点，pending action 同意后执行原登录 | 协议版本化 receipt 是后续合规增强 |
| 账号隔离 | `SHA-256(route|backend:canonicalId)` / provider 临时 scope + alias，登出/换号在 publish 前切 store/cache/player/Web 边界 | `StableDeviceID` 和 analytics queue 只是 route-scoped，明确不属于 account scope |
| 本地导入 | PDF/EPUB/DOCX/text/image/OCR 在端上解析，无远端 upload/documents 依赖 | 网盘功能关闭且不入本次包；以抓包证明无上传请求 |
| 书架 | 保留 Kindle、微信读书、Google Play Books、Kobo、O’Reilly 与 YouTube；CN 默认微信读书 | 引导默认不覆盖用户已选项 |
| QuickRead | Global `api.castreader.ai`，CN `quickread.castreader.cn`；Bearer `cms_`；CN DeepSeek；block0/TTS 去重 | 仍按 9.3/9.7 用长文、SSE 截断、空 TTS 和跨批 fixture 回归 |
| TTS | CN 生成 URL 只用 `api.castreader.cn/api/captioned_speech_partly`，response asset 只放行 `/api/tts/*` | CN Nginx 当前仍可在服务器侧代理 `.ai` TTS，数据路径披露必须准确 |
| iOS 支付 | StoreKit 2 + canonical DB/Apple billing authority | 双入口候选部署后做购买/恢复/退款/revoke 回归 |
| 本地化 | 资源含 system + 9 种正式 App 语言，CN 关键 key 已静态审计 | 目前只明确有 `zh-Hans` 关键 UI 真机证据；不宣称九语 CN 真机矩阵已全验收 |

### 15.4 Build 39 剩余发布门禁

1. Global 候选和 CN 候选均完成部署，受保护路由的 401/422、QuickRead、Pro、TTS、runtime config 和 billing fingerprint 探针通过。
2. 真机执行 CN 手机/Apple、global↔cn 冷启动往返、A→退出→B 内容隔离、QuickRead 3+ block 无重复、TTS 连续播放。
3. 双域探针通过后，runtime 使用 CAS/管理合同只对 `minimumBuild=39` 与 `maximumBuild=39` 设 `cn`，回读公开配置并验证旧 build 仍 global。
4. 完成签名 Archive、上传后等待 Build 39 `VALID`，绑定 1.2.24 元数据/审核资料后再送审。

网盘/mobile upload、Android 中国包和 Android 支付宝不在 Build 39 发布范围内，不得把它们混入本次 iOS 包，也不得用它们的未完成状态否定 Build 39 已确定的本地导入范围。

## 16. Android 后续交接：当前基线与差距

> 本节只定义后续工作，不表示本轮已经执行 Android 改造。

Android 工程：`/Users/xuxuheng/Documents/CastReader-Android`

现有基础：

- Kotlin + Compose + Hilt + Retrofit/OkHttp + Moshi + DataStore + Media3。
- `global/cn` product flavor 已存在，包名均为 `com.same.castreader`。
- CN 已编译期使用手机号和支付宝实现类，Global 使用 Google/Play Billing。
- CN 微信读书首启、手机号 UI/API、Alipay SDK/接口和 Keystore session 已有雏形。

但现有测试通过不代表中国区可发布；当前高风险合同基本没有覆盖。

### 16.1 P0：发布前必须先解决

| P0 | 当前实现 | 目标 |
|---|---|---|
| 产品区和网络混用 | `AppRegion.kt` 同时提供 web base；`CHINA_BACKEND_ENABLED=false` | 单独 `ServiceRoute`，进程冻结 |
| CN base 错误 | 即使打开开关也是 `https://castreader.cn/` | 通用 `https://api.castreader.cn/`，QR `https://quickread.castreader.cn/` |
| TTS 时区路由 | `TtsEndpointRouter/Interceptor` 按时区选旧 Seeta，CN 失败回 US | flavor/route 固定公共网关，同 route 重试 |
| QuickRead key/base | APK 中 `QUICKREAD_API_KEY`；远程配置任意 URL/key；发送自报身份 | 移除 key，Bearer `cms_`，精确 host |
| QuickRead 假完成 | EOF 不强制 done；块/TTS/compose `getOrNull` 后继续 | 权威 done、显式失败、有界恢复 |
| 生产伪登录 | `PhoneLocalFallback.ENABLED=true`，`888888`，`cms_local_<phone>` | Release 完全不存在 |
| 手机号 Pro 失效 | email 非空才算 serverPro/才能购买恢复 | `cms_ + canonical backendUserId` 充分 |
| 账号串号 | account/session/DataStore 多为全局 key，首页只判断 account 非空 | route session + account scope + generation |
| 付费披露错误 | 一次性支付宝计划仍显示 Google Play 自动续费 | 按 `mode/autoRenew` 渲染 |

### 16.2 P1：功能完整和审核门禁

| P1 | 当前实现 | 目标 |
|---|---|---|
| 协议交互 | 底部独立条款按钮；checkbox 在 phone sheet；未勾只禁用 | 单句居中可点链接 + pending action 弹框 |
| 验证码输入 | 发码成功后才出现 | 始终显示 |
| 九语 | 多语言 phone/payment 仍继承英文或 Play 文案 | 九语完整本地化 |
| Manifest | CN 继承 BILLING、Play/GMS queries | 移到 global manifest |
| Analytics | 硬编码 `castreader.ai/api/events` | 当前 route `api.*` |
| 账号注销 | CN API 有实现但缺完整 UI/状态 | 设置页 server-first 注销 |
| 上传 | 旧匿名 `/sts` 和自报 user id | mobile STS + notify + `cms_` |
| 书架 | CN 排除 Google Books，缺 O’Reilly | 五个平台 + YouTube 全保留 |
| 管理订阅 | 永远打开 Google Play URL | 按支付渠道和实际 agreement 状态 |

### 16.3 P2：质量、观测和运维

- 九语 × CN 登录/协议/支付/微信首启截图测试。
- 长文 QuickRead 跨批、弱网、前后台和进程恢复。
- WebView route/account profile 迁移与回归。
- 同 route 请求 id、job/block、匿名错误码的结构化观测。
- 国内多网络运营商、VPN/无 VPN、IPv4/IPv6、弱网测试。
- 国内应用市场渠道号、签名、备案信息和商店元数据自动校验。

## 17. Android 后续目标设计

### 17.1 建议组件

~~~text
distribution/
  DistributionRegion.kt
  DistributionPolicy.kt

network/routing/
  ServiceRoute.kt
  ServiceRoutingSnapshot.kt
  RuntimeRoutingConfigRepository.kt
  FirstPartyEndpoints.kt
  OwnedHostRedirectInterceptor.kt

auth/
  MobileSessionRepository.kt
  MobileSessionAuthenticator.kt
  AccountScope.kt
  AccountBoundaryCoordinator.kt
  ConsentGate.kt

quickread/
  QuickReadClient.kt
  QuickReadSseParser.kt
  QuickReadJobCoordinator.kt

billing/
  EntitlementRepository.kt
  ChinaAlipayBilling.kt
  GlobalPlayBilling.kt
~~~

命名可按工程风格调整，但职责边界必须保留。

### 17.2 `DistributionRegion`

~~~kotlin
enum class DistributionRegion { GLOBAL, CN }

interface DistributionPolicy {
    val region: DistributionRegion
    val loginChannels: List<LoginChannel>
    val defaultLibrary: LibrarySource
    val availableLibraries: List<LibrarySource>
    val paymentChannel: PaymentChannel
}
~~~

- 由 flavor 生成不可变实现。
- 不包含 API URL。
- 不读取时区决定产品行为。
- CN libraries 目标为 WeRead、Kindle、Google Books、Kobo、O’Reilly；YouTube 作为独立内容入口保留。

### 17.3 `ServiceRouteSnapshot`

~~~kotlin
enum class ServiceRoute { GLOBAL, CN }

data class ServiceRouteSnapshot(
    val route: ServiceRoute,
    val source: RouteSource,
    val frozenAtElapsedRealtime: Long
)

data class FirstPartyEndpoints(
    val apiBase: HttpUrl,
    val quickReadBase: HttpUrl
)
~~~

初始化顺序：

~~~text
Application.onCreate
  → resolve DistributionRegion
  → discard production-disallowed overrides
  → resolve and freeze ServiceRouteSnapshot
  → construct endpoint-bound OkHttp/Retrofit singletons
  → load only route-local session/account
  → activate account scope
  → render root auth gate/main UI
~~~

禁止在 Interceptor 每个请求时重新读取 DataStore route；否则一次进程内仍可能热切。

### 17.4 Retrofit / OkHttp

建议不要再建立“main/reader/web 三套各自硬编码 Retrofit”。可以：

1. 为 frozen route 创建统一 first-party OkHttp；
2. API 和 QuickRead 使用两个精确 base；
3. 第三方 HTTP 使用不带 CastReader bearer 的独立 client。

拦截器顺序建议：

~~~text
RequestIdInterceptor
→ OwnedEndpointPolicyInterceptor
→ RouteSessionInterceptor
→ SanitizedMetricsInterceptor
→ network
~~~

`RouteSessionInterceptor`：

- 只对 allowlisted protected paths 加 `Authorization` 和 `X-Auth-Provider`。
- 从 snapshot 对应的 session repository 读 token。
- QuickRead 加 allowlisted platform/local-date/continuation header。
- 不发送 user/email/device/key。

`OwnedHostRedirectInterceptor`：

- 对 first-party client 禁止自动跨 host redirect。
- 校验 scheme、host、port、path。
- 第三方 client 不使用该 bearer。

401 refresh 更适合 OkHttp `Authenticator` 或统一 repository 处理，但必须有“最多一次、同 route、同 generation、同 rejected token”约束。

### 17.5 Session 存储

建议：

~~~text
EncryptedSharedPreferences / Keystore alias:
  castreader_mobile_session_v2_global
  castreader_mobile_session_v2_cn

DataStore account profile:
  account.profile.global
  account.profile.cn
~~~

session record 至少包含：

~~~kotlin
data class MobileSessionRecord(
    val tokenCiphertext: String,
    val route: ServiceRoute,
    val canonicalUserId: String,
    val expiresAt: Instant?,
    val provider: AuthProvider,
    val generation: Long
)
~~~

迁移：

- 旧单 key session 只迁到 global。
- `cms_local_` 不迁移，直接清除并要求真实登录。
- account profile 没有同 route 有效 session 时不恢复。
- 发现 audience/host mismatch 时只清目标 route。

### 17.6 Account scope coordinator

~~~kotlin
interface AccountScopedComponent {
    suspend fun deactivate()
    suspend fun activate(scope: AccountScope)
}

class AccountBoundaryCoordinator(
    private val components: Set<AccountScopedComponent>
) {
    suspend fun switchTo(account: CanonicalAccount, route: ServiceRoute)
}
~~~

切换过程需要 Mutex/串行 actor，不能多组件并行到一半就 publish account。所有 repository 写入都接受 scope 或从只读 active scope 获取；禁止继续使用无 scope 的全局 DataStore key。

Android `AccountScope` 的 opaque id 必须完全复用第 2.3 节的命名空间合同：

~~~text
SHA-256("<route>|backend:<canonicalId>")
或临时 SHA-256("<route>|provider:<provider>:<providerUserId>")
~~~

不得把 `StableDeviceID`、analytics queue/dead-letter 放入 `AccountBoundaryCoordinator`；它们是 route-scoped 而非 account-scoped，换账号时必须保持，只在换 route 时切换命名空间。

文件型缓存：

~~~text
files/account-scopes/<opaqueScopeId>/...
noBackupFiles/account-scopes/<opaqueScopeId>/...
~~~

WebView：

- `WebView.setDataDirectorySuffix(...)` 是**进程级**配置，且必须在该进程第一次创建 WebView 前调用；同一进程运行期间不能按 provider/account 动态切 suffix。
- 若要真正按 opaque scope 建独立 profile，必须让 WebView 运行在专用进程，并在该进程冷启动、创建任何 WebView 之前固定 suffix；切 scope 时终止并重建该专用进程。
- 同进程的最低合同是在 account boundary 清 CookieManager、WebStorage 和 cache，等待清理完成后强制重新绑定；不得宣称同时保留多个隔离 profile。
- YouTube 官方公开字幕 extractor 可保持独立无账号 process，但 pending share/history/progress 仍要归属当前 account scope。

### 17.7 Consent Compose 设计

~~~kotlin
data class ConsentState(
    val accepted: Boolean = false,
    val pendingAction: LoginAction? = null,
    val dialogVisible: Boolean = false
)
~~~

使用 `AnnotatedString + ClickableText/LinkAnnotation` 实现同一句内两个链接。checkbox、文本整体用 `Row` 居中，并处理 320dp、小字体/大字体、横屏和九语换行。

Agree handler 必须原子：

~~~kotlin
val action = state.pendingAction
state = state.copy(accepted = true, pendingAction = null, dialogVisible = false)
action?.let(::executeOnce)
~~~

### 17.8 QuickRead Android 状态机

建议统一状态：

~~~kotlin
sealed interface QuickReadState {
    data object Idle
    data object Planning
    data class Ready(val jobId: String, val totalBlocks: Int)
    data class Playing(val jobId: String, val blockIndex: Int)
    data class RecoverableError(val stage: Stage, val retryAfter: Duration?)
    data class AuthRequired(val route: ServiceRoute)
    data class QuotaRequired(val remaining: Int)
    data class Failed(val publicCode: String)
    data object Completed
}
~~~

不允许 `catch { null }` 后跳过。每块具有：

~~~text
jobId, blockIndex, sourceScopeHash, ttsState, composeState, enqueueState
~~~

只有 `done + 0..<totalBlocks 全部一次完成` 才进入 Completed。

### 17.9 Pro 与 Billing

`EntitlementRepository` 合并：

~~~text
effectivePro =
  localStoreEntitlement (Play/StoreKit equivalent)
  OR authenticatedServerEntitlement
~~~

CN 手机号没有 email 时，server entitlement 仍然有效。

Billing UI 不读取 `AppRegion.currencySymbol`，只渲染 plan/store 返回的 localized price、mode、period、trial、renewal 和 cancellation policy。

## 18. Android 后续实施顺序（只作交接，不在本轮执行）

### Phase A：安全地基

1. 删除 Release 直通码、`cms_local_` 和 APK QuickRead key。
2. 拆分 DistributionRegion / ServiceRoute。
3. 冻结 route 并集中 endpoints。
4. 加精确 host/redirect 安全边界。
5. route-scoped session 和 legacy→global 迁移。

退出条件：

- CN 包抓包没有 QuickRead key。
- CN TTS/QuickRead 不触达 `.ai`。
- Release 输入 `888888` 不可能登录。

### Phase B：账号与登录

1. 根登录墙要求 profile + route session。
2. AccountScopeCoordinator 接入所有持久化和播放器。
3. 实现协议 pending-action。
4. 手机号 UI 始终显示验证码框。
5. server-first 注销。

退出条件：

- A→登出→B，首页、书架、历史、播放、Cookie 全部只显示 B。
- global→cn→global 恢复各自账号，无 token 跨 host。

### Phase C：核心网络

1. QuickRead bearer/SSE/done/去重/重试。
2. TTS route 固定、空 segment 和同 route retry。
3. Pro v2 与原子额度。
4. mobile documents/upload。

退出条件：

- 长文 3+ blocks 无 block0/TTS 重复。
- 截断 SSE 不假完成。
- STS 跨账号/route 失败关闭。

### Phase D：支付、书架与本地化

1. 手机号 Pro。
2. Alipay plan-aware UI、真实支付/恢复/取消。
3. 恢复五书架 + YouTube。
4. 九语与 CN manifest。

退出条件：

- 一次性计划不出现“自动续费/Google Play 管理”。
- 九语截图无英文占位和截断。

### Phase E：真机、灰度与商店

只在前四阶段通过后进行；本轮不执行。

## 19. 测试与验收矩阵

### 19.1 自动化合同测试

#### 区域和路由

- CN flavor 只能得到 CN 产品策略。
- global flavor 只能得到 global 产品策略。
- route 优先级、损坏值、过期缓存、build 越界、未知字段。
- CN 启用必须有 min/max versionCode。
- 进程冻结后修改设置不改变现有 Retrofit host。
- Release 忽略测试覆盖。

#### Host 与 header

- Global API/QR 只命中 `api.castreader.ai`。
- CN API/TTS 只命中 `api.castreader.cn`。
- CN QR 只命中 `quickread.castreader.cn`。
- CN→Global redirect 拒绝。
- protected 请求有 Bearer + provider；没有 user/email/device/key。
- 第三方 URL 没有 CastReader bearer。

#### 手机和 consent

- `+86/0086/86` 归一化。
- 非法手机号和非 6 位码拒绝。
- 未勾选点手机号→弹框→同意→发送恰好一次。
- 不同意不发送。
- 验证码框初始可见。
- 429 倒计时使用服务器 `retryAfter`。
- 注入腾讯云发送失败后，旧的未过期验证码仍可验证；失败请求不产生新的有效 challenge。
- raw phone 不进入 profile/DataStore/log/analytics，登录后只保留掩码。
- Release 不含 `888888/cms_local`。

#### Session 与账号

- legacy session 只迁 global。
- route mismatch 不跨线重试。
- A 的迟到 401 不登出 B。
- DNS/5xx 不清 session。
- profile 无 token 不放行。
- A→B 的每个 store/cache/player/WebView 都不串。
- AccountContentScope 的 backend/provider fixture 必须证明哈希输入含 `backend:` / `provider:` 命名空间前缀，不是只哈希 raw id。
- 换账号不旋转 `StableDeviceID`、不切换 analytics route queue；换 route 才切换这两类 route-scoped 状态。

#### QuickRead

- SSE 有/无空行都解析。
- 缺 block0、缺 done、job id 不一致均失败。
- fast opening 从 quality input 删除。
- `(jobId, blockIndex)` 只入队一次。
- extract/TTS/compose 任一失败不进入 Completed。
- 401、402、404 capability、429、5xx、截断 SSE 分流。
- 当前 capability 模型下，合法未过期 `qrc_` asset GET 不校验 owner，所以不应把“另一账号 GET 仍成功”误判为合同回归；错 route、过期、内部 `qr_*` 才应 404。
- continuation POST 必须验证当前 `cms_` principal；更换 owner、route/quota 不匹配或 job 不可用应以 404/明确业务错误失败，不得因持有 qrc URL 继续。
- 长文跨批重置状态。

#### 路由与 TTS 安全

- runtime 缺失 `cacheSeconds` 或类型错误时整份配置 fail closed 到 global；合法整数 299/300/604800/604801 秒按 300～604800 clamp。
- CN 生成请求只允许精确 `POST https://api.castreader.cn/api/captioned_speech_partly`；HTTP、非 443 端口、其它 host/path 和该 path 的任意延伸都失败关闭。
- CN 只允许精确 host 下 `/api/tts/*` response URL；仅精确 `api.castreader.ai` 且 `/api/tts/*` 可做 path/query-preserving `.ai → .cn` 兼容改写，其它 owned URL fail closed。
- 新客户端受保护 TTS 无有效 `cms_` 返回 401，跨 route token 失败；并发生成不能绕过原子额度。
- 旧版公开 TTS 兼容入口有独立限流、观测和可执行下线窗口。

#### Pro / 支付 / 上传

- 手机号无 email 仍可 serverPro。
- global/CN canonical user 权益一致、配额隔离。
- 并发 consume 不超额。
- Alipay onetime/renewal 文案。
- 重复 callback 只结算一次。
- STS 前缀、20MB、TTL、跨账号、跨 route。

#### Build 39 本地导入

- PDF/EPUB/DOCX/text/image/OCR 各入口均在端上构建文档。
- 抓包证明用户可达导入不请求 mobile documents/upload 或旧 documents/STS/upload 端点。
- 网盘 feature flag 为 false，未完成 provider 文件不进 Sources phase/发布 commit。

### 19.2 九语 UI 矩阵

九种语言分别验证：

- CN 登录墙；
- checkbox/协议句和弹框；
- 手机号 sheet、错误、倒计时；
- 微信读书引导；
- Paywall、一次性/订阅披露、处理中、恢复/取消；
- 设置账号、注销、备案信息；
- 小屏、横屏、系统最大字体、深浅色。

### 19.3 真机 E2E

| 场景 | 证据 |
|---|---|
| 旧线上版本 | 抓包 + 登录/Pro/TTS/文档/上传回归 |
| 新 Global | 所有 mobile v2、QuickRead、TTS、支付 |
| 新 CN iOS | 手机/Apple/StoreKit/QR/TTS/上传 |
| 新 CN Android | 手机/Alipay/QR/TTS/上传 |
| 路线往返 | global→cn→global 各自账号和内容恢复 |
| SMS 风控 | 重发、小时限制、错码、过期、并发 |
| QuickRead 长文 | 3+ block、无首块/TTS 重复、SSE 中断 |
| TTS | 多段、时间戳、后台、弱网、同 route retry |
| Apple | 一线路购买，另一线路恢复，退款/撤销 |
| Alipay | 小额/沙箱首购、通知、query、重复通知、退款、换机 |
| 上传 | 正常、20MB、过期、错误 owner/route |
| 中国网络 | 多运营商、法务页、备案域名、TLS |

日志/抓包必须脱敏后保存，不保留正文、token、手机号、验证码、订单串或 capability URL。

### 19.4 Android 后续执行时的最低命令门

以下命令只是后续交接要求，本轮不执行 Android 改造：

~~~bash
./gradlew testCnDebugUnitTest testGlobalDebugUnitTest
./gradlew lintCnRelease lintGlobalRelease
./gradlew assembleCnRelease assembleGlobalRelease
./gradlew connectedCnDebugAndroidTest
~~~

Release 产物还应做反向 secret/旧线路扫描；扫描规则至少覆盖：

~~~text
888888
cms_local_
QUICKREAD_API_KEY
quickread.castreader.ai
qr.castreader.ai
旧 SeetaCloud TTS host
TENCENT_SMS_SECRET
DEEPSEEK_API_KEY
支付宝私钥片段
~~~

CN 产物允许出现 `api.castreader.ai` 的情况必须逐条有清晰解释（例如显式 internal global 测试配置的枚举逻辑）；正式 CN route 的业务抓包不得实际访问它。

## 20. 发布 Go / No-Go

### 20.1 iOS 1.2.24 (Build 39) 本次发布门禁

本次用户已授权完成 iOS 代码提交、双域后端候选部署、严格测试、打包与 App Store 提交。以下是 Build 39 的实际 Go/No-Go：

- 打包内容精确固定在 iOS `2ecb07d`，包含 UI 基线 `b8d6114`，不包含未完成网盘文件。
- Global 候选 `6a275aa6 + 3f71b023` 和 CN 同候选都完成部署/探针；runtime config、phone auth、Pro v2、Apple authority、QuickRead 和 TTS 的公开 host/鉴权语义一致。
- 双入口部署后仍连接同一 canonical DB 与 Apple billing authority，激活脚本的 fingerprint 校验通过。
- runtime 只对 `minimumBuild=39` 与 `maximumBuild=39` 开 `cn`，且必须在双域探针通过后才更新；Build 38 和已上线旧版仍走 global。
- CN 手机发码/验码、Apple、A→退出→B、global↔cn 冷启动往返不串账号/本地内容；raw 手机号不落盘/不进日志。
- QuickRead 严格 3+ blocks 真机验证 block0、首个正式块、文字和 TTS 均不重复；SSE/401/402/截断不伪完成。
- CN TTS 在客户端只命中第 4.4 节的精确 `.cn` allowlist，服务器侧实际代理/数据处理路径已在隐私文案与审核资料中如实处理。
- StoreKit 2 购买/恢复、账号归属和注销 revoke 关键流程通过；不在 iOS 中接支付宝。
- 中国备案号、法务链接、Privacy Manifest、账号注销、审核账号/短信策略与 App Store 元数据完成提交前检查。
- Archive/签名验证通过，上传 Build 39 后等待 `VALID`，绑定 1.2.24 的 11 个 App Store Connect locale 元数据与审核资料后才送审。

Build 39 对用户文件只做本地导入，所以 CN STS/upload/mobile documents 可用性不是本次发布门禁；门禁是反向证明 App 不会调用它们。

### 20.2 后续 Android/网盘/服务强化门禁

以下不能被忘记，但它们属于后续对应发布的 Go/No-Go，不混入 Build 39：

- Android Release 没有 `888888`、`cms_local_`、provider key、Google 无用权限/错误支付文案；手机号无 email 仍可 Pro/支付。
- Android CN 保留全部书架 + YouTube，九语、协议、手机、支付和 WebView account boundary 通过。
- 网盘启用前，mobile documents/STS/notify、20MB/TTL/跨账号/跨 route 与旧版兼容单独验收。
- Android 支付宝真实首购、回调、query、恢复、退款和幂等通过；一次性套餐不披露为自动续费。
- 新受保护 TTS 合同、服务端原子额度、Asia/Shanghai 日切和旧公开入口下线窗口按独立后端版本实施。

无论哪个发布范围，都不得用“首段能播”“短信收到过一次”“客户端只看到 .cn”或“单元测试通过”替代对应范围的端到端验收。

## 21. 运维、观测与回滚

### 21.1 可记录

- route、endpoint operation、HTTP 状态
- request id、匿名 account scope hash 前缀
- job/block index、重试次数
- 连接/首包/完成耗时
- 公共错误枚举
- plan/segment/block 数量

### 21.2 禁止记录

- 原文/解读正文
- 手机号、验证码、email
- `cms_`、provider token
- `qrc_` capability
- DeepSeek/短信/COS/支付密钥
- Alipay `orderStr`、支付通知原文
- 音频 base64
- 第三方 Cookie、localStorage、账号原始 evidence

### 21.3 灰度和回滚

- 控制面只返回 route 枚举、平台版本窗口和 TTL。
- CN route 配置先限定一个内部 build。
- 发布脚本先验证服务 route、Nginx vhost、TLS、401 边界、账本 fingerprint。
- 激活失败自动回滚到前一 release。
- 客户端回滚通过把下一启动 route 改回 global；当前进程不热切。
- 回滚不删除 CN 用户数据，避免再次测试时丢账号和书架。

## 22. 旧文档和旧注释的废止说明

以下材料仍有历史价值，但其中“当前状态”或产品规则已过期；若冲突以本文为准：

| 材料 | 已过期内容 |
|---|---|
| `docs/iOS-China-Dual-Route-Test-Plan.md` | 曾写 CN 保留邮箱；当前 CN 仅手机 + Apple |
| `docs/硬登录墙与邮箱验证码登录-双端交付.md` | 邮箱域名/session 能力与当前代码已变化 |
| `docs/中国区后端-服务器规格与上线清单.md` | “尚未部署/真实短信未通”等进度落后 |
| `docs/Pro一致性标准.md` | v1 自报 device/user/email 合同不再是新客户端目标 |
| iOS Settings 内部说明 | 仍可能写“手机号、Apple 与邮箱”或“全部本地数据完全隔离” |
| Android `AppRegion.kt` 注释 | 把 Google Books 在 CN 排除，与最新保留全部平台要求冲突 |
| Android QuickRead/TTS 注释 | 仍描述旧 `.ai:8444`、时区节点和跨线 fallback |

旧文档不删除，便于追溯；后续修改需求必须先更新本文，再同步代码和测试。

## 23. 关键代码与合同索引

### 23.1 iOS 当前基线

发布候选 commit：`2ecb07d`。以下索引对应该 commit，不是未提交工作树的模糊快照：

- `CastReader/Services/AppRegion.swift`
- `CastReader/Services/ServiceRouting.swift`
- `CastReader/Services/OwnedAPINetworking.swift`
- `CastReader/Utils/Constants.swift`
- `CastReader/Services/MobileSessionService.swift`
- `CastReader/Services/AuthService.swift`
- `CastReader/Services/PhoneAuthService.swift`
- `CastReader/Views/Auth/LoginView.swift`
- `CastReader/Views/Auth/PhoneSignInView.swift`
- `CastReader/Services/QuickReadService.swift`
- `CastReader/ViewModels/ExplainViewModel.swift`
- `CastReader/Services/TTSService.swift`
- `CastReader/Services/ProBackendService.swift`
- `CastReader/Services/ProManager.swift`
- `CastReader/Services/QuotaManager.swift`

### 23.2 后端和部署

发布候选 commit：

- `6a275aa6`：mobile auth/routing、Pro/Apple、QuickRead、CN 原子激活与账本预检。
- `3f71b023`：将构建所需的博客图片从已退役 COS URL 迁移到现有公开对象 URL。

本次 backend release closure 的关键索引：

- `/Users/xuxuheng/Documents/MyProject/readout-web/src/app/api/mobile-auth/`
- `/Users/xuxuheng/Documents/MyProject/readout-web/src/app/api/mobile/pro/`
- `/Users/xuxuheng/Documents/MyProject/readout-web/src/shared/phone-auth/`
- `/Users/xuxuheng/Documents/MyProject/readout-web/src/shared/mobile-routing/`
- `/Users/xuxuheng/Documents/MyProject/readout-web/src/shared/quickread/`
- `/Users/xuxuheng/Documents/MyProject/readout-web/src/shared/pro/`
- `/Users/xuxuheng/Documents/MyProject/readout-web/scripts/nginx-api-castreader-cn.conf`
- `/Users/xuxuheng/Documents/MyProject/readout-web/scripts/deploy-cn.sh`
- `/Users/xuxuheng/Documents/MyProject/readout-web/scripts/activate-cn-release.sh`
- `/Users/xuxuheng/Documents/MyProject/readout-desktop/scripts/video-pipeline/tools/llm-provider.mjs`
- `/Users/xuxuheng/Documents/MyProject/readout-desktop/scripts/video-pipeline/tools/extract-content.mjs`

后续云能力索引（未进本次 backend commit）：

- `/Users/xuxuheng/Documents/MyProject/readout-web/src/app/api/mobile/upload/`
- `/Users/xuxuheng/Documents/MyProject/readout-web/src/app/api/mobile/documents/`
- `/Users/xuxuheng/Documents/MyProject/readout-web/src/shared/upload-gateway/`

### 23.3 Android 当前审计入口

- `app/build.gradle.kts`
- `app/src/main/java/com/same/castreader/data/local/AppRegion.kt`
- `app/src/main/java/com/same/castreader/di/NetworkModule.kt`
- `app/src/main/java/com/same/castreader/data/remote/TtsEndpointRouter.kt`
- `app/src/main/java/com/same/castreader/data/remote/TtsEndpointInterceptor.kt`
- `app/src/main/java/com/same/castreader/data/remote/QuickReadApi.kt`
- `app/src/main/java/com/same/castreader/data/remote/CastReaderApi.kt`
- `app/src/main/java/com/same/castreader/data/remote/ProApi.kt`
- `app/src/main/java/com/same/castreader/auth/MobileSessionStore.kt`
- `app/src/main/java/com/same/castreader/data/remote/FirstPartySessionInterceptor.kt`
- `app/src/cn/java/com/same/castreader/auth/AuthManager.kt`
- `app/src/cn/java/com/same/castreader/auth/ChinaPhoneNumber.kt`
- `app/src/cn/java/com/same/castreader/ui/screens/auth/PhoneSignInSheet.kt`
- `app/src/cn/java/com/same/castreader/billing/BillingManager.kt`
- `app/src/cn/java/com/same/castreader/billing/AlipayApi.kt`
- `app/src/main/java/com/same/castreader/data/local/ProManager.kt`
- `app/src/main/java/com/same/castreader/ui/screens/pro/Paywall.kt`

## 24. 官方参考

- Apple：[App Store Connect 中国大陆可用性与 ICP 信息](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information)
- Apple：[中国大陆主体合规信息](https://developer.apple.com/help/app-store-connect/manage-compliance-information/view-mainland-china-compliance-information)
- Apple：[App Review Guidelines（登录、账号删除、IAP、审核可用性）](https://developer.apple.com/app-store/review/guidelines/)
- Apple：[App 内账号删除](https://developer.apple.com/support/offering-account-deletion-in-your-app/)
- Apple：[Sign in with Apple 注销与 token revoke](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple)
- Apple：[在 Android/网页等其它平台使用 Sign in with Apple](https://developer.apple.com/sign-in-with-apple/usage-guidelines-for-websites-and-other-platforms/)
- 工业和信息化部：[开展移动互联网应用程序备案工作的通知](https://www.gov.cn/zhengce/zhengceku/202308/content_6897341.htm)
- [DeepSeek API 文档](https://api-docs.deepseek.com/zh-cn/)

## 25. 最终交付定义

本文档现在同时承担两种责任：

1. **Build 39 发布记录**：用 commit、测试结果、双域部署状态、runtime 窗口和 App Store 状态说明 iOS 1.2.24 实际包含什么、不包含什么。
2. **Android/后续云能力交接**：保留产品、安全、网络、账号、QuickRead、TTS、支付、上传和验收合同，但不把上述后续能力伪写成 Build 39 已实现。

当前 iOS/后端候选代码已提交，双域部署与打包前验收正在进行；runtime 仍安全保持 global，尚未对 Build 39 开 CN 窗口。该状态必须随发布进度持续回写，不得再用“本轮只整理文档”的旧描述覆盖真实执行。
