# CastReader Codex 插件：首版交付与后续接入

## 首版边界

第一版围绕两种完整结果：开发可运行的语音功能；生成可播放音频，并处理费用和原任务恢复。插件 ID 为 `castreader`，Git 市场为 `castreader`。托管 MCP、OAuth、OpenAI 公共目录、应用听读是不同的后续接入环节，不把一个环节完成写成全部完成。

## 已交付

- 公开源代码与 Git 市场：<https://github.com/vinxu/castreader-codex>。
- 版本与归档：<https://github.com/vinxu/castreader-codex/releases/tag/v0.1.0>，包含插件 ZIP、市场 ZIP 和 SHA-256。
- `build-voice-app`：可运行 Node.js 音频卡片应用；可迁移到既有框架的后端、播放器、计划和恢复示例。
- `generate-audio`：无额外依赖的 Node 22+ 命令，显式语言、准备好的音色、实时估算、费用上限检查、区域固定、持久化幂等键、原任务轮询、二进制音频检查与实际费用回执。
- 已从公开仓库运行 `codex plugin marketplace add vinxu/castreader-codex` 和 `codex plugin add castreader@castreader`；已用安装缓存中的脚本创建新应用。
- 本地实现与示例共 28 项测试通过；官网相关契约与 SEO 元数据 15 项测试通过。官网生产构建通过。
- 真实 MP3 与 WAV：相同 55 字符英文输入，Rowan，中国处理区，分别 $0.000440，合计 $0.000880。MP3 5.016 秒，WAV 4.968 秒；ffprobe 与完整 ffmpeg 解码通过。文件检查不代表母语发音或音质评审。
- 插件与两个技能的结构验证通过。示例安装官方 SDK 0.2.2 成功；本地界面及语言切换通过。

费用上限是提交前对实时估算的检查，当前 API 不提供客户端预算锁价接口，不能把该检查宣传为跨未来调价的硬计费保证。恢复过程中保留原请求身份，不用新的付费生成掩盖未知状态。

## 官网和 SEO 资产

主落地页：`https://voice.castreader.com/integrations/codex`，中文版本 `?lang=zh-CN`。

| 资产 | 用户要完成的任务 | 已实施内容 |
|---|---|---|
| Codex 插件落地页 | 了解、安装、开始使用 | 两种结果、准确安装命令、API Key 设置、费用/恢复、功能边界、支持入口 |
| 可播放证据 | 判断实际输出是什么 | 本轮真实 MP3、原文、实际费用、下载与哈希回执 |
| 机器可读入口 | 编程代理发现准确契约 | integration-manifest、llms.txt、llms-full.txt 的插件入口 |
| GitHub 市场与版本页 | 安装、核验源码、更新 | 稳定插件名、版本 tag、归档及哈希、明确目录状态 |
| 现有 AI 接入指南 | 从通用评估进入 Codex 工作流 | 新增插件链接，修正此前“无原生插件”的陈述 |
| 站点技术资产 | 搜索引擎理解双语页面 | canonical、hreflang、站点地图、SoftwareApplication、站内链接 |

搜索意图：`CastReader Codex plugin`、`Codex text to speech`、`generate audio with Codex`、`add TTS to app with Codex`。这些是定位假设，不是假装已经从 GSC 验证的需求或排名。

首轮只新增一个完成实际任务的落地页，复用现有可运行教程和 API 文档。先观察该页的索引、页面×查询、国家/设备、安装入口访问和首次成功生成，再决定是否需要独立教程页。不为关键词变体批量建页，不改动主站冻结的 Kindle/Claude/朗读页面。

指标：落地页访问 → GitHub/安装入口 → 安装后使用 → API 开通 → 首次成功生成 → 同任务恢复成功率。现有网站浏览与后端使用量可提供部分信号；本地插件没有遥测，因此当前不能准确串联个人完整漏斗。不要声称已实现用户级归因。后续若增加可选遥测，先明确披露数据与退出方式。

## OpenAI 公共目录

公开 Git 市场可安装不等于 OpenAI 官方目录已上架。发布包已备齐两项技能、所有引用脚本/模板、描述/图标/政策链接、三条起始提示词，以及五个正向、三个负向用例。

2026-09-16 已通过用户登录的 Brave 核对 `CAST AI PTE. LTD.` 的 Business 身份为 Approved，并上传 **0.1.2** 技能插件包。官方草稿已创建：<https://platform.openai.com/plugins/plugins_6aaaa52666208191b7e575b264f338a9/submissions/appsub_6aaaa5266d348191ba6a775f6aa349fc>。已保存插件说明、支持/隐私/条款地址、三条起始提示词；两项技能扫描均显示 **Passed**，提交页不再显示技术问题。用户随后自行完成最终提交。2026-09-16 22:37（北京时间）经 Brave 回读，平台版本列表显示 **0.1.2 Published**，版本详情显示 released。公开目录页已打开并核对名称、公司、版本、两项技能及 Install plugin 按钮：<https://chatgpt.com/plugins/plugins_6aaaa52666208191b7e575b264f338a9>。官方目录已发布；新用户安装与首次实际使用仍需单独验收。

公开 Git 市场已推送 0.1.2，提交 `54209462b651b6ffa3d8d41914efd4427ba3eaea`；版本归档：<https://github.com/vinxu/castreader-codex/releases/tag/v0.1.2>，包含插件 ZIP、市场 ZIP 和 SHA-256。该 Git 发布状态与官方目录状态分开记录。

本次本地验证：12 项 CLI 测试、18 项示例应用测试，以及插件和两项技能的结构校验通过。SDK 0.2.3 下载 SHA-256 与已知官方包一致。0.1.2 调整已验证公司名、30 字符内的短描述，并修正中国区 API 文档地址。提交 ZIP 的 SHA-256 为 `bbf406d087ece485922ba3950a7a5f04fabb0394f48a4443e2d3ccc251d8dff4`；此处本地检查不等于平台扫描或人工审核通过。

## 第二阶段：托管 MCP 与 OAuth

### 服务边界

在现有 Voice API 独立项目中接入稳定 HTTPS MCP 入口，复用 `clone-v1`、原区域路由、队列、额度和账本。代码复用首版的输入/费用/恢复规则；持久状态改为服务端数据库，不能使用无持久性的函数本地磁盘保存关键任务身份。

| MCP 工具 | 最小输入/输出 | 行为 |
|---|---|---|
| `voice_get_capabilities` | 当前语言、格式、限制、价格版本 | 公开配置查询 |
| `voice_list_voices` | 过滤/游标 → 可用工作区音色 | 现有音色列表可能初始化内建引用，不能标为绝对只读 |
| `voice_estimate_audio` | 文本/语言/音色/格式 → 有效期、费用与试用量 | 不生成；不作锁价保证 |
| `voice_create_audio` | 已授权计划、稳定操作 ID → job/status | 会产生用量；并发重试唯一操作映射至同一原生任务 |
| `voice_get_audio_job` | 操作 ID → 状态/费用/恢复提示 | 核验当前主体及区域 |
| `voice_get_audio_result` | 成功操作 ID → 可播放结果/受保护下载 | 不重新生成；链接有受控有效期和权限边界 |

工具返回精简结果，不向模型回传 API Key、邮箱、内部账本或存储路径。写入、开放范围、不可逆费用等注解按实际行为设置。音频 UI 可后加，基础工具应在无嵌入 UI 的客户端也有用。

### OAuth 接入

现有 Google 登录是 CastReader 登录手段，不等于可以给 Codex 签发 OAuth 访问令牌。采用维护中的 OAuth 2.1 实现，支持授权服务器与受保护资源发现、PKCE S256、准确的 resource/audience 校验、精确回调地址、短期 access token、refresh token 轮换/撤销。

授权时选择现有工作区/项目，明确地区和 `voices:read`、`speech:generate`、`usage:read` 权限；令牌绑定 canonical user + workspace + project + region。每次操作重查成员和封禁状态。MCP 服务器所在机房不能代替用户或资源的处理区域。不得把插件用户映射到运营者共享 Key。

验证必须覆盖：真实数据库的租户隔离、scope 越权、audience/回调错误、PKCE、过期与撤销、并发重复调用、断流与重连、部分费用失败、下载过期、区域不切换，以及真实 Codex 连接后的工具扫描与生成。OAuth 未通过这些检查前，不在插件清单发布虚构 MCP 地址。

### 发布衔接

在同一 `castreader` 品牌版本升级中加入 MCP；公开目录选择 With MCP，部署域名挑战、配置审核账号、Scan Tools 后检查真实工具元数据和技能快照。导入技能是审核时快照，发布后修改源码不会自动更新目录版本。

## 第三阶段：应用听读统一入口

品牌和账号入口统一，权益保持明确：Voice API 钱包用于开发者生成；App Pro 用于应用听读。先交付可核验的文档导入、阅读会话、音频/原文高亮与手机接续，再暴露 `reader_create_session`、`reader_get_session`、`reader_explain_passage` 等工具。

现有本地阅读进度不等于已完成跨设备云端同步；不得把旧版发送手机页面宣传为可靠的云文库。服务端会话、访问控制、持久文档、进度同步、链接/深链和 App 验收全部完成后，才能在插件落地页将“应用听读”改为已可用。

## 官方参考

- <https://developers.openai.com/plugins/build/plugins>
- <https://developers.openai.com/plugins/build/auth>
- <https://developers.openai.com/plugins/deploy/submission>

发布细节与正式域名验证结果记录于 Voice API 源码仓库的 `docs/voice-api-codex-plugin-release-2026-09-15.md`。
