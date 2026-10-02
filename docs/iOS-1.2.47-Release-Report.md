# iOS 1.2.47 发布记录

## 2026-10-02 更新说明修正，原 Build 71 已重新进入等待审核

**2026-10-02 09:44:29 CST，保留 App 1.2.47（71）重新提交原审核单；09:44:55 API 回读 App version 与 Review Submission 均为 `WAITING_FOR_REVIEW`。** 额度内购 `ai.castreader.clone.minutes120` 也回读为 `WAITING_FOR_REVIEW`，页面展示同批两个项目均等待审核。仍为审核通过后自动发布，尚未获得批准。

本次拒审仅指出 Guideline 2.3.10：What's New 包含 Google Play 提及。用户明确选择修正文案并回复 Apple，继续审核原 Build 71；`520bf60` 及后续二进制改进留待当前版本通过后的新包。没有重新编译、上传、替换 Build 或合并应用代码。

- 只修改全部 11 语 `whatsNew`，移除各语言的 Google Play 名称并保留其余内容；保存前后快照，逐字段确认每个本地化的其他属性完全一致。现行文案源为 [AppStore-Whats-New-1.2.47.json](AppStore-Whats-New-1.2.47.json)。本地 1.2.48 文案草稿同步删除同类提及以避免复发，未写入 ASC 新版本。
- 09:43 在 App Review 消息中回复，说明全部 11 语已修正、仍使用 1.2.47（71），请求按其 bug-fix 流程继续审核。页面出现第 3 条消息，已确认发送成功；随后点击“更新审核”和“重新提交至 App 审核”。
- 原 App version `138a0a05-56de-42f7-b841-31fdfb842418`、原审核单 `e0120f7a-1331-468f-adb9-0b1f045c352a`、两个原 review item ID 与关联对象均保留。Build 仍为 `7356c4a6-2426-4e2e-ac96-c55e7d78c65f` / **71 / VALID**。重新提交时间为 `2026-10-02T01:44:29.656Z`。
- 元数据修正不改变原二进制及其既有验收记录；本轮没有新增真机测试结论。此前测试边界及用户授权例外仍详见下方 Build 71 记录。没有改动标题、副标题、截图、审核联系方式、价格、订阅、地区、隐私或法律声明。

[查看审核单](https://appstoreconnect.apple.com/apps/6757636395/distribution/reviewsubmissions/details/e0120f7a-1331-468f-adb9-0b1f045c352a)；[最终 API 回执](../reports/ios-release-1.2.47/metadata-review-20261002/final-readback.json)；[内购状态](../reports/ios-release-1.2.47/metadata-review-20261002/iap-final-state.json)。API 的 review item 内部状态为 `READY_FOR_REVIEW`，与顶层审核单的 `WAITING_FOR_REVIEW` 分别记录，不混用字段。

本轮依据 [iOS 发布技能](/Users/xuxuheng/.codex/skills/submit-castreader-ios-to-app-store/SKILL.md) 完成元数据修正和状态回读；Apple 的[回复审核消息说明](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/reply-to-app-review-messages)说明，元数据问题可继续使用相同构建版本。

以下为先前提交的历史记录，状态按记录时间理解。

## 2026-10-01 Build 71 已重新提交审核

**2026-10-01 00:10:52 CST，App 1.2.47（71）、同批额度内购及原 Review Submission 均已回读为 WAITING_FOR_REVIEW。** 审核通过后自动发布（AFTER_APPROVAL）；当前状态不表示已经通过或上线。

Build 71 于 00:04:14 经官方 Xcode 上传成功，errors/warnings 均为空；Apple 处理为 VALID / APP_STORE_ELIGIBLE，usesNonExemptEncryption=false。保留原版本、原审核单与两个原 item，换绑新 Build，将被拒 App item 标记已解决后重新提交。没有创建重复版本/审核单，没有移除或重建 IAP。

- Build ID：`7356c4a6-2426-4e2e-ac96-c55e7d78c65f`，71 / 1.2.47。
- App version：`138a0a05-56de-42f7-b841-31fdfb842418`，WAITING_FOR_REVIEW。
- Review Submission：`e0120f7a-1331-468f-adb9-0b1f045c352a`，WAITING_FOR_REVIEW；重新提交时间 `2026-09-30T16:10:52.181Z`。
- IAP：`6816697780` / `ai.castreader.clone.minutes120`，WAITING_FOR_REVIEW；IAP version `f267f0a8-d537-4fa7-9cc1-1796fc44b71c` 保留。

[查看原审核单](https://appstoreconnect.apple.com/apps/6757636395/distribution/reviewsubmissions/details/e0120f7a-1331-468f-adb9-0b1f045c352a)；[最终 API 回执](../reports/ios-apple-signin-review-20260930/resubmit71-final.json)。

9 月 30 日拒审原因是 Guideline 4：Apple 登录入口只是 44×44 圆形图标，其他主登录按钮为 50pt 高的整行按钮。修复使用原生 `ASAuthorizationAppleIDButton`，完整文字、同宽同高、显示在主登录区域第一项，保留中国区协议同意与现有授权回调。

发布范围冻结为登录修复 `2f89c00` + 用户指定四平台改进 `d390c0d8347723abd3fcbd221efed64d9994bc2d`；[PR #3](https://github.com/vinxu/CastReader/pull/3) 已正式合入 main。归档提交 **`2cf246a3a01ee191d376270eb392a95334e44853`**；422 个应用/组件/WebReader/工程文件与最终回归候选逐一一致，源码摘要 `8bdfdec85cc3149e156e55c94f4f4dea5f51dd72eda85bfe09e22550e5d0e77f`。App、Share、Widget、Safari 全部为 **1.2.47（71）**。没有纳入另一个 agent 仍在测试的后续改动，没有覆盖其真机。

合包回归 **26 PASS、0 FAIL、0 SKIP**：25 项 AppRegionTests + 1 项登录 UI 用例，覆盖 iPad Air 11-inch (M3) / iOS 26.5 的英文、德文、中文横竖屏，同宽同高、无需滚动可见、完整标题及中国区协议弹窗/拒绝。最终结果 `/tmp/CastReaderAppleSignInIntegrated71-20260930.xcresult`。早期旋转坐标采样失败已修复测试等待时序，未放宽断言。WeRead 合约/恢复、发布祖先和 Safari 静态资源检查通过。完整证据见 [拒审修复记录](../reports/ios-apple-signin-review-20260930/validation.json)。

**用户于 2026-09-30 明确要求当前候选直接合包送审，剩余问题下版迭代。** 本次最终候选 CN/Global × Read/Explain × Kokoro/clone（vl_/vc_）完整矩阵为 **NOT_RUN / USER_AUTHORIZED_RELEASE_EXCEPTION**；该次授权不改变后续版本默认门禁，不把 9 月 29 日 Build 70 的历史 PASS 冒充本包最终验收。延期项目包括 WeRead 原始词时间缺失（估算字幕）、Google 跨章节 8.543 秒冷启动、Kobo 真人验证阻断、四平台长时/iPad 验收缺口，以及 iPhone 小屏和真实 Apple 账号授权检查。

正式归档位于 `/Users/xuxuheng/Desktop/CastReader-1.2.47-71-Review/CastReader-1.2.47-71.xcarchive`。四组件版本/设备族 1、2/团队/严格签名通过；九语各 1,520 个编译 key；205 文件、54 个夹具标志扫描 0 命中，Debug 阳性对照通过。Safari content.js 摘要 `192e07f0e15b8ce27ec088b2e62e17ecdb5a9491235e8b2243153e523d333a75` 与已发版一致。归档使用开发签名，官方 export 完成商店分发签名与上传，不将归档 get-task-allow 冒称最终分发权限。归档清单摘要上传前 `31d3af3bba106a8605efe6ca1f3af021594a05e810d82a857a7d2921f408ab69`、上传后 `90d4d9df635e17d826387b264db71e8f54b4584c6e83d1eb0c85bdf91bcdfa46`；仅根 Info.plist 新增官方分发记录，App 和扩展全部原文件不变。原 Build 70 归档保留。

11 语 What's New 在原文后追加登录与四平台改进；审核备注更新为 3,833 字符，明确 Build 71 / Guideline 4 修复及验证入口。以上字段已写入并回读一致；其他版本文案、审核联系人/账号资料均保持原样。最终 ASC audit 为 0 errors：11 locale、原标题/副标题保持，55 张截图全部 COMPLETE（9 语 iPhone 45 张 + 中英文 iPad 10 张；zh-Hant、es-MX 沿用主语言回退）。内购、价格、地区、隐私、年龄及法律声明未改。发布方式保留 AFTER_APPROVAL。原始私有快照与构建日志位于 `/Users/xuxuheng/Desktop/CastReader-1.2.47-71-Review/evidence/`，不提交凭据或审核私人资料。

以下为 2026-09-29 Build 70 的原始提交记录，审核状态仅在原时间有效。

状态：**已于 2026-09-29 12:46:34 CST 提交，App 1.2.47（70）、额度商品和 Review Submission 均为 WAITING_FOR_REVIEW。** 审核通过后自动发布；此状态不表示已经审核通过或上线。

## 发布身份与范围

从 App Store 1.2.46（69）、main `9eb758b` 增量整合 Pro 克隆音色额度购买、Kindle 原生 BLOB 页序与跨页整句/预取修复。保留 Safari、Share、Widget、阅读位置恢复和其他已发布子系统。四组件均为 1.2.47（70）。发布 PR：<https://github.com/vinxu/CastReader/pull/2>。

验收源码 `60ec3823844e429c9b3dc224be5164cd8f399849`；416 个应用/组件/WebReader/工程文件冻结摘要 `9f2ee75b8b30cddc7aef445517d6c49cdca3a535d175ab6c6dc3148514f76b5c`。12:20 逐文件复核 0 变化。`build-voice-toc-integration.sh --check` 全部祖先门禁通过，包含发布基线 b6dd4d7 与既有导航/插图/播放实现。此后报告和审核资料更新不改变验收应用。

设备为 iPhone 15 Pro Max，iOS 26.7（23H24）。本轮按用户要求仅使用真机和镜像，没有使用模拟器。正常 Debug 包禁用 Debug Pro，两区使用真实服务端账号/接口；12:05 安装相同源码开发签名 Release 包，未传测试参数。尚未声称实测 App Store 分发签名包。

私有原始证据统一位于 `/Users/xuxuheng/Desktop/CastReader-1.2.47-Release/evidence/`。该目录误删后已由用户授权从 Finder 回收站原样恢复，期间产生的续验文件也已保留并合入，无覆盖冲突；不提交会话、收据、密钥、私有正文。

## 两区核心服务

| 地区/语言 | Read Kokoro | Read clone vl/vc | Explain Kokoro | Explain clone vl/vc |
|---|---|---|---|---|
| CN / 中文 | PASS | PASS / PASS | PASS | PASS / PASS |
| Global / 英语 | PASS | PASS / PASS | PASS | PASS / PASS |

Global：英文自有 Shortcut Text，19 段、1,400 字符，指纹 `3c53af97e197f6b1`。常规 `af_bella` → 社区 `vl_d1efb23a380bdaa2f6b0` → 私人 `vc_62934fe77f764051aa341b4b076bbb85` → 常规，均有新生成、实际播放推进及词高亮/滚动。暂停时换声先准备而不抢播，显式继续后推进。英语新 QuickRead 作业 `qrc_axCdCTGKuI_aH6QhbTGeVZS137A_6jBQ`，六块讲解，实际走 `api.castreader.ai`；各声音播放讲解并推进下一块，原文高亮/下划线可见，切回 Bella 完成。证据：`global-final-core-console-r2.log`、`reader-log-global*.log`、`live-ui-observations.json`。

CN：中文自有 Shortcut Text，5 段、491 字符，指纹 `e4cbc325f46c8462`。常规 `zf_001` → 社区 `vl_65b2c4daaea282b057a7` → 私人 `vc_63a448ca35794f57b0aea0e189a68cb3` → 常规，两种模式均新生成并实际播放；朗读句段高亮/连续跨段有效。11:54:05 新 QuickRead 计划生成三块中文讲解，使用现有短块等价管线，讲解与原文不同；有效阅读/主动回忆高亮、中心意思圈注和工具段下划线可见，社区/私人均推进下一块。切回常规后最后一块 12:04:24 完成。TTS/账号走 `api.castreader.cn`，QuickRead 走 `quickread.castreader.cn`。CN 作业 ID 未从中断的 console 留存，不编造；reader 中新计划及块身份、实际音频/产品效果保留于 `reader-log-cn-final-r2.log` 和分阶段日志。

12:02 私人解读已准备音频重播自动推进，前/中/后三次账本均为 50 笔成功、288,888 ms，无新扣费。11:47 一次本机使用手机引起系统音频中断，恢复后位置保留，单列外部中断，不记作应用自动停顿。当前声音均为 warm；冷准备、迟到响应、快速切换、未知额度和失败恢复由确定性测试覆盖，不声称生产冷启动实测。

Release 配置补验：12:06 社区朗读跨段至完成；12:07 私人声音重新生成，12:08 实际播放连续推进 0→12 段并高亮/滚动；12:09 新英语解读六块，私人声播放至 Part 2、Part 3，原文圈注/高亮同步。`release-final-console.log` 记录 voice ID、新音频时长/就绪和播放完成，`live-ui-observations.json` 记录界面观察。Release 的 DEBUG reader 文件日志关闭，`reader-log-release-final.log` 仍止于 CN 12:04，不将其冒充 Release 播放日志。签名严格验证、204 文件/54 标志夹具扫描为 0 命中，Debug 阳性对照有效；内部控制关闭，无 RepositorySnapshot，Safari content.js 摘要 `192e07f0e15b8ce27ec088b2e62e17ecdb5a9491235e8b2243153e523d333a75` 与已发版一致。

## Kindle 验收

Kindle 合入来源 `bbe7ef7`：114 项受影响真机测试通过；实书连续自动呈现 8 个下一页，23 次 AVPlayer 切换中位 168 ms、最大 243 ms，没有 >600 ms 样本；31 次 TTS 请求无重复。覆盖克隆→Bella、暂停、手动 Next/Previous 往返和字号重排。原生 Map 页面索引、书籍 epoch/渲染所有权校验、相邻页与跨页句子映射避免旧 BLOB 错配；预取随声音和位置失效。详见 [Kindle 真机记录](Kindle-原生缓存页序与真机验收-2026-09-29.md)。事件间隔不是声学静音测量，也不保证任意网络绝对零停顿。最终整合未改动这部分实现，复用证据并通过最终真机回归。

## 额度购买与成本

有效 Pro 可在正余额或零余额购买，每月包含 120 分钟；120 分钟消耗型内购，月额度优先，购买余额不失效，Pro 到期保留购买余额。仅成功新生成按实际时长结算，缓存重播/固定试听不扣费。商品 `6816697780`，SKU `ai.castreader.clone.minutes120`，价格保持 CN ¥18 / US $2.99。

两笔真实 Apple Sandbox 购买各 7,200,000 ms、各仅入账一次：10:25 正余额购买成功，10:31 再次购买取消及同步余额不变；11:13 确认零余额后从解读选声门禁购买成功，重选原社区声、重新生成并从保留末块播放完成。第二笔仅因两次真实生成扣 20,760 ms。此路径是选声门禁购买/重试/续播，不冒称实测后台耗尽专用 Continue 按钮。专用 Sandbox 账号临时零余额夹具已于 11:18 还原，保留真实新订单与使用；Production 账本未变。此前私人 Preview 的补单/幂等验收与最终正式 API 真机购买分开记录。12:15 Global 最终账本：Sandbox 86 笔成功、600,648 ms；Production 82 笔、798,025 ms，仍为基线。

用户授权赠送当前 CN 测试账号真实服务端 Pro 7 天，2026-10-06 11:31 CST 到期、无续费；仅该账号加入现有沙盒测试名单。未改变其他账号权限/订单。测试准备时旧会员过期及缺 Sandbox 资格导致的拒绝保留，不计为通过。

成本依据服务端 `docs/clone-credits-cost-2026-09-28.md`：GPU/存储 $0.4435556/小时、实测 RTF 0.08518，120 分钟音频边际推算约 $0.0756；730 小时持续实例固定成本约 $323.80/月，尚需计利用率、Apple 分成、税费和其他运维，不把边际推算当全成本利润。

## 回归结果

首次真机全套暴露测试设施路径、旧哈希和异步断言问题，修正仅影响测试；26 项定向复测通过。完整 r5 为 1,950 项：1,929 通过、20 跳过、1 本地化失败；补齐 22 条购买文案 × 7 语共 154 个译文后，受影响完整 LocalizationCatalogTests 50 项全通过。合并真实结果为 **1,930 通过、20 跳过、0 未解决失败**，不声称单次全绿。20 跳过为 10 项 Mac localhost IAP/额度夹具、10 项需本地真实文件或显式实网开关的用例。真实购买和服务矩阵另行通过。证据 `physical-unit-tests-combined.json`，失败原始结果保留。最终 Debug/Release 已重建并装机。

## 服务端与商店

Global：源码 `6acd3933db95926b7426e1d068e936f30fb24324`，工作流 `36471567236`，部署 `dpl_DptAVPWCZ8iDrXeNWiCexMSvjB8x`。CN：源码 `036a5a9067daa50a46353e93363d88b6c1779b60`，部署 `release-20260929034148`；应用/依赖与 Global 一致，保留 CN 运维配置。签名校验、账号归属、隔离账本、幂等、原子预留/退款及健康检查通过，cloneCredits enabled/salesEnabled/sandboxIsolated 为 true。CN 清理每 15 分钟仅清过期重放音频，不删订单余额。

ASC App `6757636395`；基线版本 `f835f4df-b17b-4c1b-a71f-50de22006ae7`，App Info `a3a05161-de19-4dd4-8c99-363187f758c7`。本版草稿 `138a0a05-56de-42f7-b841-31fdfb842418`；待发布 App Info `acf27d07-c6bd-48e9-abaa-af0f93b723e7`。11 语 What's New 已更新并回读，其他文案、标题/副标题、55 张有效截图保持原样；审核备注购买步骤已更新，联系/账号字段不变。发布方式 AFTER_APPROVAL 保持。

IAP 版本 `f267f0a8-d537-4fa7-9cc1-1796fc44b71c`，11 语商品名称/说明与审核备注已完成。12:18 从真机亮屏导出未经编辑的 1290×2796 购买页，`iap-review-credits-final.png` 已目视确认。先前黑图/锁屏图不上传。最终同批需包含 App 版本与 IAP 版本；提交工具 6 个隔离模拟 API 测试及两项目在线 dry-run 通过。

## 最终归档与提交回执

PR #2 已合入 main，归档提交 `fadb18a727c96c6ada3353e08882fe1ed34ccf74`；416 个验收应用文件逐一一致，归档前祖先门禁再次通过。正式 `xcodebuild archive` 成功，仅用仓库 AppStoreExportOptions.plist 经官方 `-exportArchive` 上传一次。2026-09-29 12:40:40 CST 回执 success，errors/warnings 均为空；无改包或重复上传。

归档 `/Users/xuxuheng/Desktop/CastReader-1.2.47-Release/CastReader-1.2.47-70.xcarchive`，归档文件清单 SHA-256 `53b8e53eaa4e5cecc7ce7c6a8d7d608654eccf5e0b831d3bd319cedc71cf30e8`。官方 export 仅向归档根 Info.plist 写入成功分发记录，App/扩展全部原文件未变化；含该记录的最终清单摘要 `102b5aeaa49b6b433abe851eccc2f05fec026a9c6a5f8dd489e7d3e6f0924d3f`。开发签名归档由官方 export 重新分发签名；不把归档 get-task-allow 值冒称最终商店签名。九语各 1,520 个编译 key、四组件版本/设备族/团队/严格签名及加密声明通过；203 文件/54 标志扫描 0 命中。

Build ID `e0d0175f-e83f-47a9-8055-3bba0f09fd19`，70 / 1.2.47，`VALID / APP_STORE_ELIGIBLE`，usesNonExemptEncryption=false，准确绑定本版。最终 ASC audit 无错误：11 locale、原标题/副标题全部不变，55 张截图均 COMPLETE（9 语 iPhone 45 张 + 中英文 iPad 10 张；zh-Hant、es-MX 沿用主语言回退）。审核资料、AFTER_APPROVAL 均保留。

内购审核截图 `d463dec3-f954-4c3f-b3de-c95a1dfe7a9e` 已 COMPLETE、无错误/警告；商品先到 READY_TO_SUBMIT，再由 ASC 网站加入同一审核草稿。dry-run 精确验证只有本版 App 和目标 IAP 版本两项，最终从网站执行提交。

- 提交时间：**2026-09-29T04:46:34.519Z / 北京时间 12:46:34**。
- Review Submission：`e0120f7a-1331-468f-adb9-0b1f045c352a`，**WAITING_FOR_REVIEW**。
- App version：`138a0a05-56de-42f7-b841-31fdfb842418`，**WAITING_FOR_REVIEW**，构建 70。
- IAP `6816697780` / `ai.castreader.clone.minutes120`，**WAITING_FOR_REVIEW**，对应版本 `f267f0a8-d537-4fa7-9cc1-1796fc44b71c`。

ASC 网页显示“已提交 2 个项目”，两项均“等待审核”；官方 API 回读上述状态，且没有再次执行写入。审核单内 item 的 API 子状态仍为 READY_FOR_REVIEW 是该接口返回值，不能把它与父审核单、App 或 IAP 的实际 WAITING_FOR_REVIEW 混淆。

[查看审核单](https://appstoreconnect.apple.com/apps/6757636395/distribution/reviewsubmissions/details/e0120f7a-1331-468f-adb9-0b1f045c352a)。可提交的去敏回执、最终测试与源身份摘要见 [reports/ios-release-1.2.47](../reports/ios-release-1.2.47/)。原始私有证据留在上述本地目录。
