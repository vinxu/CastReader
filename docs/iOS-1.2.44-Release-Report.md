# iOS 1.2.44（66）发布记录

状态：**已提交 App Store 审核；版本与审核单均为 `WAITING_FOR_REVIEW`。**

## 源码与版本

- 2026-09-23 从最新远端 `main` 的 `426a09a` 建立 `codex/ios-release-1.2.44`，双亲合并 `f74fa6b` 完整纳入本次修复分支 `aba9b0d`，再以 `6f7f546` 统一 App、Share、Widget 为 1.2.44（66）。商店回读上一版 1.2.43 已 `READY_FOR_SALE`；其正式主线合并 `fe64420` 是本候选祖先。
- `3013b71` 的 iPhone/iPad 通用应用源码、iPad 分支 `bcd9778`、既有读写/音色/额度/EPUB/PDF/Kindle/多窗口等必备提交，以及本轮 Tab/Kindle 四个修复提交均经祖先关系核对包含。相对最新线上主线的应用变更只涉及 MainTab、Home、Kindle、Explain、QuickRead、本地化与六处版本/Build 配置。基线脚本 `build-voice-toc-integration.sh --check` 已通过。
- 已装真机开发包的应用源码及资源与前轮修复验收 `aba9b0d` 完全一致，差异仅在项目版本配置；本次候选包含最新主线的其余文档、测试和商店物料。
- 冻结提交 `6f7f546faadce8e79dcb470874e999ca22fa85f8`；301 个应用/组件/工程文件清单摘要 `f1c83d541b95a0f9427b799e7b7b51f722495a8e8129af9c60f99841449ece56`。逐文件清单在私有 `reports/ios-release-1.2.44/candidate-identity.json`，不含本机私有配置。
- 真机验收后，纯测试前提修正及本报告纳入 `b1ffeed`；`main` 在远端 `426a09a` 未变化的前提下快进至该提交并推送。发布归档的 301 个应用与配置文件在合并前后逐文件复核均未变化，因此归档仍与正式主线应用源码一致。

## 商店与本地预检

- ASC 一次 inspect：已上架版本 1.2.43 ID `64b17291-fac4-444d-a18b-790b75c01d03`；最高已上传 Build 65，当前无活跃审核单；下一版 1.2.44（66）。已上架 App Info ID `74d0c149-211b-4d37-8d29-e77667241029`。
- 三组件同版同 Build、Team `KQW6UNZE8J`、11 语资料、本机签名与 ASC 密钥权限的 preflight 已通过。发布工作树的 `Secrets.xcconfig` 仅在本机复制并被 Git 忽略。
- 1.2.44 的 11 语商店文案与已上架元数据逐字段对比，仅 `whatsNew` 有预期差异；标题、副标题、描述、关键词及推广文字完全一致。11 语截图集合共 55 张，状态全部 `COMPLETE`；原有两种无专属截图语言继续继承主语言。私有 ASC 原始快照在 `reports/ios-release-1.2.44/`，不会提交账号资料。
- 正式 Release 归档 `/tmp/CastReader1244Release.xcarchive` 于 2026-09-23 成功。App、Share Extension、Widget 均为 `1.2.44 (66)`、Team `KQW6UNZE8J` 且签名验证通过；包内包含九种 UI 语言及葡语回退资源，无 Safari 扩展或 XCTest 夹具。`CastReaderInternalDistributionControlsEnabled=NO`、`ITSAppUsesNonExemptEncryption=false`。主二进制 SHA-256 为 `60e207d5beac892a3ec48e611c43eab528e9b9f5451f14af448fea3c8161721c`；审计结构见私有 `reports/ios-release-1.2.44/archive-audit-private.json`。
- 本次沿用现有有效截图和审核资料，不改价格、订阅、地区、App Privacy、年龄分级或法律声明。发布方式计划沿用审核通过自动发布。

## 真机验收

设备：iPhone 15 Pro Max / iOS 26.7。依用户要求，**只用 iPhone 镜像和真机测试，没有使用模拟器**。

- 1.2.44（66）正常开发签名包已在真机启动。实际 Kindle 英文解读显示原文标注、讲解字幕，并自动翻至下一页后继续播放。首页与音色页在镜像中往返切换多次，系统原生 Tab 选中状态正常；这次镜像观察不替代更长时间的性能采样。
- 11 项有针对性的真机播放回归于 `/tmp/CastReader1244Targeted3.xcresult` 全部通过，含过期预取、任务续接、标注结束翻页、停止/恢复归属。首轮另外加入一条读取宿主机 Swift 文件的静态用例，在 iPhone 上因无宿主源码路径失败；相同断言已在开发机逐项通过，随后排除该环境不适用项重跑 11 项并取得整体 `TEST EXECUTE SUCCEEDED`。
- 前轮同一应用源码的镜像验收连续翻页两次、第三页继续播放；八项过期任务真机可控时钟测试全部通过。完整定位与边界见 [Kindle 任务过期修复](kindle-explain-job-expiry-2026-09-23.md)。
- 受影响的 SpeechPipeline 真机套件 28 项全通过；Release 配置已在同一真机编译并完成三组件签名、版本、九语资源检查。中国线路专用 UI Runner 在 Xcode 测试引导阶段退出（code 74，测试未启动），改由镜像手动验收，不计作通过项。
- 全量单测使用独立真机测试包 `com.same.castreader.releasechecks1244`，独立 Keychain 与 App Group；未在用户的正式 App 中运行可能清空账号状态的全量测试。2026-09-23 20:48 本机时间完成 `/tmp/CastReader1244IsolatedRunnableFull.xcresult`：**1,849 项、0 失败、22 项由测试自身跳过，整轮 `TEST EXECUTE SUCCEEDED`**。支付测试类因可能变更真实账号/付款状态未运行。另有 24 项从真机总跑显式排除：22 项读取宿主机源码/JSON/图片的静态断言（iPhone 无法访问 Mac 路径）；1 项 Kindle WebKit 像素对比在 iOS 26.7 的测试窗口取得全黑 `takeSnapshot`，实际镜像标注可见且同套件 DOM 路径/粗细/透明度断言通过；1 项 SVG 绘制截图在组合运行曾取得空白画面，但原测试源码单独运行 1/1 通过。22 项内部跳过主要是需本机样本文件或显式 opt-in 的测试，详见结果包。真机总跑前的 Google Books 两项 WebView 时序偶发超时单独复测均通过；中国/全球区默认值和会话、`/var` 路径差异已仅在测试前提/比较上修正，并在整轮回归中通过。受影响 SpeechPipeline 28/28 与音频暂停/续播 9/9 另有独立真机通过记录。
- 中国线路真实短文与国际线路 Kindle 原文均完成每区四格，切换中保留位置；中国短文解读进入下一块并完成，国际 Kindle 解读原文标注、字幕和自动翻页后继续播放。下列格均见真机画面及 `reader-refocus.log` 的新生成、实际播放和段落/块推进记录。
- 中国区测试专号的既有 24 小时零金额手动 Pro 授权已过期；沿用前版同意的测试授权方式创建 `ios1244-cn-test-20260923`，2026-09-24 10:35:13 UTC 自动到期，不收费、不自动续费，未改既有付费订单。运行中克隆额度按成功生成下降。
- 1.2.43 的 iPad 验收见 [前版发布记录](iOS-1.2.43-Release-Report.md)；本轮 iPhone 专属 Tab 修改不触及 iPad Tab 路径，共享 Kindle/Explain 所有权以真机测试和两区真机服务格覆盖。

| 地区/输出语言 | 朗读常规 | 朗读社区/私人 | 解读常规 | 解读社区/私人 |
| --- | --- | --- | --- | --- |
| CN / zh | PASS：`zf_001`；`api.castreader.cn` 200、高亮和连续段落 | PASS：社区 `vl_b4bb75aa2d3e56fd90a2` / 私人 `vc_63a448ca35794f57b0aea0e189a68cb3` 均新生成 200、实际播放、继续到下一段；切回常规 | PASS：7 段新 QuickRead，常规音色讲解，原文标注、字幕、块 0→3 | PASS：私人 `vc_63a448ca35794f57b0aea0e189a68cb3`、社区 `vl_b4bb75aa2d3e56fd90a2` 各自重新生成 200，块 0→3 和标注；切回常规 |
| International / en | PASS：`af_bella`；`tts.castreader.ai` 200、词高亮、Kindle 连续段落与翻页 | PASS：社区 `vl_d1efb23a380bdaa2f6b0` / 私人 `vc_62934fe77f764051aa341b4b076bbb85` 均新生成 200、实际播放与下一段；切回 Bella | PASS：Kindle 新 QuickRead、Bella 讲解，原文标注和英语字幕，自动翻页后继续播放 | PASS：社区 `vl_d1efb23a380bdaa2f6b0` / 私人 `vc_62934fe77f764051aa341b4b076bbb85` 各自新生成 200，标注字幕及翻页续播；切回 Bella |

日志：`/tmp/CastReader1244-CN-1837-reader.log`、`/tmp/CastReader1244-CN-1841-reader.log`、`/tmp/CastReader1244-global-1855-reader.log`、`/tmp/CastReader1244-global-1902-reader.log`。国际 R-C 在 19:00:26 切社区，19:00:28 收到 200，19:00:44 自动进入下一段；19:01:06 切私人，19:01:08 收到 200 并真实播放，19:01:09、19:01:22 继续推进。19:01:55 切回 Bella 后播放常规音频。真机镜像 19:01 可见词高亮与翻页。音色后来一次误触选中其它社区声音，已于 19:03 显式恢复 Bella 并暂停。

## 上传与审核提交

- 官方 `xcodebuild -exportArchive` 使用原归档和仓库 `scripts/AppStoreExportOptions.plist`。首次尝试经本机代理时，Apple 内容交付在同一分片反复出现校验和不匹配，Build 66 尚未出现在 ASC，故停止该失败的重传；保留原归档，在去除进程代理环境后重试成功，Xcode 返回 `Upload succeeded / EXPORT SUCCEEDED`。未改变应用二进制或提高 Build 号。
- ASC Build **66** ID `844cef9b-209d-455f-ad78-f9b036337fe1` 于 `2026-09-23T13:19:47Z` 上传；后续回读 `VALID / APP_STORE_ELIGIBLE`，`usesNonExemptEncryption=false`。
- 新版 1.2.44 ID `00f5fd32-714e-4744-98aa-b60ebfae8184`，待发布 App Info ID `7dda1882-212e-4c08-80a4-cdcf1bdd95db`。仅更新 11 语 `whatsNew`，提交前后回读与文案文件 11/11 相同；标题保护审计显示 11/11 未改变，原有 55 张截图全部 `COMPLETE`，`es-MX` 与 `zh-Hant` 继续继承主语言。审核资料存在、审计零错误。未改价格、订阅、地区、App Privacy、年龄分级、法律声明或自动发布策略。
- Build 66 已绑定并回读一致。Review Submission ID `1e755484-850a-41d5-936c-f2de8139c03a`，于 **2026-09-23 13:24:35.998 UTC** 提交；正式回读审核单和 1.2.44 版本均为 **`WAITING_FOR_REVIEW`**，版本维持 `AFTER_APPROVAL`。审核单含本版唯一版本项。
