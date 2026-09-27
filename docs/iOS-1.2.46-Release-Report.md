# iOS 1.2.46 Safari 发布记录

状态：**1.2.46（69）已于北京时间 2026-09-27 12:51:55 提交审核，版本和审核单均为 WAITING_FOR_REVIEW；审核通过后自动发布。尚不代表已上线。** Build 68 未送审。最终源码 `3051b15` 已合入并推送主线；Build 69 最后一次真机目测未完成的边界见下文。

## Build 68 集成基线和设备支持

- 本轮 ASC 回读线上 1.2.45（67）为 `READY_FOR_SALE`，最大已上传 Build 67，无活跃审核单。线上源码在远端 `main` 的 `baccb69aacf845b348347015dd84af7879ae006d` 中。
- 从该远端主线建立 `codex/ios-release-1.2.46`，以双亲合并 `e1e10d988adc9d7612add70ebf37ecae6759aacf` 纳入 Safari 分支 `2b26f99`；版本配置提交 `9960e13`。此前已发布的 `b6dd4d7`、`fe64420`、`66fc2e1` 和全部基线脚本要求的提交均保留。
- **正式主线已快进并推送至 `3051b15`**，包括集成、版本、测试/商店记录和包装校验脚本。此后的报告更新不改应用源码。基于测试和真机包的 390 文件清单再次逐文件核对全部一致，主线不包含主目录旧分支的未提交改动。首次 Git 传输受本机代理影响（扩展分支 HTTP 408），回读旧远端引用后使用仅本次命令的直连重传成功，没有强推或改系统代理。
- App、Share、Widget、Safari 的 Debug / Release 全部统一为 **1.2.46（68）**，`TARGETED_DEVICE_FAMILY=1,2`。Safari bundle ID 为 `com.same.castreader.SafariExtension`，扩展点 `com.apple.Safari.web-extension`，由 App 依赖并嵌入 PlugIns，沿用 App Group 和专用 Safari Keychain。
- 原生 TTS、QuickRead、播放器、Kindle/WeRead/Kobo 等实现没有被旧分支替换。原生差异仅 Safari 会话投影、账户边界清理、URL 导航、设置跳转，以及对应工程、entitlements 和资源。
- 扩展源码提交 `31f8c7b`；完整 WXT iOS 输出与原生资源同步验证通过。生产 `content.js` SHA-256：`192e07f0e15b8ce27ec088b2e62e17ecdb5a9491235e8b2243153e523d333a75`，与前轮两台模拟器和用户手机已安装候选的修复脚本相同。没有临时 QA textarea 探针。
- 390 个应用/组件/工程文件的清单摘要：`151ee7dcacdf8ba4502637529ee48bec5116f17bfaac2a1924b6a417cd2dee9d`。逐文件清单保存在下方私有证据目录。

## Safari 和本地检查

- `build-voice-toc-integration.sh --check`、`verify_safari_extension.rb`、发布 preflight `--include-safari` 均通过。Safari 在未显式启用该参数的发布预检中仍默认禁止；启用后增加第四组件及 iPhone/iPad 入包合同检查，不豁免真实播放验收。
- 九种扩展语言的键和占位符一致。11 语商店文本均符合长度限制，最长描述 3,867 字符。
- 沿用同一应用源码/配置的有效 Safari 验证：Safari 180 项、Chrome 一致性 263 项，类型检查、折叠章节/视口恢复/像素回归；实际 iPad WebKit 浅深网页 × 浅深系统 × 词句绘制 8/8 通过。
- 最新普通包在 iPhone、iPad 模拟器的 Safari 真实云端朗读回归已通过，涵盖高亮、滚动、跨段、暂停/恢复、换音色、停止清理；iPhone 最终轮实际从 1x 改为 0.75x。iPad 最终轮选择的是原本的 1x，实际变速证据来自此前完整回归。详见 [Safari 高亮修复与验收](Safari-Highlight-Repaint-2026-09-26.md)，保留非 canonical Wikipedia URL 读到导航文字及未做声学逐字审校等限制。
- 2026-09-27 00:50 完成候选全量隔离单测：**1,890 PASS、0 FAIL、8 SKIP**，整轮 `TEST EXECUTE SUCCEEDED`，结果 `evidence/unit-tests/tests.xcresult`。跳过为既有需要显式启用真实服务/本机样本的用例，不当作真实核心格通过；PaymentTests 仍按原隔离脚本显式排除。使用专用模拟器应用/Keychain/App Group，没有在用户手机的正式 App 内执行会改变账户状态的单测；完成后已卸载本轮创建的模拟器隔离应用。
- Release 真机编译 `BUILD SUCCEEDED`。四组件代码签名 `--deep --strict`、版本/设备族、专用 Keychain/App Group、加密声明、九语编译资源、最新 content.js 哈希检查通过。`verify_release_no_shelf_fixtures.py` 扫描 204 文件 / 54 个标志，Debug 阳性对照有效，Release 夹具命中 0。`CastReaderInternalDistributionControlsEnabled` 实际为字符串 `NO`；第一次人工审计只接受 Bool false 而触发断言，随后依项目既有校验合同同时接受 false/NO，未修改二进制或降低产品要求。

## Build 68 真机与正式配置

- 设备：iPhone 15 Pro Max，iOS 26.7 beta（23H24），CoreDevice `8D96EFB3-DBC1-52E3-B10D-412C1059D28E`。本轮通过 iPhone Mirroring 进行实际界面操作；历史锁屏/辅助控制限制已解除。
- 09:22–09:25 使用正常 **Release 配置、开发签名**的 1.2.46（68），Safari 进程路径确认属于当时容器 `03A51D29-10B2-47E4-9DB0-4F40F735DFAC`。刷新用户默认 canonical Wikipedia Reading 页面后，Heart 1.25x 朗读、逐词更新、自动展开/滚动和跨段有效；暂停保持词和视口，改为 0.75x 后继续，切换 Bella 后继续；关闭 X 后词与段落背景全部清除。本次未再观察到用户报告的残留或无高亮。证据：`iphone-mirroring-20260927.json`，并保留镜像观察。
- 09:34 暂装同一冻结应用源码的 Debug 开发签名包，用于取得真实请求和播放器日志。09:46 起显式使用 `-CastReaderDisableDebugPro` 禁用历史遗留的模拟 Pro 设置；没有注入音频、假账号或绕过鉴权。国际线路通过 `-CastReaderRegion global -CastReaderServiceRoute global` 选择实际国际服务，解读输出为 en。
- 10:16 已恢复正常 **Release 配置、开发签名**的 1.2.46（68）；新容器 `991E8A62-E68F-47F2-9800-ABE598CA0906`。未启用调试启动参数；自然按 CHN storefront 进入中国线路。正式配置补验社区→私人朗读、私人解读从首块进入第 2 块，原文圈注/下划线及讲解字幕可见。此包不是 App Store 分发归档。
- 手机第二个同名应用是旧隔离包 `com.same.castreader.releasechecks1244` 1.2.44。本次始终安装、启动和验证正式 bundle `com.same.castreader`，没有删除旧应用或用户数据。

## Build 68 核心服务门禁

全部应用源码/配置仍匹配 390 文件冻结清单（10:15 再次逐文件校验），不存在用旧版本测试代替新候选的情况。以下 PASS 基于真实服务请求、音频队列完成/后续段块推进和镜像产品效果共同确认；不等同于声学逐词审校。

| 地区 / 语言 | R-K | R-C（vl / vc） | E-K | E-C（vl / vc） |
| --- | --- | --- | --- | --- |
| CN / zh | PASS：`zf_001`；第 4→6 段、高亮、暂停/继续和完成 | PASS / PASS：`vl_b4bb75aa2d3e56fd90a2` / `vc_63a448ca35794f57b0aea0e189a68cb3`；实际新生成、跨段和切回常规 | PASS：新 QuickRead 5 块、讲解与原文不同、原文圈注/下划线、0→2 块 | PASS / PASS：社区 2→4 块；私人第 4 块至完成，Release 补验私人 0→1 块；切回常规 |
| International / en | PASS：`af_bella`；逐词高亮、11→18 段、暂停/继续 | PASS / PASS：`vl_d1efb23a380bdaa2f6b0` / `vc_62934fe77f764051aa341b4b076bbb85`；新生成、多段播放、切回 Bella | PASS：新 QuickRead 6 块，英语字幕、原文标注、自动续块 | PASS / PASS：社区重播 0→1 块；私人 2→4 块，切回 Bella 后 4→5；原文标注和字幕持续推进 |

- 中文自有样本：7 段、533 字符，文档 `9FF2D864-51CA-4A7A-8710-9BBEF9ED3014`，指纹 `600f7ce034072e9d`；英语自有样本：19 段、1,400 字符，文档 `218F8021-84EA-408D-ABEB-B32A4FDF0583`，指纹 `3c53af97e197f6b1`。没有上传客户私有正文或录音。
- CN：09:49–10:00；TTS `api.castreader.cn`，QuickRead `quickread.castreader.cn`。新 job `qrc_s6kp6xCYmoIM3naKPtNop8lZHxDfTxyS`，plan 09:57:09.540，首块播放 09:57:18.229，原文 mark 09:57:18.740，实际 extract-block/compose 后推进。常规请求示例 `AF3FC937-2DC4-4AD9-9629-B9366B1F976F`；社区解读 `E4A67CC3-8066-4FF7-8D0D-CB5E2118E093`；私人解读 `FF0209CD-BE7B-431F-B63C-7EFBB621D4A7`。
- Global：10:02–10:15；账号/QuickRead `api.castreader.ai`，常规 TTS 实际使用 `tts.castreader.ai`。新 job `qrc_72DdLT5TnWWFnTqXPO3pYZzEPocptr_y`，plan 10:08:23.578，首块入队 10:08:31.332，mark 10:08:32.000；真实 extract-block/compose 6 块。常规请求示例 `8669519E-6D37-4964-AD21-EEB244743058`；私人后续讲解 `D9998769-5F7B-4111-8C8B-1D3E504A3BB6`。
- 用户明确授权后，为同一 CN 测试账号恢复一次 24 小时免费测试 Pro：`ios1246-cn-test-20260927`，截至北京时间 **2026-09-28 09:40:33**；0 元、无续订，原 6 条订阅记录在事务中核对未变。服务端 Pro=Y，普通声音不扣克隆额度，克隆成功请求返回真实剩余额度。CN 从 7,200 秒开始；09:56 7,147 秒，10:00 6,878 秒；Global 从约 71 分钟到 67 分钟。未重置或透支个人余额。
- 两模式覆盖常规→社区→私人→常规、暂停/继续、当前位置/后缀保留、读/解读互切和旧标注清理。英文解读暂停后换回 Bella，准备完成仍暂停（入队 auto=N），明确继续后播放与续块。实际冷准备未遇到，本轮记录为 warm；准备中暂停、旧响应、失败恢复、额度 unknown/zero、预读并发等确定性分支沿用同候选全量单测，不伪报为生产冷启动测试。
- 持续操作期间界面保持可响应，未观察到崩溃或 watchdog；未做声学逐词校对或专门的内存压力基准，不据音频文件大小推断资源表现。
- 私有证据：`cn-core-evidence-summary.json`、`global-core-evidence-summary.json`、`native-cn-suffix-private.log`、`native-global-suffix-private.log`、对应当前进程 console，以及最终 `final-release-console-private.log`。ReaderRunLog 历史文件按本次基准字节偏移截取，避免仅以无日期时间过滤而混入旧记录。

## Build 69 修复与 App Store 提交

### Build 69 用户反馈修复

- 首页根因：iOS 26 iPhone 使用独立悬浮 `UITabBar`，外层 NavigationStack 的安全区没有传入首页 ScrollView；原有避让只计算迷你播放器，无播放器时为 0。现在同时测量 Tab 和播放器上边界，取遮挡区域并集，避免重复叠加；iPad/系统 Tab 不添加虚构高度。
- 原生朗读根因：当前段显示 `processedDisplayText` 的已生成前缀，未生成的句子被暂时删除，随后逐句增长，导致下方内容位置变化。原生正文固定为完整段落；音频时间戳/恢复游标仍使用 processed 坐标，只在最终显示时做有验证的范围投影，兼容空白/标点规范化、重复词与 UTF-16。移除每次分句到达触发的额外重定位。
- 同一候选全量隔离单测 **1,893 通过、0 失败、8 条件跳过**；新增真实 `ReaderUITextView` 布局测试验证四次分句到达前后正文高度、下一段 Y 坐标不变及高亮正确。iPad 上 `ReaderViewportTests` **10/10** 通过。
- 随后收紧重音字符快捷路径：必须 UTF-16 单元完全相同才能复用字符偏移，不能只依赖 Swift String 的规范等价。最终源码 `3051b15`，修正后的完整布局套件再次 **10/10** 通过（含分解/组合重音、完整正文高度、相邻段位置、高亮、自动滚动、PDF 和 EPUB）；该行测试不重复计入全量结果。
- Build 69 普通 Release 开发签名包已安装到同一 iPhone，容器 `6DA0D952-A786-4C9F-A381-BB824D84180F`；App/Share/Widget/Safari 均为 69、设备族 1/2、签名检查通过。最终镜像连接因手机使用中超时，命令启动返回 Locked，因此 **Build 69 新布局的最终真机目测未完成，不记为 PASS**。用户随后明确要求“你就直接提交那个 APP Store 审核吧”，继续提交该修复候选；保留此验收边界。
- 390 个应用/配置文件冻结摘要：`ddc20ea633f7bbf5a836c168d856d9f02f9854f38e0c9d79d2320c0b430f5016`；相对 Build 68 仅工程 Build 号、原生正文投影、Tab 避让和一处游标注释改变。TTS/QuickRead/API/播放队列/Safari 资源未改，上方 Build 68 的真实服务记录保留其原始范围。
- 最终归档：`CastReader-Safari-Release-20260927/CastReader-1.2.46-69.xcarchive`。归档四组件签名/设备族/版本/九语资源/扩展 SHA-256 与冻结源码校验通过；扫描 203 文件、54 个夹具标志，Debug 阳性对照有效，Release 0 命中。最终归档中的开发签名 App 已于 12:36 安装成功，替换早先 Build 69 包，容器 `F58BF550-7C13-4520-9CC7-2296D45D68B7`；包括最终重音字符边界修正。

- 版本 ID：`f835f4df-b17b-4c1b-a71f-50de22006ae7`，最终状态 `WAITING_FOR_REVIEW`。
- 待发布 App Info：`a3a05161-de19-4dd4-8c99-363187f758c7`；线上基线 App Info：`62ad576b-3ab7-4759-bf88-05840a7647eb`。
- 已 PATCH 并回读 11 语 `description` 和 `whatsNew`：仅增加 Safari iPhone/iPad 功能和启用说明。标题、副标题 11/11 保留，关键词、推广文字、支持链接、营销链接逐字段未变。文案：[What's New](AppStore-Whats-New-1.2.46.json)、[Safari 描述增量](AppStore-Safari-Description-1.2.46.json)、[完整当前文案](CastReader-AppStore-Metadata-1.2.46.md)。
- 审核说明将旧版本开头摘要压缩为本版 Safari 启用、网站授权和核心控件测试步骤，保留账户/审核资料及其它审核说明；共 3,939 字符，回读一致。首次尝试因追加后超长而在本地拒绝，未提交超长内容。
- 现有 55 张截图保留，草稿逐张回读全部 `COMPLETE`；`zh-Hant`、`es-MX` 沿用主语言回退。不改价格、订阅、地区、隐私、年龄分级、类别或法律声明；继承审核后自动发布 `AFTER_APPROVAL`。
- Build 68 已于北京时间 2026-09-27 10:33:46 由官方 Xcode 上传成功，ID `4b525c72-7f4c-4cfa-b88b-0fca74894734`；因用户随后报告布局问题，该 Build 不绑定、不送审。
- 最终 Build 69 于 **12:42:21** 经官方 Xcode 上传成功，ID **`5db69625-49f7-4f61-ad16-e591ae07d047`**，Apple 回读 **VALID / APP_STORE_ELIGIBLE**，非豁免加密 false。绑定和最终 audit 通过：11 语、标题/副标题逐项保留、55/55 截图 COMPLETE、审核联系人完整；沿用原有 `demoAccountRequired=false`，未填入或公开私人账号密码。
- `submit_review.rb` dry-run 检查无其它活跃审核冲突后正式 execute。审核单 **`dbe9c7b9-9cc8-4aa1-a78e-0f4dfd0d962f`**，提交时间 **2026-09-27T04:51:55.133Z（北京时间 12:51:55）**；版本和审核单均回读 **WAITING_FOR_REVIEW**，发布方式 **AFTER_APPROVAL**。没有将“上传成功”当作“提交成功”。

## 证据

私有原始证据目录：`/Users/xuxuheng/Desktop/CastReader-Safari-Release-20260927/evidence/`。包含一次 ASC inspect、商店基线快照、草稿创建结果、预检、应用源文件摘要、元数据回读、测试日志和编译日志。审核账号、会话和凭据不写入仓库。

Build 68 原始服务验收与归档保留。最终 Build 69 证据包括 `candidate69-source-identity.json`、`build69-acceptance.json`、`build69-unit-tests/summary.json`、`build69-final-layout-summary.json`、`build69-ipad-layout.xcresult`、`archive69-package-audit.json`、`archive69-fixtures.json`、`build69-final-install.json`、`export69-upload.log`、`build69-status.json`、`asc-final69-audit.json`、`submit69-result.json` 和 `post-submit69-readback.json`。保留真实服务证据与最终渲染真机复测限制的区别。

参考 [Apple 的 Safari 扩展分发文档](https://developer.apple.com/documentation/safariservices/distributing-your-safari-web-extension)：iOS 扩展随包含它的签名 App 分发。本版设备支持由通用 App、Safari target 和嵌入扩展配置共同保证；没有把 macOS 独立应用当作 iPhone/iPad 安装包。
