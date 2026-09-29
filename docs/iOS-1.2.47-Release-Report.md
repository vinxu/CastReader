# iOS 1.2.47（70）发布记录

状态（2026-09-29 12:20 CST）：功能整合及真机验收通过，待主线合并、正式归档上传和最终提交。尚未进入审核。

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

## 待补最终回执

主线合并提交、不可变归档/IPA 摘要、Build ID 与 VALID/APP_STORE_ELIGIBLE、审核截图 COMPLETE、最终 audit、Review Submission ID/时间，以及版本和审核单 WAITING_FOR_REVIEW 状态在完成后填写。当前不得把验收通过或草稿当成审核完成。
