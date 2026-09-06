# iOS 1.2.34（54）发布记录

## 提交结果

- 提交时间：2026-09-06 12:16:10（Asia/Shanghai）；UTC `2026-09-06T04:16:10.937Z`。
- App Store 版本：`1.2.34`，Build `54`。
- 版本状态、Review Submission 状态：均为 `WAITING_FOR_REVIEW`。
- 发布方式：`AFTER_APPROVAL`，审核通过后自动发布。
- Version ID：`1db5a12c-64cd-4961-ad04-4ff117646723`。
- Build ID：`c7e03dec-5c12-4914-a69b-ec1a7db2c7b6`，`VALID / APP_STORE_ELIGIBLE`。
- Review Submission ID：`59fab953-41d1-4cd3-94f7-3221822b70f8`。
- 归档：[CastReader-1.2.34-54.xcarchive](/Users/xuxuheng/Documents/.worktrees/CastReader-ios-release-1.2.34/build/CastReader-1.2.34-54.xcarchive)。Xcode archive 和官方 export/upload 均成功。

## 本期内容与基线

从已上线 1.2.33 的 `e3bbe90` 保留完整功能，整合 Kobo / Google Play Books 登录、绑定、完整书架同步、首页与阅读页衔接；账号与扫描结果隔离；普通 TTS 暂时错误恢复和响应容错；Kindle 翻页后续读；中国区线路稳定性；音色创建请求超时调整。

已上线的邀请录音、上传音频创建音色、音色分类和首页布局完整保留。脑腐视频链接修复属于浏览器扩展/桌面端，没有作为 iOS 更新加入；独立离线朗读分支也未纳入。

- 发布目录：`/Users/xuxuheng/Documents/.worktrees/CastReader-ios-release-1.2.34`。
- 发布分支：`codex/ios-release-1.2.34`，已推送 origin。
- 归档时提交：`830d778`；应用源码最后修改提交 `f25abf1`。测试后、上传前已逐文件核对源码哈希一致。
- 原工作目录的其他未提交改动保留；本次正式版本源码以发布分支为准。

## 模拟书籍排除（用户明确要求）

针对正式归档 App 的 119 个文件，检查 30 类模拟书名、书籍 ID、HTML 页面、模拟书架存储标记和启动开关，结果 **零匹配**。同一检查器对 Debug 对照包成功检出 Google 与 Kobo 模拟书，证明扫描有效。正式归档编译日志没有 `DEBUG` 编译条件；没有测试 bundle、模拟书架资源或 Safari 扩展被嵌入。模拟代码仅用于本地 Debug / 自动测试，正式二进制中没有可启用的模拟书架入口。

证据：[no-shelf-fixtures.json](../reports/ios-release-1.2.34/no-shelf-fixtures.json)、[归档文件哈希](../reports/ios-release-1.2.34/archive-file-hashes.json)。上传的是上述同一份归档，模拟器数据容器没有参与打包。

## 测试与修复闭环

- 全量单元测试 1,293 项。首轮发现缺少“请先登录”本地化条目，以及音色测试硬编码中文；补齐九语文案、修正测试的语言预期后，两项定向测试通过。
- 完整单元回归中，其余 1,286 项通过、6 项按既定环境条件跳过；英文 TTS 实网用例遇到测试机代理 TLS 中断。随后该用例独立重跑通过，完整 `EvalTests` 组也通过（19 通过、1 项预设实网授权条件跳过）。因此 1,287 项可执行单元用例均已取得通过证据，无未解决失败。
- 全量 UI 套件：64 项，53 通过、11 项按既定实网/截图环境条件跳过、0 失败。覆盖九语言启动、18 组语言/外观书架、登录与购买入口、首页、音色创建、Kobo 四页及 100 本、Google 100 本等。
- 原授权模拟器上单独启用 Google 真实账号验证：两本书同步首页、逐本打开、翻页、重启保留通过。此项在常规 UI 套件中为条件跳过，合计 54 个不同 UI 用例取得通过证据。
- 原模拟器已运行整合后的中文首页，授权 WebKit 登录状态保留。本轮没有宣称 Google 新包已完成物理 iPhone 测试，也没有断言 Google 阅读器真实 TTS 播放。
- Release 归档成功；主 App、分享扩展、Widget 版本均为 1.2.34（54），最低 iOS 17.6；签名校验通过，非豁免加密声明为 false。

原始结果位于 `/tmp/castreader-ios-1.2.34-*.xcresult`；摘要保存在 [reports/ios-release-1.2.34](../reports/ios-release-1.2.34)。测试首轮在新工作树缺少本地 xcconfig 时未能构建，补入原发布树的本地配置后重跑成功，未改动或输出配置内容。

## 商店资料与审核

- 11 个 App Info 语种、11 个版本语种齐全，更新说明与本期 JSON 逐字回读匹配。
- 标题、副标题、隐私链接、介绍、关键词、推广文案、支持与营销链接均保留上一版值。
- 新版本创建时 Apple 未继承推广文案，已按原发布内容恢复；一次元数据写入超时后先回读，确认已保存 9 语，只补写剩余 2 语。
- 46 张截图均 `COMPLETE`：9 语种有独立截图，繁体中文与墨西哥西语沿用主语言截图。
- 审核联系资料完整、无需演示账号。未修改价格、订阅、地区、App Privacy、年龄分级或内容版权声明。
- 使用 Review Submission 正式提交，未使用已废弃的版本提交接口。

非阻塞限制：此 API key 无法读取 `buildUploads` 集合（Apple 返回该集合不允许 GET_COLLECTION）。发布按 SOP 以 Xcode 上传成功和精确 Build 的 VALID / APP_STORE_ELIGIBLE 回读为门禁。三项 StoreKit 模拟购买测试因宿主 `notEntitled` 按既有逻辑跳过，其余条件跳过项需要额外实网授权/测试参数；本次没有更改商业化流程。
