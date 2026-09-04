# 核心服务迭代与验收（2026-09-04）

本轮已完成代码修改、服务器部署和下述验证：**播放第一，高亮第二；已选中国/国际线路不在两套服务之间回退；GIF 退出线上解读流程。** 身份、音色所有权、会员和业务额度保留。

**仍不能认定整个系统已经“全链路零跨境”**：国际 Supabase / R2 的物理区域和全球 LLM API 的内部推理地域尚缺控制面证明；旧客户端不会因服务器上线自动升级。本文分别列明已证明、已修复和未验收事项，不以域名限制或一次 HTTP 200 代替全链路证明。

## 1. 修复后的服务结构

| 环节 | 国际线路 | 中国线路 |
|---|---|---|
| 账号与核心 API | api.castreader.ai → 美国 Vercel iad1 / 国际账号 | api.castreader.cn → 中国 Nginx / Next / 本机 PostgreSQL |
| Kokoro | 固定美国 GPU，同节点重试 | 本机 18880 隧道 → 北京 GPU，不回退美国 |
| 克隆模型 | 美国 clone worker → 同机 Nari / Qwen3-TTS Base 0.6B | 本机 18890 隧道 → 北京 clone worker → 同机 Nari |
| 解读入口 | CMS 网关；旧匿名客户端固定 qr.castreader.ai | CMS 网关 / quickread.castreader.cn → 本机 QuickRead |
| 解读文本 | Gemini，Claude 备用；只允许国际模型合同 | 固定 DeepSeek 官方 API / deepseek-v4-pro，无国际模型回退，拒绝重定向 |
| 解读语音 | 复用本区 Kokoro / 克隆；旧整篇 TTS 固定 api.castreader.ai | 复用本区 Kokoro / 克隆；旧整篇 TTS 固定 api.castreader.cn |
| 参考录音 | 本地准备片段 → 国际 multipart → 美国建声 | 本地准备片段 → 本区 STS → 上海标准 COS → 北京建声 |
| 降噪 / prompt | 同机 DeepFilter 固定 atten24 一次，构建 x-vector prompt，逐段复用 | 相同本区处理；不是每段朗读都重复上传、降噪、建声 |
| 参考 / prompt 存储 | 加密 Supabase，实际物理区域待证明 | 私有上海 COS，账号前缀隔离，禁止 accelerate / 任意 endpoint |
| 文档与音频缓存 | 国际文件服务 / R2；R2 源桶区域待证明 | 本机转换 / 文档数据库和上海 COS；旧上传接口不再代理国际站 |
| 辅助限流与额度 | 国际服务自己的依赖 / 国际额度接口 | 本机 PostgreSQL；不走外部 Redis / Upstash；解读额度调用本机 Next |
| GIF | 不搜索、不下载、不上传；旧任务返回时也清理 GIF 字段 | 相同 |

这里的区域隔离指已选 CN/Global 后，正文、参考录音、prompt 和音频不被后台改送另一套区域。两区架构不等于全球每个国家都有本地服务；供应商全球 API 的内部调度也不是仅凭入口域名就能证明的。

## 2. 已修复的具体原因

### Kokoro：辅助元数据曾丢掉已经生成的声音

Kokoro worker 曾把预测时长、PCM 时钟、词区间和 source mapping 的校验作为音频成功条件。网关清空坏 timestamps 无法挽救 worker 在回包前抛出的异常。

R131b 保留真实 PCM，坏时间戳降级；失败的完整正文单元只在提交音频前重试，不重复前缀、不截尾、不换音色。超长音素完整拆分，KPipeline 复用选定模型，避免隐式重复加载默认模型。真实空音频、编码失败或持续模型不可用不会被伪装成成功。

59 项测试及真实 PCM 故障注入通过。1,074 phones 完整拆成三块，生成 60.7 秒音频，即使无可用时间戳也不漏正文。新增安全请求日志只记阶段、数量和异常类型，便于后续定位；不能倒推把过去 26 条缺少内部因果日志的全球 500 全归因于时间戳或 OOM。

### 克隆：Kokoro 的健康检查曾连带重启另一条管线

中国旧 watchdog 在 Kokoro `/health` 2 秒超时后调用 `stop_children`，重启 Nari 和 clone。04:01:36Z 的现场事件中，GPU 仍有 8,141MiB 空闲，Kokoro PID 未变；历史日志也有同类行为。该次事件发生在本轮隔离候选测试期间，不能写成整卡 OOM 或“测试没有影响生产”。

现已删除三处错误依赖，保留各服务自身健康恢复和原 GPU 保护；四项真实 shell 模拟通过。维护按顺序停止接收、排空、正常退出旧监管进程，没有永久冻结旧监控或 KILL。

克隆供给维护窗口为 04:23:52.514Z–04:24:22.930Z，实测 **30.42 秒**。随后 Kokoro 实际切换的 55.48 秒内，clone PID 639681 / Nari PID 639323 均未改变，验证了解耦。这里不宣称零停机维护。

### 解读：标注、缓存、GIF 和错误分类曾影响声音交付

- GIF 搜索、下载和 COS 上传不再被线上 server 调用，`/gifs` 兼容接口固定返回空列表。旧 job 恢复后，也在三个响应出口清除 GIF 字段；历史正文、音频、截图和磁盘快照保留。独立离线视频工具里的旧文件不代表线上流程仍使用。
- 标注在本地按音频时间线安排，不再等待另一次 LLM 调用；整篇 compose 不进入模型生成队列。网关对有效身份和 job 绑定下的标注超时、5xx、元数据缺失，在两秒预算内返回有效空标注。
- 坏 timestamps、可选缓存写入、元数据持久化和 ffprobe 时长探测失败不拒绝已有音频。真实多段 MP3 合并仍需 ffmpeg，两机依赖已补齐。
- 移除额外的每分钟 30 / 每小时 600 次技术请求计数。沿用原服务容量，等待额度接口时预留队列位置，入队后立即释放，避免已扣量后再因排队竞争拒绝。续块和标注不增加这层新会话准入。
- 内部额度接口的非 2xx、坏 JSON、缺少判定属于服务故障，按既有策略放行；只有有效的明确 `allowed:false` 才拒绝额度。用户 API key / CMS 身份、所有权校验仍单独保留。
- 三个新会话入口先校验正文与容量再消费额度。fast-block0 不额外扣量，extract-block / compose-block / compose 不扣新会话额度。长文跨批次建立新 job 仍沿用原计费口径，本轮未改免费量或计费政策。
- 中国 QuickRead 原缺内部额度凭据，现复用本机正式 Next 的现有凭据，未轮换；真实本机额度验证通过。国际服务继续从原私有 `.env` 读取凭据，真实国际额度只读请求也通过。
- 活跃有效 job 续块后台延长两小时空闲期；本机原子快照支持重启恢复。没有接受过期账号认证，也没有用资产读取无限续期。

### Android：任意段数上限与吞异常曾静默截断内容

七个解读入口已共用续传实现，取消 24 段硬截断，按服务端余文继续；保留未送出的原文尾部，不拿展示文字、字母数量或时间戳猜测是否读完。已生成音频不会因为正常的空白、连字符或标点规范化而被拒绝。

临时网络/容量失败在原区域、原音色、原输入内有限退避；明确业务拒绝和取消保持原语义。持续失败不会把部分内容冒充整段完成，内部异常文字使用已有本地化提示。未重写播放器或新增技术检查页面。

## 3. 当前部署与提交

| 组件 | 当前版本与状态 |
|---|---|
| 国际 API / Web | 正式 `2d5575b6`；Vercel `dpl_2CmzKBRfAMhhKYiVF6DwUjnakPRn`，iad1；保留同期增长功能 `5e69d2cc`、`4720b4cf` |
| 中国 API / Web | 正式 `62386e902cb7201919e9680e56c82c8627b47110`，`release-20260904120513`；正规 PR #19、#20 合入 beta 后发布 |
| 两区 Kokoro | R131b；运行源码 `4eee2f9`，证据提交 `77daa03`；US 04:08:10Z、CN 04:25:57Z 完成切流 |
| 国际 QuickRead | `20260904-quickread-gif-retirement`，源 `5728d1c`，PID 507570；05:02:19Z 完成 |
| 中国 QuickRead | 同名 release，源 `5728d1c`，PID 1067993；05:04:24Z 完成；环境按原子事务更新 |
| iOS | 本项目 `a1ee5f0`，146 项模拟器测试通过，未送审或安装到用户手机 |
| Android | 区域修复 `14b884b` + 连续朗读 `91e3040`；两区可覆盖安装的签名测试 APK 已生成，未发布商店 |
| 扩展 | `8681577`；可加载 Chrome 包、Safari JS/资源已生成，未发布商店 |

时间为 UTC，北京时间加八小时。两区 QuickRead 均从各自实际生产源码打补丁，保留 US 串行和 CN 并发 3 的差异。代码、模型、配置及部署回执都有对应私有备份和全量下载 SHA-256 核验；中国恢复物料在上海，不依赖国际副本。US 使用既有国际私有 Supabase 备份，其物理区域仍须控制面核验。

中国 Web 首次激活发现旧 `27-cn-tts.conf` 覆盖正确地址，被原检查拒绝并自动回滚；随后纳入配置事务再正常发布。没有绕过源码 HEAD、计费、schema 或 TTS 健康检查。最后一轮 CN 隔离候选曾因继承 PORT=7777 而绑定失败，调整为载入配置后固定候选端口 17777，再完成验证；这一失败未替换正式服务。

## 4. 已取得的真实验证

| 验证 | 结果与范围 |
|---|---|
| US Kokoro 正式短文 | 真 MP3 51,885B、77,760 samples、尾词和 requestId 一致；clone / Nari 未重启 |
| CN Kokoro 连续多语 | 同一个正式进程 15 例全部 200：六个英文音色 + zh/ja/de/es/fr/it/pt/hi + 长文；无未读尾文 |
| CN Kokoro 长文 | 4.118 秒生成 64.8 秒音频、167 cues、末词 sunflower；最低空闲 GPU 9,430MiB |
| 国际公开 Hindi partly | hf_alpha 两段完整循环 3.041 秒；真实音频 2.568 + 3.432 秒，remaining 35→0，均为 global / castreader-us4090 |
| 中国克隆恢复 | 中性本地合成参考建声；旧测试音色重启后继续生成，新建测试音色也成功；两者已删除并确认目录不存在 |
| 国际 Web TTS | 正式短文 200 / 4.584 秒音频；同制品候选长文 88.368 秒、208 cues、末词 narration |
| 两区完整解读 | 正式进程本机 HTTP：US 200 / 5.232 秒，CN 200 / 11.333 秒，各五节；真实音频可取回 |
| 最终两区服务 | 35 次同来源空输入均 400、无额外技术 429；缺 key 401；坏 timing compose 200；GIF 为空；旧任务恢复 5 / 4 节 |
| CN 最终真实额度 | 初始 0/3；无效请求及错误 key 不扣；真实 plan 后为 1；同 job extract/compose 后仍为 1；另一诊断额度满 3 才 402，升级地址为中国站；诊断记录已清理 |
| 并发与 GIF / redirect | 36 项回归通过；11 项准入场景分别运行在两区最终源码；旧快照 GIF 响应清理、DeepSeek 307/308 目标零请求通过 |
| 中国文档公开全链 | 旧 EPUB、新 CMS PDF → 本地转换 → Markdown → TTS 均通过；Range206、删除后404、外区Markdown403、无/外区CMS401；Nginx global 引用为0 |
| Android | 区域阶段 Global1517/CN83；最终续传阶段 Global51/CN54，通过且无跳过；两区同一18项续传用例通过；APK 签名及ZIP对齐验证通过 |
| 扩展 | 393 条 Chromium 断言 / 46 场景及相关合同测试通过；内联音频不依赖可选缓存；Global key存在，CN key不打包 |

Hindi 本轮验证的是代表音色 hf_alpha，不能扩展成全部 20 个音色都已逐个验证。国际公开克隆网关的真实登录建声全链测试，也不能由匿名401或capabilities成功代替。

## 5. 客户端与未验收边界

- iOS 权威 CHN 区域不会因旧配置缺失、过期、损坏、返回 global 或 Build 越界而改走国际；先准备区域再冻结服务，随后才创建 Analytics/Auth/Pro 和 UI。14 个初始化相关文件比对一致，146 项测试通过。显式内部选区保留；首次安装完全没有 Storefront 证据时仍保留现有默认规则。
- Android 的账号、文件、普通音色、克隆、解读服从发行区域，不再独立按 SIM/时区/远端配置选 compute。Global 原有匿名解读保留，既有 job 不因登录变化换入口，CN 不携带国际 key。
- 普通桌面扩展保持既有 global 产品合同，移除 GeoIP 双区探测、COS QuickRead 配置及跨账号区恢复；iOS Safari 保持原生冻结区域。Safari JS/资源合同通过，但当前 iOS 项目没有 Safari target，完整原生集成没有验收，默认完整检查也未跳过此前置条件。
- 客户端源码修复需要安装新包；本轮未替换用户手机、未提交 iOS/Play/扩展商店，未代替用户设备上的 Kindle 翻页长时播放回归。
- 国际 Supabase / R2 的物理区域和 LLM 的内部处理地域仍需供应商控制面证据。已请求区域设置页，不需要提供密钥；取得证明前不宣称全链路零跨境。
- 真实、持续的网络/GPU/模型不可用仍可能影响供给。本轮消除的是已证实的技术误拒、跨区回退和内容截断，不以空音频、漏读或换声掩盖不可用。

## 6. 可追溯证据

- [跨仓库代码与证据提交索引](/Users/xuxuheng/Documents/CastReader/reports/backend-core-commit-index-20260904.md)。
- [修复前审计](/Users/xuxuheng/Documents/CastReader/reports/backend-core-audit-20260904.md)与[原始问题实证](/Users/xuxuheng/Documents/CastReader/reports/backend-core-evidence-20260904/README.md)。
- [最终 QuickRead 部署、配置与备份清单](/Users/xuxuheng/Documents/CastReader/reports/backend-core-evidence-20260904/iteration/retired-gifs/quickread-final-rollout.json)。
- [Kokoro / watchdog 区域备份索引](/Users/xuxuheng/Documents/CastReader/reports/backend-core-evidence-20260904/iteration/kokoro/regional-backup-index.json)。
- [Android 最终验证](/Users/xuxuheng/Documents/CastReader/reports/backend-core-evidence-20260904/iteration/android-continuation/validation.json)、[测试包回执](/Users/xuxuheng/Documents/CastReader/reports/backend-core-evidence-20260904/iteration/android-continuation-apks.json)、[扩展验证](/Users/xuxuheng/Documents/CastReader/reports/backend-core-evidence-20260904/extension-regional-continuity-20260904.json)。
