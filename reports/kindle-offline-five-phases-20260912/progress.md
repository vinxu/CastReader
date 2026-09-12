# Kindle 离线朗读：实现与验收记录

更新：2026-09-12。当前是 DEBUG 内部验证版本，支持独立的已确认页面；整本书保存尚未完成。

## 基线

- 工作树：`/Users/xuxuheng/Documents/.worktrees/CastReader-kindle-offline-five-phases-20260912`。
- 分支：`codex/kindle-offline-five-phases-20260912`。
- 集成前快照：`5f863c4ba9692ab51c9cf1ee318cad63a17d2c92`，祖先包含已验证发布提交 `b6dd4d7`。
- 快照包含指定发布工作树当时的更多 / Aa / 睡眠定时等增量；866 个受核对文件一致，见 `release-source-manifest.json`。
- 本轮增量在独立工作树完成，没有用旧离线原型整文件替换 Kindle 导航、字号重排或播放器。
- 每次真机包先执行 `scripts/build-reader-more-integration.sh --check`，再执行该脚本的 `--device`；通过 `CASTREADER_DEVICE_DERIVED_DATA` 使用独立构建目录。

## 本轮已实现

1. 系统 TTS 直接播放原文字串，使用系统 UTF-16 范围回调高亮，队列最多保留当前句及后两句。不生成 WAV，不估算词时间戳。
2. 复用发布版当前页确认、捕获和 OCR，显式保存图片、文字及 OCR 定位数据。打开保存页只读取本机文件。
3. 内容存放于 Application Support，排除备份；资源摘要校验、索引最后原子提交、进度独立写入；显式保存不参与 LRU 清理。
4. 保存页按 CastReader 账号、Kindle 区域及本地绑定代次隔离。切换播放所有者、账号边界和睡眠到期均接入现有播放器控制。
5. 暂停、换声音、换语速和前后句控制；重启从最近确认句首继续，允许重复当前句。
6. Kindle 书架中增加 DEBUG 已保存页面入口，不必先重新打开在线 Kindle 网页。
7. 单独的 Page Flip 只读探针：不自动翻页，保留中途导航变化、丢事件和观测失败，不能因最终回到原页而掩盖中途风险。

## 本轮发现并修复的问题

| 问题 | 修正 | 验证 |
|---|---|---|
| 默认声音选到了 Albert，听感异常 | 排除 novelty / personal voices，优先系统同语言常规默认声音 | 模拟器切到 Samantha 后用户确认“现在正常”；自动化检查可选音色及默认排序 |
| 真机系统朗读启动失败 | `.playback + .spokenAudio` 使用空 options；移除不适用于该类别的显式 `allowAirPlay`，共享播放器同步修正 | 修改后真机成功启动并持续收到范围回调；错误保留具体 audio-session code，避免笼统吞错 |
| 冷启动恢复到第 8 句，但正文仍在顶部 | 阅读内容初次挂载时也根据句子所在段落滚动 | v4 真机重开后，第 8 句所在段落显示在阅读区域 |

Apple 对 `allowAirPlay` 的说明：该显式选项仅适用于 `playAndRecord`，其他支持的类别会隐式提供 AirPlay 输出。[Apple API 文档](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/allowairplay)

这里不将最初的人工听感反馈计为“真机断网验收通过”：当时正在操作模拟器。随后真机有独立画面与回调证据，真正断网的人工听感仍待验证。

## 真机记录

设备：iPhone 15 Pro Max，通过 iPhone 屏幕镜像操作。沿用设备已有账号和数据，没有卸载 App。

| 场景 | 结果与证据边界 |
|---|---|
| 当前页保存 | 《A Journey to the Centre of the Earth》1 个确认页面，531,126 字节，7 个 OCR 段落、209 个 OCR 词；图片与文字快照 SHA-256 均校验通过 |
| 系统声音启动 | Samantha；一次运行首个启动回调约 50 ms，110 次文字范围回调，页面高亮持续推进。50 ms 是回调延迟，不是实测声学首声延迟 |
| 句子断点 | 暂停在第 8 / 11 句；持久化 `paragraphID=4, sentenceStart=0`；终止并重新启动进程后仍恢复第 8 句，且保持暂停 |
| 正文恢复 | v3 重开未滚动，v4 已修复并在真机确认 |
| 短时后台 | 从第 8 句开始后返回 iPhone 主屏幕；系统继续读至第 11 句，记录 91 次范围回调、状态 finished；回前台定位末句。此项不代表 60 分钟锁屏测试通过 |
| Page Flip 观测 | 当前静止阅读页 47 个事件、无溢出、导航序号保持 0、原页与结束页一致；未观测到多页网格，结论仅为 notObserved |
| 严格断网冷启动 | 待测。以上真机日志的网络可用提示均为 true，不以“代码只走本地”替代断网实测 |

源页面首次打开出现 Amazon 位置同步提示：当前 1984、最远 2011；选择保留当前页。没有将书架缓存中的旧位置标签当成当前页证据。尚未验证整书采集对 Amazon 最远已读进度的影响。

当前 CastReader 会隐藏源网页工具栏。静止页未出现 Page Flip，不能据此断言 Kindle Web 不支持 Page Flip；还需在可见源控件环境中打开并验证候选入口，或取得逐页路线的起点、相邻页和终点证据。

## 自动验证

- 165 项选定回归通过：系统语音、Page Flip 模型与 WKWebView 脚本、保存页仓库、播放所有权与失败恢复、睡眠定时、流式暂停意图、账号内容隔离、Kindle 导航/字号所有权、阅读恢复、WeRead 开书恢复。
- 音色修正后 10 项系统语音测试通过。
- 音频会话修正后 32 项选定回归通过，其中 11 项系统语音测试，另含音频所有权、失败恢复与睡眠定时。
- v4 真机 test-build、安装与启动通过；首次滚动恢复通过真机 UI 验证。这次滚动修改没有添加镜像实现的单元测试。
- 上述均为选定测试，不代表全工程测试或完整真机验收已通过。
- Release 编译结果另见本目录 `validation-evidence.json`。

本机原始证据：`/tmp/CastReaderKindleOfflineP1Regression.xcresult`、`/tmp/CastReaderKindleOfflineSessionTests.xcresult`、`/tmp/CastReaderKindleOfflineDeviceBuild-v4.log`、`/tmp/CastReaderKindleOfflineReleaseBuild.log`。摘要保存在本报告目录；原书图片、OCR 正文、账号信息与认证数据不加入报告。

## 五阶段状态及接续顺序

| 阶段 | 当前状态 | 下一退出条件 |
|---|---|---|
| P0 路线验证 | 进行中；系统声音及当前页捕获已有证据，整书路线未定 | 真机断网中英文语音；有效 Page Flip 入口或逐页路线；确认 Amazon 进度副作用 |
| P1 小范围闭环 | 内部实现已可测试，尚未验收完成 | 断网终止重开 → 本地页与第 8 句恢复 → Samantha 朗读与高亮；补充真机睡眠、音频中断、耳机控制 |
| P2 整书保存 | 尚未开始正式驱动实现 | P0 路线通过后实现分页 journal、完整覆盖证明与断点续传；300 页书中断测试 |
| P3 用户功能 | 尚未完成 | 正式保存入口、按书组织、容量管理与删除、目录、所有支付来源的离线 Pro 权益；处理解绑后的旧绑定资源 |
| P4 扩展与发布验证 | 尚未开始 | 长书、多语言、书型矩阵、60 分钟锁屏与性能回归；是否发布由后续发布任务决定 |

断网测试已向用户请求协助：控制中心关闭蜂窝数据并断开 Wi-Fi 网络，保留 Wi-Fi / 蓝牙开关供镜像使用。等待设备状态确认期间保留第 8 句暂停断点。镜像不能打开控制中心时，不关闭 Wi-Fi / 蓝牙无线电来冒险切断控制连接。

下一轮先完成这一个真实断网场景，再收敛整书获取路线。单页闭环不标记为整本书离线功能完成，P2–P4 不以代码数量或保存页面数量替代退出条件。
