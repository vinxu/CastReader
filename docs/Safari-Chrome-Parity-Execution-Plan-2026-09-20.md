# Safari / Chrome 全功能对齐与 iOS 联合发布执行计划

建立日期：2026-09-20。启动回读：专项任务已运行，用户已确认开始推进；扩展与 iOS 独立工作树已建立，P0 基线/功能矩阵正在整理，首项 H01 同步脚本修复进入复现准备。尚未完成任何新功能或真机验收。

专项任务：`01a0bcfa-6d0a-7cc3-ad2f-7ba0468febe1`（Safari 全功能对齐 Chrome 与 iOS 联合发布）。本文件保留启动范围；后续实时状态以[专项执行计划](/Users/xuxuheng/.codex/worktrees/4e15/readout-desktop/docs/safari-chrome-ios-parity-plan-20260920.md)与[逐项进度](/Users/xuxuheng/.codex/worktrees/4e15/readout-desktop/reports/safari-parity-20260920/progress.md)为准。

## 目标与完成定义

以当前 Chrome 扩展的实际功能为对照，逐项完成 iPhone/iPad Safari 扩展，并嵌入 CastReader iOS 一起交付。Safari 的账号、登录、StoreKit、Pro、额度走 iOS 的既有合同。共享代码涉及的 macOS Safari 需要回归；独立 macOS 上架不作为本轮额外交付。

优先确保 Kindle 与普通网页的朗读、解读可持续使用。朗读必须保留音频、词级高亮、自动滚动同步；解读必须播放真实讲解并在原文上同步绘制手写标注。Kokoro、社区克隆、私人克隆音色都必须覆盖实际生成与播放，不能用试听成功代替。

同时审查并修复 Chrome 的共享架构和播放缺陷，包括等待不恢复、换声串音、旧请求污染新会话、重复生成、重复播放、跨页中断和内存持续增长。以可复现证据驱动修复。

本轮最终交付是经过验证的 iOS + Safari 可安装候选、测试证据和用户验收清单。用户完成最终验证后进入正式提审与发布。

## 执行规则

1. 两个仓库各用独立工作树，核验源码祖先与发布证据后选择集成基线。不能直接使用主目录的脏状态，不能依据版本号大小选基线。
2. 每条功能先建立现状/失败证据，再实现，运行相关自动测试和真实浏览器/设备验证，通过后才推进下一条。
3. 失败必须记录、修复和复验。缺少设备、登录或真实站点材料的项目记为待验证，并继续无依赖事项，不能标为通过。
4. 所有功能都有稳定编号、Chrome 源码入口、Safari 对应实现和证据路径。共享源码、打包成功、字符串检查、模拟音频均不等于端到端通过。
5. 每阶段更新计划、逐项矩阵与证据索引，不重复请求已授权的实现/验证许可。

## 阶段与验收门槛

| 阶段 | 实施内容 | 进入下一阶段所需证据 |
| --- | --- | --- |
| P0 基线与清单 | 核实 Chrome 已发布/待发布包、Safari 当前资源、iOS 已验证发布提交；审计所有入口和能力；建立性能基准 | commit、工作树、包哈希、祖先关系、完整功能矩阵、架构风险清单、可运行验证入口 |
| P1 iOS 桥接与 Safari 能力 | target/资源、App Group、native messaging、登录/登出/切账号、购买恢复/会员/额度、两区 session；权限/CSP/MAIN world/OCR/音频限制 | 宿主与扩展一致性和鉴权验证；账号切换不串权益；iOS 包无 Web 结账及上游私钥 |
| P2 核心朗读 | 先普通网页，再 Kindle；段落起读、processedText/时间戳、高亮滚动、连续生成、分页预取、手动翻页、进度恢复、暂停/跳段/变速/失败恢复 | Chrome / Safari 同内容、同音色用例；真实分段及跨页播放；页面位置与词级高亮正确 |
| P3 核心解读 | plan/extract/compose、流式讲解、块时间线、原文手写标注、DOM/Kindle 锚定、跨页、暂停恢复与读/解读互切 | 真实 LLM + TTS + 标注闭环；块/页连续；旧请求取消后无污染；单一音频所有权 |
| P4 音色及稳定性 | Kokoro/克隆互切、克隆之间切换、暂停/生成/快速改选、试听互斥；缓存身份、取消隔离、队列/预取预算、重试去重、内存释放 | 两端同矩阵；选择音色与实际声音一致；没有意外重播、串音或等待不恢复；Chrome 缺陷修复有回归 |
| P5 全功能和长时回归 | 按 P0 清单补齐其他站点、选区、Reader/文档、LLM 页面、YouTube、设置、本地化、反馈和纠错；性能与网络抖动 | 每项有证据；核心至少 30 分钟连续真实播放；明确统计异常停顿、延迟、同步偏移和资源增长 |
| P6 联合候选交付 | 在核实的新 iOS 发布基线上增量整合；自动回归、独立 DerivedData、编译签名、嵌入资源/entitlements/App Group 核验 | 可安装候选、精确源码身份/哈希、安装和核心冒烟证据、用户验收清单及未决问题 |

P2–P5 各阶段内部仍逐条实现和验证，不把整个阶段的验证积压到末尾。跨阶段发现的核心缺陷先修复再继续受影响事项。

## 核心验收矩阵

以下仅为必须优先覆盖的矩阵，不替代 P0 的全量 Chrome 功能清单。

| 维度 | 必测范围 |
| --- | --- |
| 平台 | Chrome；iPhone Safari；iPad Safari；共用代码变更涉及的 macOS Safari |
| 场景 | 普通 DOM 长文；Kindle 连续多页；既有支持的其他特殊站点与 Reader |
| 模式 | 朗读；解读；两者互切 |
| 音色 | Kokoro；社区克隆；私人克隆；Kokoro ↔ 克隆；克隆 A ↔ B |
| 切换时机 | 正在播放；暂停；生成/缓冲中；快速连续改选；完成后重新开始 |
| 操作 | 首次起读；段落起读；跳段；变速；手动/自动翻页；停止重开；进度恢复 |
| 环境 | 全球/中国既有线路；冷生成/热缓存；网络抖动/失败恢复；产品既定前后台行为 |
| 身份 | 匿名/登录；Pro/免费；登录/登出/切账号；权益刷新；恢复购买；额度耗尽 |

记录首音延迟 p50/p95、音色切换恢复耗时、有效播放期异常断音次数/时长、句段及跨页衔接、高亮偏移、重复请求/播放、资源增长。先测真实基线再固化数值门槛。区分用户主动暂停、按需冷生成与播放器故障；记录用户实际等待，不能因分类而隐藏延迟。

## 已核实的起点与集成风险

这些是 2026-09-20 的只读观察，开始实施时必须刷新。

- 扩展主仓库：`/Users/xuxuheng/Documents/MyProject/readout-desktop`，`codex/voice-expansion`，观察到 `2f060971136c61b3b7f407a155fbbb65ed43ce80`；有大量未提交改动，主目录 package 版本仍为 1.2.32，不能直接作为功能权威。
- 较新扩展候选：`/Users/xuxuheng/Documents/MyProject/.worktrees/readout-desktop-kindle-gdocs-feedback-20260919`，观察到 `33cce3e6f699a390964a64dabb09c656137d721d`，含 1.2.44 Kindle 云修复及 Google Docs 相关记录。详见该目录 `docs/kindle-cloud-release-1.2.44-2026-09-20.md`；发布包哈希和实际商店状态仍需核对。
- 现有 Safari 文档：扩展仓库 `docs/safari-full-parity.md`。其验证记录为 2026-07-16，不能证明与当前 Chrome 一致。
- 已有 iOS Safari native 合同：`GET_ENTITLEMENT`、`GET_MOBILE_SESSION`、`OPEN_PRO`、`OPEN_ACCOUNT`、`SIGN_OUT`，共享 `group.com.same.castreader`。需要行为复验。
- 已有 parity 门禁大量检查 manifest、资源和字符串。必须补足真实 Safari/设备验证，不能按静态检查数量宣称功能完成。
- `sync-safari-ios-project.rb` 默认写主 iOS 目录，使用 `CASTREADER_IOS_ROOT`；parity 脚本使用 `CASTREADER_IOS_PROJECT`。所有调用必须显式指向本专项独立工作树。
- 旧 `release-safari-ios.sh` 有默认 Build 22，并使用 `-project`。联合发布需采用最新 iOS workspace、版本与发布门禁，不能直接执行旧默认流程。
- iOS 主仓库 `/Users/xuxuheng/Documents/CastReader` 有大量脏改动。用户 AGENTS 的 1.2.37 / `b6dd4d7` 是旧的验证基线；已发现更新发布记录，须核对祖先和实际产物。
- iOS 音色工作树 `/Users/xuxuheng/Documents/.worktrees/CastReader-mobile-voice-explore-20260914` 的 `docs/iOS-1.2.41-Release-Report.md` 记录 1.2.41(63) 的提交和两区 Read/Explain/Kokoro/克隆真机验证，也明确该包未包含未完成的 Safari 扩展。记录是历史提交回执，不代表当前商店状态。
- `/Users/xuxuheng/.codex/worktrees/castreader-ios-release-1-2-42/CastReader` 正被其他任务修改，观察到未解决合并冲突；不能修改或使用其中间状态打包。
- 保留已发布的 Kindle 位置恢复、手动翻页确认、预热书架遮挡、原生字号重排、WeRead/Kobo 恢复和播放器失败恢复；不能整文件覆盖这些子系统。

## 每条功能的记录模板

| 字段 | 内容 |
| --- | --- |
| 编号/阶段 | 稳定编号及所属阶段 |
| 用户行为 | 入口、操作、预期结果 |
| Chrome 基线 | commit / 源码位置 / 真实行为证据 |
| Safari 差异 | 实际缺失或错误，不以推测记为已确认缺陷 |
| 实施 | 方案、修改文件、提交 |
| 验证 | 命令、输入、模型/音色、线路、浏览器/设备、产物身份 |
| 结果 | 通过 / 失败 / 待验证 / 外部阻塞及证据路径 |
| 后续 | 修复复验或确切所需外部条件 |

## 最终交付清单

- 全量功能对照表，每项关联验证证据。
- Chrome/Safari 共用架构修复清单及针对性回归结果。
- 真实 Kindle / 网页 Read / Explain / 音色切换 / 长时稳定性报告。
- iOS + Safari 可安装候选、源码与包哈希、签名和嵌入检查。
- 面向用户的操作式验收清单，标明已验证范围和所有未决项。
- 用户最终验收后的正式发布步骤与回滚依据。
