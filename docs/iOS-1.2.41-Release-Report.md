# iOS 1.2.41 (63) 发布记录

状态：**已提交审核，版本和 Review Submission 均为 WAITING_FOR_REVIEW**。提交时间：2026-09-19 00:54:15（Asia/Shanghai）。审核通过后自动发布；尚不代表已经上线。

## 候选身份

- 工作树：`/Users/xuxuheng/Documents/.worktrees/CastReader-mobile-voice-explore-20260914`
- 分支：`codex/mobile-voice-explore-20260914`；基线 HEAD：`febfeabf869c2f77b57d360e970218899c87aa02`，包含待提交增量。
- 本版包含流式有界预读、已核验后缀换声/缓存、解读短单元及标注同步；另外修复验收发现的保留阅读会话响应全局换声而抢占播放器，以及完成后换声重播旧音频。
- 最终应用源码/工程 SHA-256：`8670be15e6d5e31df8752192c9b694a81f5149c65a22ce2c0eeb429d75f3dd06`，见 `reports/ios-release-1.2.41/candidate-identity.json`。按路径排序 App 内 Swift/xcstrings，再追加 pbxproj，共 216 文件；依次计算相对路径、NUL、文件字节、NUL。核心验证使用正常签名开发包，非 App Store 分发包；不注入音频、身份或鉴权。
- 预检时上一商店版为 1.2.40 / READY_FOR_SALE，最大已上传 Build 62。本版保持 AFTER_APPROVAL（审核通过后自动发布）。

## 核心服务验收

| 地区 / 输出语言 | R-K | R-C 社区 / 私人 | E-K | E-C 社区 / 私人 |
| --- | --- | --- | --- | --- |
| CN / zh | PASS | PASS / PASS | PASS | PASS / PASS |
| International / en | PASS | PASS / PASS | PASS | PASS / PASS |

最终候选两区矩阵已完成；已通过格来自本次 23:05 安装的最终候选。固定英文原文见 `reports/ios-release-1.2.41/core-sample-en.txt`。通过正常 `castreader://read?input=...` 接口导入，使用 `%20` 编码空格。之前错误使用 `+` 编码的测试文档不作为验收输入。

用户明确授权重置当前账号克隆额度：已仅清零国际区当前活跃周期 bucket 的 used_ms（7,181,920 → 0）；reserved_ms 本来为 0，无未完成保留请求。订阅、历史 ledger、其他周期及其他账号未变。数据库备份和操作审计仅留本地私有 `/tmp/castreader1241-quota-backup.json`、`/tmp/castreader1241-quota-reset.json`；不提交用户标识或凭据。手机后续真实生成响应及余额显示已验证重置生效。

## 检查及失败处理

- 初次全量：1,784 项、9 跳过、16 条失败断言（7 个独立用例）。2 项旧 Eval 预读测试未建立当前段已有音频的前置条件；改为完整生成路径，并断言精确缓存复用/不重复请求。其余 5 项伴随模拟器音频错误，单独复跑全部通过。
- 相关完整复跑：48 项、1 跳过、0 失败。跳过为显式需真实账号的在线解读 Eval，由真机矩阵承担验收。
- 真机发现保留会话抢占及完成后换声旧缓存，补修后相关套件：99 项，0 失败。覆盖 SpeechPipelineTests 13 项、ReadingResumeTests、ReadAloudContinuationTests、AudioPlaybackOwnershipTests。检查使用当前会话 token，允许已激活但尚未装载队列的解读恢复。
- 最终候选全量通过：1,787 项中 1,778 通过、9 跳过、0 失败，约 8 分钟。`/tmp/CastReader1241FinalUnit20260918.xcresult`；跳过项及历次失败/重测汇总见 `reports/ios-release-1.2.41/test-summary.json`。9 项为原有需要指定本地资料、在线鉴权或 StoreKit 环境的可选用例；不以这些跳过代替真实核心验收。
- 九语资源/缺键/占位符等 LocalizationCatalogTests：50 项，0 失败；见 `reports/ios-release-1.2.41/localization-tests.log`。
- 已跑基线检查，保留发布祖先；Xcode 团队账户有效；preflight 通过。

## 商店资料

- 初始快照和最终检查均为 11 个版本 locale 与 11 个 App Info locale。9 个截图集共 45 张，全部 COMPLETE，文件和顺序与基线一致；zh-Hant、es-MX 继承主语言截图。审核联系人完整，demoAccountRequired=false，审核说明与基线一致。
- 1.2.41 版本 ID：`6ad32f79-da45-4ded-8863-be8ef3d0afe9`；pending App Info：`2795ac8a-92b4-4401-a8d5-6e63b3385fb1`；baseline App Info：`8a0b4ca4-06b9-45ce-b612-fe4e9c633a41`。
- 已更新并回读 11 语 What's New，其他版本属性保持原值；未修改 App Info。更新证据：`metadata-patch.json`。保留标题/副标题、现有截图及法律/定价配置。
- 文案：`docs/AppStore-Whats-New-1.2.41.json`；当前资料快照：`reports/ios-release-1.2.41/`。
- Build ID：`aa33b7a4-cbc2-4c7d-aa76-a626434af0b8`，1.2.41（63），`VALID / APP_STORE_ELIGIBLE`，usesNonExemptEncryption=false。已绑定并回读一致。

## 正式归档与上传

- 使用 workspace / CastReader scheme / Release / generic iOS device，独立 DerivedData `/tmp/CastReader1241Archive63`。归档 `build/CastReader-1.2.41-63.xcarchive` 成功，归档后未更改应用代码或配置。
- App / Share Extension / Widget 均为 1.2.41（63），签名团队 `KQW6UNZE8J`。归档原始开发签名与上传分发签名分别核验；分发三个产品均 `get-task-allow=false`，严格签名校验通过。见 `archive-validation.json`、`distribution-validation.json`。
- 上传 IPA 为 42,822,946 字节，SHA-256：`383a35dc4fd5139d5a191c7f31e85de7b5b265f8e9e7cb0e3bd5472d6b549acc`。
- Release 离线资源检查：9 语、186 键、0 错误；测试夹具排除扫描 123 文件/54 标记通过，并用 Debug 包作阳性对照。见 `release-localization-audit.json`、`release-fixture-audit.json`。内部切线开关为 NO，未包含未完成的 Safari 扩展。
- 00:15:29 通过仓库 `scripts/AppStoreExportOptions.plist` 启动官方 Xcode 上传。receipt `aa33b7a4-cbc2-4c7d-aa76-a626434af0b8`；上传分析文件期间经本机代理发生 NSURLErrorDomain -1005 / 校验和不匹配。00:31 用同一归档恢复官方 export，Xcode 复用了同一 receipt，未创建重复候选；仅 Apple 对象存储临时走直连，分析文件传输恢复。00:36:19 官方返回 EXPORT SUCCEEDED / Upload succeeded，临时代理例外已恢复原值。见 `upload-result.json`。最终上传 IPA 保存在 `build/CastReader-1.2.41-63-upload.ipa`；恢复 export 后已重新验证分发签名并记录最终 IPA 摘要。
- 六个继承的商店公开链接均返回 HTTP 200，见 `public-links.json`。
- 中国后端只读部署身份：`release-20260915180927` / `2251845f60d96ba4a2d4dc9368714dcb549b6771`，合同 voice-clone-v3。本轮未修改生产服务代码或部署。

## 最终候选真机证据（23:05 起）

- 安装身份：`device-candidate.json`，dylib UUID `D99F968F-0D02-3FE8-BBDD-516F69C86B2C`，源码摘要未变。设备 iPhone 15 Pro Max / iOS 26.7。
- 国际 / en：常规 `af_bella`、社区 `vl_d1efb23a380bdaa2f6b0`、私人 `vc_62934fe77f764051aa341b4b076bbb85`。23:07–23:09 在朗读中依次换声；实际 TTS voice 与选择一致，AVPlayer 完成段落并推进 checkpoint，原文词高亮可见。23:07:03 完成后换成 Bella 从首段新生成、autoPlay=N，手动播放后继续多段，验证旧音频修复。23:21–23:22 读/解读互切、朗读暂停和恢复可继续。
- 国际解读：新 QuickRead job `qrc_NFWbs9hAX_gWtTFgW2fxxMHiyQGTF_hh`，3 块，真实 plan/extract/compose。常规声音 23:09:56–23:10:44；社区 23:15:34–23:16:30 连续三块；私人 23:18–23:20 连续进入第 3 块，暂停后停留、恢复后继续；切回 Bella 23:20:08 播放新音色。高亮、下划线及圈注在原文出现，不是朗读原文替代解读。
- 国际 API 和播放证据：`global-api-generation.log`、`global-device-progress.log`。Global QuickRead 使用 api.castreader.ai，常规 TTS 实际命中 tts.castreader.ai。未遇 VOICE_PREPARING，记为 warm；冷准备、迟到响应、等待时暂停等分支由最终候选确定性测试覆盖。
- 中国 / zh：正常保存的中国账号，使用调试启动参数仅选择 cn 产品/服务线路，无假账号/假音频或绕过鉴权。常规 `zf_001` 实际请求 api.castreader.cn，23:26:18 起连续三段，中文句段高亮与进度正常。解读新 job `qrc_RrgOcTBonmPY6JIH-uJ4tRq8wY1h9tFn`，quickread.castreader.cn / deepseek-v4-pro，2 块，23:30 完成 plan/extract/compose、标注可见并进入第二块。
- 中国账号起初服务端为非 Pro。用户于 23:28 明确允许临时测试权益；仅新增 manual / pending_cancel / 金额 0 的 24 小时测试权益 `ios1241-cn-test-20260918`，保留原有 2 条订阅与支付记录，自动到期。原始备份仅在本地私有目录；手机回读 pro=Y，120 分钟额度。初始会员同步拦截不计为克隆通过。

- 中国克隆最终结果：社区 `vl_b4bb75aa2d3e56fd90a2`（曹操），私人 `vc_63a448ca35794f57b0aea0e189a68cb3`（中国区测试录制）。社区解读 23:36–23:38、私人解读 23:38–23:42，均新生成、原文标注正确并播放两个块；切回 `zf_001` 后 23:50–23:51 继续播放到完成。
- 中国朗读：23:52:42 常规→曹操（para=1、autoPlay=Y），自动进入第 3 段；23:53:49 曹操→私人，23:54 从首段继续，暂停约 50 秒后继续，23:55:15 第 1 段完成、23:55:35 第 2 段完成。9 月 19 日 00:00–00:02 私人→常规（镜像恢复后），高亮从“选择舒适的声音…”推进到“理解较难的内容。”并完成。末次切回由镜像可见进度确认，CoreDevice USB/调试连接此时 unavailable，未取得这最后一步的新控制台日志；前述生成、克隆播放与完成日志已保存。
- 中国证据：`cn-api-generation.log`、`cn-device-progress.log`。只读账本核对新成功生成共 301,422 ms，bucket used_ms 完全一致，reserved_ms=0；常规不进入克隆账本。测试权益准确窗口为 2026-09-18 15:30:23.313Z 至 2026-09-19 15:30:23.313Z；纠正数据库 timestamp 时区后保留已产生的 100,667 ms 用量及对应 ledger，未清零。
- 无实测冷准备，全部记为 warm；冷准备、快速连续改选、迟到响应、错误/零余额及等待暂停用最终候选确定性测试证明。UI 测试期间连接中断/麦克风占用按 macOS 镜像提示处理，未将该系统事件记作应用崩溃。真实连续播放和多次选择后仍可交互，未观测应用 watchdog。
- 00:02 源码摘要再次核对为 `8670be15e6d5e31df8752192c9b694a81f5149c65a22ce2c0eeb429d75f3dd06`（排序 App Swift/xcstrings，再追加 pbxproj；路径 NUL 文件字节 NUL）；测试后未改应用代码。
- 19:41 的首次安装因 CoreDevice 断连失败；23:05 已重新安装并确认最终候选身份后才执行上述验收。相同 Build 号的更早开发包不作为最终候选证据。
- 00:16 前已退出中国测试线路，以正常启动恢复原国际区账号、讲解语言“中文”和“曹操”音色，返回首页并停止播放。手机测试结束，无需继续占用设备。


## 提交结果

- 提交时间：2026-09-18T16:54:15.83Z，即北京时间 2026-09-19 00:54:15。
- Review Submission：`f5a6f1f5-9eed-49f4-aa99-da89538a0e0f`，状态 **WAITING_FOR_REVIEW**；只包含本版一个审核项目。
- App Store version：`6ad32f79-da45-4ded-8863-be8ef3d0afe9`，1.2.41，状态 **WAITING_FOR_REVIEW**；发布方式 **AFTER_APPROVAL**。
- 最终审核检查 `final-audit.json` 无阻塞项；标题/副标题不变、11 locale 完整、45 张截图全部有效。`metadata-final-check.json` 进一步确认只有 What's New 改动，其余版本属性和全部 App Info 属性均与初始快照一致。
- `review-dry-run.json` → `review-submission.json` 记录实际提交；`post-submission-readback.json` 确认提交后仍绑定 Build 63，11 语 What's New 正确。未修改定价、订阅产品、销售地区、App Privacy、年龄分级或法律声明。
- 真机设置已恢复，网络代理临时例外已撤销。中国测试权益自动到期，不自动续费；本轮没有额外生产服务部署。
