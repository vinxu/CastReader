# CastReader Mac 1.2.48（Build 76）交付记录

2026-10-11 13:07:26（北京时间）已提交 App Store。版本和 Review Submission 均为 **WAITING_FOR_REVIEW**；发布方式保留 **AFTER_APPROVAL**，审核通过后自动发布。此状态不表示已经审核通过。

## 本版交付

- Mac 界面支持 28 种语言，沿用已发布 iOS 的语言、声音目录和朗读/解读逻辑；保留 Mac 原有书架、导入和窗口功能。
- 音色浏览使用与 iOS/iPad 一致的当前音色、推荐及搜索布局。单音色语言只有清楚的当前声音卡片，不显示空推荐区；播放中换音色按内容/讲解语言打开。
- 替换冗长额度警告：大字号总可用余额、月度与已购余额卡片、增加 120 分钟及 StoreKit 实时价格按钮，规则默认折叠。只有服务端确认总可用为零才显示“生成额度已用完”；月度为零但已购余额仍有 37 分钟时显示可用 37 分钟，未知余额显示同步中。
- 28 组真实 Mac 产品图，每组 5 张，共 140 张；2560×1600、无透明通道。朗读画面均有实际词高亮，解读画面有真实原文标注。
- 上传 29 个 Apple 支持的商店语言条目，每个 5 张，145 张全部 COMPLETE。27 个应用语言有对应商店条目，另保留 es-MX 与 zh-Hant。**Apple 不提供 Filipino 独立商店语言条目**：菲律宾语的 5 张图片和说明保存在本地，商店按英语回退；es-MX 复用西语图，zh-Hant 复用简体中文图。没有虚构 Apple 不支持的条目。
- 商店说明、关键词和更新内容已逐字段回读一致；现有标题、副标题、价格、订阅、地区、隐私和法律设置未变。

## 源码与安装包

- 正式源码：`f4bb046`，已推送 `origin/codex/mac-28-languages`。
- 同时包含 Mac 已发布 Build 73（`295c2f4`）和 iOS 已发布 Build 75（`d48a9af`）的祖先实现。
- App/Share/Widget 均为 1.2.48（76），包含 arm64 和 x86_64，三个进程的签名、沙盒、App Group 与描述文件均通过校验；54 项测试夹具标记扫描为零命中，Debug 正对照通过。
- 28 种语言资源在三个已签名组件中均已确认；没有打入未完成的 Safari 扩展。
- 归档：`/Users/xuxuheng/Documents/CastReader-Releases/Mac-1.2.48-76-20261011/CastReaderMac-1.2.48-76-final.xcarchive`。
- 同归档的正常 Release 包已安装至 `/Users/xuxuheng/Applications/CastReader for Mac.app`。保留原账号与书架，未开启模拟 Pro；已恢复跟随系统语言、Morgan Freeman by Tims 英语音色和 1.5x 速度，播放已停止。

## 验收证据与边界

| 管线 | 结果 | 实际证据 |
| --- | --- | --- |
| 英文朗读 × 常规 Bella | PASS | 真实新音频、请求音色 ID、音频时间推进、词高亮、自动下一段及暂停/继续 |
| 英文朗读 × 社区/私人 | PASS / PASS | David Attenborough 与现有 Mac QA 私人音色分别生成并推进；按常规→社区→私人→常规切换 |
| 英文解读 × 常规 Bella | PASS | 新 QuickRead 生成 6 块讲解；实际播放讲解、原文圈画/高亮、自动下一块 |
| 英文解读 × 社区/私人 | PASS / PASS | 实际生成 ID 与选中一致、块推进和原文标注；换声保留讲解、重新生成对应音频；最终切回 Bella 播放 |
| 捷克语单音色 | PASS | Tereza `api_cs_wavenet_b`，自动识别 cs，12 个朗读段与 4 个解读块；实际使用 api.castreader.ai，唯一声音面板无空区 |
| 额度界面 | PASS | 正常账号月度 0 / 已购余额仍可用；真实 StoreKit 价格；中文、德语、阿拉伯语面板；最终 Release RTL 复验 |

Mac 产品本版只有 Global 服务线路，CN 不属于该产品发布矩阵。上述核心运行使用生产身份的正常开发签名包，无注入音频或假账号；最终 Release 补验签名、资源、夹具排除与额度 UI。日志提交 `cb4dde7` 到最终 `f4bb046` 的 TTS、QuickRead、播放器与两个播放 VM 无变更，因此复用核心结果，不重复耗费生成额度。最后的额度改动仅影响展示与入口，余额模型与通过的测试源码哈希相同。

- 本轮全量执行曾因旧 iOS 测试夹具不符合 Mac 句子播放/冷启动策略出现 22 个失败用例；已修正平台适配的测试预期。受影响八个完整套件复验 **390 PASS / 0 FAIL / 1 SKIP**，额外额度回归 **5 PASS / 0 FAIL**。另一次声音目录聚焦复验 **51/51 PASS**。
- 唯一上述受影响套件跳过项为 opt-in Google Play Books 外部网络测试，不作为核心朗读/解读通过依据。全量执行过程中曾磁盘不足，原始完整 stdout 已保留，未把无效的 xcresult 零统计当成通过。
- 社区音色本轮为 warm；没有伪报实测冷启动。冷准备、旧响应、未知余额保持和队列所有权沿用通过的隔离回归。
- 本轮额度界面验证没有发起新的真实付费交易；原有 StoreKit 商品、价格与服务端结算链路保留。

## Apple 最终记录

- App：`6757636395`；Mac version：`e9065422-ce33-4ff5-81e1-a7b7aef4f7b4`。
- Build：`5e1cbc05-8bce-4b97-bee0-a8db3bdb9273`，`VALID / APP_STORE_ELIGIBLE`，非豁免加密声明保持 false。
- Review Submission：`9d54c621-2158-4607-8dc9-4eead1dcb481`，`WAITING_FOR_REVIEW`。
- 提交时间：`2026-10-11T05:07:26.079Z`。
- 最终商店审计 errors 为空，29 个条目各 5 张 COMPLETE 图片；提交后的版本、绑定 Build 与应用说明已再次回读。

详细证据位于本工作树 `reports/mac-28-languages-20261011/`：`core-service-acceptance.json`、`live-core-current.log`、`ui-audit/`、`quota-panel-tests/summary.json`、`repair-r6/summary.json`、`archive-identity.json`、`archive-bundle-verification.json`、`archive-fixture-scan.json`、`asc-final-audit.json`、`screenshots-upload-summary.json`、`post-submission-readback.json`。包含账号验收资料的原始文件只保留本机，不提交到 Git。
