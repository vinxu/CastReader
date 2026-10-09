# iOS Voice 页面适配验收记录

当前候选位于 `/Users/xuxuheng/.codex/worktrees/ios-28-languages/CastReader`，分支 `codex/ios-28-languages`，基础提交 `09456f1979cc14ca19977ede4b1edde043c5f840`。本地交付候选版本 1.2.47 (72)，未发布。

## 实施结果

Global 的独立音色页使用 Explore / My Voices 两级入口、独立语言行、默认收起的搜索与同表面筛选。当前卡去重；常规音色不超过 6 个时直接列出，发现分组至少含 2 个不同条目。公开克隆先按源语言和既有能力得到完整池，再取首页 3 个，详情保留完整池。

首页私人/受赠预览先合并完整库并过滤授权、状态、兼容性和当前选择，再按创建日期排序取 3 个。阅读器保留全部兼容项；完整 My Voices 保留不兼容项的管理和固定试听能力，禁止不兼容选用。浏览语言随 App 语言上下文重置，同一上下文内保留手选；正文及解读语言仍分别管理。

异步选用和试听带页面、语言、账号及操作代次检查，切换或离开后取消。中国区继续原 9 语言与原发现行为。未修改服务端授权协议、账户数据、Pro、额度、录音资产或克隆输出语言集合。

## 当前验证

- 29 项定向回归通过，含浏览筛选、完整克隆池、私人排序、语言上下文、区域开关和暂停换声期间的播放意图。没有运行会改写 Pro/登录的整套测试。
- 15 种 UI 语言已实际截图并复核：en、zh-Hans、ko、ru、fi、tr、it、ar、he、de、ja、vi、fr、es、pt-BR。
- 韩语克隆详情实际遍历超过 6 个条目，并验证外语源 ID 不串入、清空后恢复。完整池尾项由模型测试覆盖。
- 阅读器 AX 快照包含 23 个 owned 与 6 个 gifted 唯一条目，未受首页 3 个上限限制。
- 6 条文案 × 28 语言共 168 条直接翻译；格式参数检查通过。
- 375pt 小屏最大辅助字号与 iPad 最大字号 de/ar/he 截图已复核，修复名称截断及推荐区横向溢出。iPad 的 3 项实际 WKWebView 视口回归通过；分屏拖拽／活动 mini player 截图未在最终这一轮重复。
- 常规、公开克隆、私人及已有受赠音色的 Read/Explain、试听恢复、显式暂停由自动和手工真实服务证据共同覆盖；失败的 XCTest 运行保留失败状态。
- 最新未签名 Release 编译通过，DEBUG 验收标记未进入正式二进制。源码与产物哈希见证据。

实时状态见 [验收表](acceptance.csv) 和 [验证索引](../../reports/ios-28-languages-20261008/voice134-alignment/verification-progress.json)。未完成的行不视为通过；Android 证据不能替代 iOS 操作。

## 修复与边界

真实播放发现：用户暂停后换声，在新音频返回前点击播放，旧的暂停快照会覆盖新的恢复意图。Read Aloud 现读取最新播放请求，同时保持之后的显式暂停优先。两个受控回归通过，真实服务复测继续保存于 `voice134-alignment`。

原三格式新增 19 语言的 114 次三分钟验收独立记录在 [语言验收](../iOS-28-language-acceptance.md) 与 `acceptance-current.json`。音色页 UI 检查不抵扣这些播放时长。音色页布局与交互检查已完成并明确记录范围；原任务 114 项三分钟长测全部完成，客户端验收交付完成。

架构契约复核见 [architecture-review.json](architecture-review.json)；原始需求见 [android-README.md](android-README.md)。未进行 App Store 上传、送审或线上发布。

可随源码交付的公开截图节选见 [截图索引](../ios-28-language-evidence/README.md)。
