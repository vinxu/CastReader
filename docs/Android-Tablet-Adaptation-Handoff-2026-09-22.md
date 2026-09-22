# CastReader Android 平板完整适配交接：对齐 iOS 1.2.43

文档日期：2026-09-22。用途：Android 开发、测试和发布共同使用的实施依据。

**交付目标：同一 Android 应用同时支持手机和平板，保留最新手机版本全部功能；旋转、分屏、窗口缩放和多文档窗口不丢阅读位置、不抢音频、不串账号。** 本文件是 iOS 实施复盘与 Android 待实施规范，不是 Android 已完成适配的证明。本次仅交付文档，没有修改 Android 产品代码、构建、安装或发布。

配套文件：[实施任务表](Android-Tablet-Implementation-Tasks-2026-09-22.md)、[验收清单 CSV](Android-Tablet-Acceptance-Checklist-2026-09-22.csv)。CSV 中 Android 状态统一从 `NOT_RUN` 开始；iOS 的 PASS 不能复制为 Android 的 PASS。

## 1. 先确认版本、事实与边界

### 1.1 iOS 可参考的最终基线

| 项目 | 已确认事实 |
| --- | --- |
| 版本 | 1.2.43（65），同一 Bundle ID `com.same.castreader` |
| 最新 iPhone 基线 | `8298f84`；应用源码祖先 `1ce1e56`，保留 1.2.41/1.2.42 全部已合并功能 |
| iPad 功能分支 | `codex/ipad-adaptation`，最终功能提交 `bcd9778` |
| 最终应用整合 | 主线合并 `fe64420dad87d7262c3d7de144a4b30c5ee7feb3`；送审回执文档提交 `33d6001` |
| 应用/配置身份 | 309 文件；SHA-256 汇总 `a08ee45fbac599cf4e21e97fa6f136dcaf9c777e00ef539f14dd1c2ac8b30466` |
| 送审结果 | 2026-09-22 09:08:47（上海）提交，版本和审核单均回读 WAITING_FOR_REVIEW，审核通过自动发布；这是当时状态，不代表已上线 |
| 平板实际环境 | 同一台 iPad Air 11 英寸 M3 模拟器、iPadOS 26.5；实际窄窗口 375×497 pt |
| 最终手机服务验收 | iPhone 15 Pro Max / iOS 26.7，CN/中文与 Global/英文，朗读/解读的常规、社区、私人声音均真实生成并播放 |
| 回归 | 平台共享合同 276/276；发布最终隔离单测 1,857 通过、0 失败、8 跳过，另排除会改变真实账号的 PaymentTests |

最终报告是状态权威：[iOS 1.2.43 发布报告](https://github.com/vinxu/CastReader/blob/33d6001/docs/iOS-1.2.43-Release-Report.md)。早期计划和交付记录中的“未发布”“仍为 1.2.42”属于阶段历史，不能覆盖最终报告。

### 1.2 iOS 已做与未做必须分开

**已有实际证据：** 四方向导航；原生文本/EPUB/PDF/扫描页/照片/DOCX/网页重排；Kindle、Google Play 图书、Kobo、微信读书的真实账号书架、朗读/解读、可见高亮/标注、自然续页、目录、Aa、迷你播放器；真实窄窗口、多窗口音频交接、进程恢复；最大辅助字号/深色、30 次旋转；中英文各 5 张 iPad 商店图。

**未被这次 iOS 结果完整证明：** iPad 真机、其他尺寸/旧 iPadOS、60 分钟能耗与性能、真实相机/实体多页扫描、Pencil/触控板/外接屏、完整 VoiceOver、完整购买退款矩阵、全部云盘 OAuth。O’Reilly 未连接且无缓存书籍，只有本地合同，没有真实账号正文验收。硬件键盘 Space 通过；Command/Escape 验证未通过，系统 TextEditor 的 Command-A 对照也失败，根因没有完全归属，不能算通过。未执行旧 iPhone-only 包到通用包的完整降级再升级实验。

Android 必须补齐目标设备上的相应验证；不得把“iOS 没测到”作为 Android 可以跳过的理由。缺账号/硬件写 `BLOCKED` 并明确范围，不能写“全部平台完美支持”。

### 1.3 Android 本次静态调查基线

调查工作树：`/Users/xuxuheng/.codex/worktrees/android-import-repair-20260920/CastReader-Android`，HEAD `63341f991f72a973098e87c8f8d8de26fa0e0013`，应用候选 `d4e63164898e850ea5d56671acaa084e1145e0ef`，1.0.53（60）。其本地报告记载 9 月 20 日提交 Play；本次没有读取 Play/CN 当前线上状态。**实施前必须重新确定最新线上源码、已占用版本代码和待合并功能，不能将这个调查快照当作未来打包基线。**

主目录 `/Users/xuxuheng/Documents/CastReader-Android` 有大量既有未提交工作，不能覆盖、清理或直接拿来发布；其旧 AGENTS 部分架构说明与现代码不一致。本文件以实际源码为准。

| 已观察到的 Android 现状 | 对平板适配的含义 |
| --- | --- |
| `app/build.gradle.kts`：minSdk 24、compileSdk/targetSdk 36、版本 1.0.53/60、包名 `com.same.castreader` | 已进入 Android 16 的大屏行为范围；不是先提高 target 才需要适配 |
| `MainActivity` 的 YouTube 活跃会话请求竖屏，收起后仍保留锁定 | 平板窗口不能继承手机方向策略；字幕会话必须支持重新布局 |
| `ReaderShell` 依据 orientation 选横/竖播放条；部分宽度按 `screenWidthDp * 0.68` | 横屏、短窗口、分屏、内层阅读栏必须分别测量，不能只靠方向 |
| Manifest 的 MainActivity 是 `singleTask`，声明大量 `configChanges` | 现有深链复用与多个独立文档窗口存在设计约束；不能只改 launchMode 就宣布多窗口完成 |
| `DocSession` 是保存单个不可变快照的 `@Singleton`；替换会清理原 owned 临时文件 | 当前单文档原子交接要保留；多窗口需按会话分区并增加文件引用所有权，避免 A 导入删除 B 正在读的文件 |
| `PlayerCoordinator` 是全局单个 route/stopper/handoffStopper；Read 全局服务与部分 Explain VM 分工 | 需要跨所有实际播放器的唯一播放租约；不能把 route 字符串当窗口身份 |
| 已有 checkpoint、商业书籍恢复、TTS scheduler、离线、原生 PDF/EPUB、声音续播实现 | 增量接入，不从旧分支整文件覆盖，不重新发明已有恢复/计费管线 |
| 依赖目录是 Compose BOM `2024.09.00`、Navigation `2.8.4`，未见 Material3 adaptive 依赖条目 | 先验证依赖兼容再使用新 API；不要将官网示例直接粘进现有工程 |

以上是静态风险定位，除已有历史报告外，不代表本次在 Android 平板上复现了缺陷。

## 2. 对齐范围与不变的产品合同

### 2.1 必须完整覆盖

| 范围 | 对齐内容 |
| --- | --- |
| 首页/导航/文库 | 已登录/未登录、空状态、继续读、真实书架、历史、搜索/排序/分页、设置、导入、迷你播放器 |
| 导入 | 文本、链接、剪贴板、文件、图片、相机/多页扫描、云盘、系统分享、跨应用拖放；取消/失败/重复/迟到回调 |
| 原生阅读 | 文本/Markdown、EPUB 目录与插图、PDF 原页/文本重排/扫描 OCR、照片、多页内容 |
| 在线阅读 | 普通网页、DOCX、Kindle 在线/离线、微信读书、Google Play 图书、Kobo、O’Reilly、YouTube 字幕 |
| 阅读控制 | 朗读/解读切换、逐词或按真实时间戳粒度高亮、自动跟随、解读原文标注和完整字幕、暂停、前后段/页、音色/语速/Aa/目录/更多/定时 |
| 声音 | 常规/社区/私人/已有赠送声音；试听、选择、准备、创建/上传、管理、分享；保持区域能力门禁 |
| 账号/付费 | 登录/登出/切账号、Pro、免费与克隆额度、购买/取消/恢复或现有权益恢复入口；授权弹窗属于发起窗口 |
| 系统集成 | 现有深链、通知/媒体控制、分享接收、文件权限、后台播放、已存在的 Widget/快捷入口；iOS App Intents 按 Android 对等能力映射，不照搬名称 |
| 大屏输入 | 旋转、分屏、自由窗口、折叠展开、多个文档、外接键盘/鼠标/触控板/系统笔输入、TalkBack、大字号、减少动画 |

各地区只展示现有允许的能力。尚无业务能力的入口不能因“适配”擅自加上，更不能拿一个空面板算完整实现。Android 本身缺失的对等功能需另列 GAP 并给出处理决定。

### 2.2 不变项

1. 同一发布渠道内手机和平板用同一包名、签名、账号和订阅体系，不增加独立 Pad SKU。Global/CN 仍按现有 flavor/线路规则发布，不相互覆盖用户数据或跨区回退。
2. 朗读是“声音 + 对应粒度高亮 + 自动跟随”；解读读的是讲解，标注画在原文上。播放请求 200、试听成功、按钮显示暂停，都不能代替真实播放推进。
3. 排版变化不是新内容：不得重建讲解计划、重新读开头、重复计额或把暂停变成自动播放。确需重新合成时遵守现有缓存/幂等和计费合同。
4. 多个窗口可浏览不同文档，任何时刻最多一个主内容音频所有者；试听也必须有明确的借用/恢复规则。
5. 不承诺新增跨设备文件/离线缓存/全部进度云同步；同账号权益一致与云同步是两件事。离线能力按现有实际内容与音频缓存定义。
6. 首版默认稳健的单栏正文、PDF 单页；不强行增加双栏编辑、任意手写笔记、独立桌面产品或移动 Safari 扩展。

## 3. Android 窗口架构

### 3.1 先按窗口测量，再决定布局

Android 16 / target 36 对最小宽度至少 600dp 的大屏会覆盖部分方向、宽高比和不可缩放限制。不要把锁竖屏或兼容黑边当最终方案；应适配系统实际给出的窗口。[Android 官方行为说明](https://developer.android.com/develop/adaptive-apps/guides/app-orientation-aspect-ratio-resizability)

采用当前窗口的动态宽高分类，阅读器还要测量扣除导航、控件、字幕、系统栏和 IME 后的实际内容区域。尺寸是 dp；文字是 sp；WebView CSS px、位图 px、PDF 页坐标须显式换算，**不能把 iOS pt 常量直接复制成 Android dp**。[Window size classes](https://developer.android.com/develop/ui/compose/layouts/adaptive/use-window-size-classes)

| Android 可用窗口宽度 | 建议产品结构（待实机调参） |
| --- | --- |
| <600dp | 单栏、紧凑导航；临时目录/声音/设置面板 |
| 600–839dp | 导航 rail 或可收起导航，正文居中；辅助面板先保证正文最小宽度 |
| 840–1199dp | rail/展开导航与正文；按需显示一个辅助面板 |
| 1200–1599dp | 允许正文加一个停靠面板，避免正文无限拉长 |
| ≥1600dp | 保持阅读行长，分配导航/正文/辅助区；不是把所有面板默认展开 |

可用高度不足、IME 出现、最大字号时优先折叠辅助内容和装饰，不缩小主要点击目标。高度 <480dp 是重点测试区；窗口外观横屏不保证内部阅读区宽或高。

iOS 最终实现的参考参数为普通页最大 1100pt、阅读栏 800pt、<500pt 宽时堆叠播放条；这些是已验收 iOS 参数，不是 Android 规范。Android 正文宽度可从约 720–840dp 原型开始，最终以行长、字号和实机为准。

可评估 `currentWindowAdaptiveInfo()` 与 `NavigationSuiteScaffold`，把布局参数传给现有页面；导航形态变化复用同一 route、会话和状态。[官方自适应导航](https://developer.android.com/develop/ui/compose/layouts/adaptive/build-adaptive-navigation)

系统栏、任务栏、窗口标题栏、手势区、IME 遮挡要在同一层明确消费，避免父子重复扣减。[Compose WindowInsets](https://developer.android.com/develop/ui/compose/system/insets)

### 3.2 状态归属必须拆清

```text
Application scope
  账号/地区与 accountEpoch、内容仓库、额度、缓存
  唯一主音频输出 + PlaybackLease(owner, generation)
                         ↑ 显式播放/试听交接
  ┌──────────────────────┴───────────────────────┐
Window/Task A                              Window/Task B
  导航、文档会话、模态、草稿                  各自独立
  当前 viewport / layoutEpoch              各自独立
  语义阅读锚点、Read/Explain 状态             各自独立
  可持久化最小书签                           各自独立
```

建议合同名称仅为设计接口，**不表示这些类已在 Android 实现**：

```text
SessionKey = accountScope + documentId + windowSessionId
PlaybackLease = sessionKey + mode + playbackGeneration
GeometryStamp = sessionKey + providerFrameId + layoutEpoch + sourceFingerprint
Checkpoint = documentRevision + semanticAnchor + segmentIdentity + elapsed
             + voiceId + mode + explicitPauseIntent
```

- `windowSessionId` 应有可恢复的业务标识，不能只依赖可重用的系统 taskId；窗口恢复书签绑定账号和文档版本。
- 浏览 B、打开 B 的声音列表、B 重组或 `onCleared` 都不得停止 A。只有明确播放/恢复动作才 checkpoint A、撤销旧租约、交接到 B。
- 所有旧回调——TTS、preview 完成、OCR、页面提取、翻页、字幕、关闭、购买返回——核对账号代次和所有权。过期事件不清新队列，不覆盖新文档。
- 沿用现有 AudioPlaybackService 生命周期和通知实现，统一仲裁 Read 与实际 Explain 播放器；本次不为“架构好看”顺带改成另一服务类型。
- 模态、文件结果、OAuth/购买 Activity Result 使用发起窗口/账号上下文。窗口销毁或账号改变后按明确规则丢弃或入收件箱，不落入当前随便一个窗口。
- 同应用多实例需设计独立文档 Activity/task 与深链分发；保留主入口 `singleTask` 的兼容行为或引入专用文档宿主，先做原型验证。打开两个 Composable 不等于两个系统窗口。

`configChanges` 不是持久化方案。`ViewModel` 保留配置重建状态；`SavedStateHandle`/`rememberSaveable` 只放小状态/ID；正文、图片、音频和文档文件使用现有持久仓库，不能塞进 Bundle。进程恢复默认暂停，显式恢复播放才继续。[保存 Compose 状态](https://developer.android.com/develop/ui/compose/state-saving)、[配置变化](https://developer.android.com/guide/topics/resources/runtime-changes)

分屏中失去焦点不等于用户停止播放；区分可见性、窗口销毁、后台、音频焦点和用户意图。两个 Activity 都活跃时仍遵循唯一播放租约。[多窗口生命周期](https://developer.android.com/develop/ui/views/layout/support-multi-window-mode)

## 4. 旋转、重排与阅读恢复的核心算法

### 4.1 分开保存语义与几何

| 内容 | 语义锚点 | 仅属于本轮布局的几何 |
| --- | --- | --- |
| 文本/EPUB | 文档版本、稳定段落身份、processed text 字符/词、音频片段 | TextLayoutResult、glyph/行矩形、滚动偏移 |
| PDF/照片 | 页身份、页内归一化位置/文字范围、相对缩放、用户视口中心 | 当前 page→view 矩阵、裁切、安全区、位图缩放 |
| Kindle OCR | 原 spoken/explained scope、词序列、上下文、首个未消费词 | 新 OCR 投影、跨行词框、页图/单双页 viewport |
| Google/Kobo DOM | 可验证 source 身份与范围、唯一精确文本上下文 | iframe 坐标、CSS columns、祖先裁切、可见 Range 矩形 |
| 微信读书 Canvas | 原文范围、词或句子锚点、严格上下文摘要 | 当前 Canvas 字形/列/页、绘制代次 |

native 与 JavaScript 范围统一明确采用 UTF-16 或其他约定；转换处覆盖 emoji、代理对、组合字符、中英混排。源段落 ID 可能稀疏，不得当数组下标。

### 4.2 一次重排事务

```text
捕获真实 viewport 变化 → layoutEpoch 加一
  → 保留当前语义 source、播放租约、暂停意图、marks ID/seed
  → 作废旧 geometry / OCR / JS 结果；合并连续尺寸事件
  → 等待有界的稳定可见内容提交（不能只等一次 resize）
  → 精确映射当前播放词/句或解读 mark
  → 重建几何并绘制；保持音频/生成状态
  → 消费重排新露出的未读/未解释尾部
  → 必要时再执行经过确认的真实下一页
```

失败时保留原 checkpoint、保持用户暂停语义并给出重新定位入口；不得静默跳到新页面开头。所有纠偏都有限次/超时，并校验 owner、baseline、相邻内容证据。不要为消除一个加载遮罩而取消导航提交门禁。

### 4.3 需要直接继承的具体规则

1. **朗读渲染与 TTS 同源。** processed text 被规范化后，不能把时间戳硬映射到旧原文。句级服务按句显示，不伪称逐词。
2. **解读 scope 不随 viewport 改写。** 讲解任务、marks ID 和确定性 seed 保留，仅重新投影矩形。完成的笔画不重复落笔，未完成的时序保持。
3. **Kindle 才使用其受控 OCR 容错。** 拆词/连字符/缺词用序列对齐，允许一个词对应多个行框；Google/Kobo/微信正文不继承 OCR 模糊容错。
4. **DOM 身份变化时仍须唯一精确匹配。** 可用明确的原文 overlap 或唯一完整短段标题补救；重复标题、歧义、改变过的文本必须拒绝。
5. **中文没有词时间戳时保存句子。** 句子自身的 hash 也计入足够上下文；相同已验证生成片段可保留比例时间，切分改变时回到已验证句首，不估算不存在的词索引。iOS 微信实现使用至少 32 个可验证语义字符等约束，移植时以当前源合同和回归共同确认，不能扩大为任意模糊匹配。
6. **暂停后的同一高亮也要重画。** DOM reset 之后，即使下一条高亮值与之前相同，也不能被 `distinctUntilChanged` 等过滤掉；seek 到暂停位置后主动绘制，不等待播放 tick。
7. **语义续读和物理翻页分别计数。** 新露出的尾部不等于下一页。验收必须记录真实翻页动作、稳定页身份、新 source 和新页高亮/ink。
8. **明确暂停优先。** 用户在 loading/waiting/边界暂停，后到音频、切模式、重排提交都不能自动开播。区分 requested、actual、buffering 和 userPaused。
9. **旋转时不每帧重新 OCR/TTS。** 只使受影响的几何失效；昂贵操作合并并淘汰旧代次。不能通过重建整个 WebView“恢复正常”。

## 5. 各页面和渲染器的实施要求

### 5.1 常规界面与导入

- 首页/书架：宽屏合理网格或列数，长标题可换行，空/加载/错误态有限宽；继续读与导入始终可发现。设置列表和最后一项为迷你播放器留实际 inset。
- 搜索/排序：IME 打开后首个结果、清空、排序和退出都可达；大字号时把易被系统隐藏的排序移入明确的可见入口。测试实际选择成功，不能只断言 menu 存在。
- 目录/Aa/语速/定时：与触发控件关联，限制宽高，短窗口可滚动；关闭后正文重新可操作。面板显示时遮罩下面的第三方控件不得接受触摸或无障碍点击。
- 录音/创建声音：介绍、录制按钮、时长、停止/重试均能在短窗口滚动到；旋转不重启录音，不丢上传任务；麦克风中断走明确恢复路径。
- 文件/照片/云盘：沿用现有格式解析、持久身份、远程引用规则，不把云文件来源降级成本地匿名文件；系统 picker 返回与账号、窗口、openEpoch 一起校验。
- 拖入/多项分享：对齐 iOS 最多 8 项、顺序处理、逐项成功/失败、重试不重复保存、取消只清自有临时文件、成功内容默认暂停打开。实现批量任务前先保护既有单文档 `DocSession` 原子交接。
- URI：按来源取得临时/可持久读取权，在有效期复制自有工作文件；不能假设 `content://` 可转换为本地绝对路径。迟到回调在取消、切账号、关窗口后不能提交。
- YouTube 待提取字幕链接需显示“仍需打开读取字幕”；未提取成功不得报告已存入文库，拖入不自动播放，沿用其实际支持的模式。

### 5.2 原生文档

| 渲染器 | 具体实现/验收重点 |
| --- | --- |
| 文本/EPUB | 容器测量 + 限行长；正文实例和段落 ID 稳定；宽度/字号/侧栏改变刷新文字与 marks 几何；目录、非 spine 插图、SVG 和图片降采样不退化 |
| PDF | 页空间作为定位权威，保留相对 zoom 和页内中心；fit-width 且位于文档顶部时优先保顶部，避免短页内容转横屏后消失；大文档按页释放资源 |
| 扫描 PDF/照片 | OCR 坐标系显式转换、裁切与缩放矩阵一处维护；旋转不重新跑整份 OCR、不把用户 zoom 重置成 1；横/竖、手动浏览和自动跟随分别验证 |
| DOCX/网页 | 长段按实际 mark 范围跟随，不把整段中心当当前句；图片、表格、代码块可达；Web marks 保留种子并重新测量路径 |
| YouTube | 以可用空间切换封面/字幕上下或左右布局，限制封面高度；保持同一字幕 session、时间位置、语言和播放权，收起后也不锁整个平板方向 |

OCR 坐标不能照搬：iOS Vision 使用左下原点的归一化坐标；Android 端必须以实际 OCR 引擎的输出约定为准。若输入框已是左上原点，就不能再复制 iOS 的 Y 轴翻转。用页左上、中心、右下三处文字校验识别图→裁切图→旋转后视图的完整变换，并验证缩放后的词框和标注仍对齐。

iOS 的 PDFKit 模拟器曾收到 pinch 手势却不改变 scaleFactor，最终通过观察原手势、仅在原生缩放停滞时使用公开 API 修正，并保持手指下页点。**Android 不移植这个平台补丁**；应分别验证本端缩放容器/渲染器，再针对真实缺陷修复。

### 5.3 商业书架逐个平台做，不共享一套“通过”结论

| 平台 | iOS 的关键修复 | Android 对齐重点与放行证据 |
| --- | --- | --- |
| Kindle 在线 | 重排不重启 Read/Explain；native 快照覆盖 OCR 过渡，音频继续；稀疏段落身份、词序列投影、未读尾部、旧翻页任务隔离 | 保留现有 `KindleVisualTurnGate`/预读/离线/恢复；旋转音频实际前进、词/整句标注仍在正确原文；Pause 在恢复中生效；自然读/解读完成后进入真实下一页 |
| Kindle 离线 | 隐藏使用容器高度；原页缩放保持归一化位置；整行点击热区 | 长页适配、手动缩放、语速/目录、下载状态、缓存/账号迁移；说明无网能做什么，不能将有网 TTS 验证称全离线 |
| Google Play 图书 | source/chapter ID 重建；唯一精确 overlap；暂停词重画；有依据的相邻页 reveal；短标题完整匹配；Aa 面板裁切修复 | cross-origin frame 继续验证来源/命令 owner；长正文和短标题各测试；重排尾部续讲之外，还须有真实自动翻页动作和新 source/ink |
| Kobo | iframe 可见区与所有 CSS clipping ancestor 取交集；手势层命中正文；强制提交同源文本的新 geometry；冷恢复先有界向后再向前 | 不按整个 WebView 矩形抽隐藏列；点击实际正文而非遮挡 shell；原生 Aa 开着旋转不永久遮罩；先前/后页恢复均不能猜最近段 |
| 微信读书 | Canvas 部分绘制先于 resize；不可变讲读 source；句级 hash checkpoint；窄↔宽冷恢复；目录真实 action 点击 | 在提交 paint 前检查实际 viewport/epoch；中文句级音频适配；两方向冷重开均真实播放；章节点击目标准确，不能只检查目录关闭 |
| O’Reilly | 本地 semantic-page/mark 合同可参考，iOS 无真实账号通过记录 | 若 Android 当前产品承诺支持，必须取得现有授权账号完成真实书架/长章/代码图/Read/Explain/续页；无条件时明确 BLOCKED |

**微信读书目录特别规则：** 一般目录跳转需要真实新页面提交；如果唯一权威目录项的目标已在稳定可见 Canvas（包括右列），可按当前选中项语义正常关闭目录，不强制多翻一页。不能仅凭旧 VM scope 认定“已在该章”。iOS 最终发现给父 `li` 发事件会选到错误章节，修成向实际标题/action 控件发一次有坐标的 click，并测试只触发一次。

**Kobo 遮罩特别规则：** iOS 在初始可读页面已提交后，为旋转视觉遮罩设置 3 秒上限；这不代表初次打开、账号恢复或真实导航 3 秒后可绕过内容确认。Android 如采用上限须保留同样边界。

## 6. 踩坑清单：现象、原因、修法与 Android 落点

下表汇总真实 iOS 迭代中的问题；“Android 落点”是实施建议或待核查，不宣称已在 Android 复现。

| ID | 现象 / 原因 | 已采用的解决方式与 Android 对齐要求 |
| --- | --- | --- |
| P01 | iPad 横屏仍是 regular；surface preference 一度返回 0×0 | 直接观察宿主实际 geometry；Android 不只判断 orientation/设备型号，0 尺寸不提交有效布局 |
| P02 | 全局屏幕高度用于隐藏阅读器，窗口缩小时露底/遮挡 | 以自身容器高度布局与隐藏；覆盖自由窗口、外接屏移动 |
| P03 | 窗口控制覆盖返回，添加第四个工具按钮挤掉导入 | 实际系统窗口控制 inset；降低工具栏密度，把新窗口放设置；Android 测标题栏/任务栏/折叠铰链 |
| P04 | 语音搜索结果在键盘后；嵌套容器扣两次键盘高度 | 只按宿主窗口的实际遮挡消费一次；验证结果行而非仅 Done；浮动键盘不压缩整个页面 |
| P05 | 设置末行被迷你播放器遮住，点击误开阅读器 | 列表预留实际播放器高度，并验证最后一项真实命中 |
| P06 | 大字号时语速/音色挤压；宽书行只有文字区域可点 | 窄窗堆叠、可滚动、完整行热区；iOS 44pt，Android 主要触控目标至少 48dp，不只放大图标 |
| P07 | PDF/照片旋转丢 zoom；短 PDF 横屏看起来空白 | 相对缩放+归一化位置；顶部 fit-width 保顶部，手动浏览保页内中心 |
| P08 | DOCX 长段 mark 跟随到段落中间，真实句子不见 | 按语义字符范围滚动，并以阅读可视区计算目标 |
| P09 | 模型 marks 还在，但旋转后页面无墨迹 | marks identity、DOM/native 实际可见路径、正确文字位置共同断言；只保 VM 不是通过 |
| P10 | Kindle 缺词/连字符导致标注截断，段 ID 越界 | 稀疏 ID 语义查找、序列对齐、一个词多个行框和覆盖度校验 |
| P11 | Kindle 为等待 OCR 暂停音频，恰好遇音频切段后无法续播 | 保留播放，用 native 快照覆盖几何恢复；自然 completion 等几何稳定后接未读部分，不暂停错对象 |
| P12 | 重排后新露出尾部被跳过，或同一段重复解释 | 维护 immutable source 与已消费范围，尾部先消费；短尾沿用有界策略，之后才物理翻页 |
| P13 | 暂停时重排没有 tick，同词去重后不重画 | 保留 nil/reset 语义或显式失效 geometry，恢复暂停 seek 后主动画高亮 |
| P14 | Google 旋转后 source ID 改变，精确 ID 匹配失败 | 唯一严格原文 overlap + UTF-16 起点修正；短标题允许唯一整段匹配，重复内容拒绝 |
| P15 | Google 注释的正文移到相邻页，fallback 重读新页开头 | 保留 source/游标；仅凭验证过的邻接文本有界 reveal，校验 frame、owner、baseline |
| P16 | Kobo 旋转后文本相同却不发布新几何 | geometry refresh 与 navigation 分开；settled geometry 即使 source 相同也必须提交 |
| P17 | Kobo 提取到隐藏列的 3–4 字碎片，被质量门禁拒绝 | 交集所有裁切祖先再映射 iframe；保留质量和 origin 检查，不能放宽过滤“解决” |
| P18 | Kobo shell 接到点击，但正文没有选中 | 实际可见 text fragment 命中；测试真实正文目标，不能固定屏幕坐标点击 |
| P19 | 手动下一页改变站点书签，冷恢复只向前找不到旧听读点 | 先有界附近向后，再现有向前检索；唯一段/严格 hash 证据才接受 |
| P20 | 微信先画半页 Canvas 后才触发 resize，被当新页重启 | 提交提取前检测真实 viewport，合并短暂 paint；保留 source/音频 owner，native 尺寸无隐式插值动画 |
| P21 | 中文服务只有句级 timing；短窄页缺少句外上下文，重开失败 | 句本身加入严格摘要证据，保留可验证邻文；切分不同退已验证句首，禁止按空格数猜词 |
| P22 | 微信目录关闭但实际是前一章，或已可见右列章节被误判超时 | 点击真实 action 一次；比较稳定可见章节内容，区分真实跳转与权威已可见项 |
| P23 | 用户在 loading 暂停，切解读却自动播放 | 显式暂停意图优先于加载状态和自动播放偏好；晚到结果只缓存/准备 |
| P24 | 旧窗口 VM close/设置回调停止新窗口音频 | 会话租约+递增代次；关闭必须 compare owner 后执行；账号切换递增边界 |
| P25 | 仅靠 SceneStorage 立即杀进程后丢窗口 | 另存按场景/账号的最小原子书签，真实宿主挂载后恢复；Android 区分重建与持久恢复 |
| P26 | 多项 provider 文件离开回调生命周期后失效；取消误删原文件 | 在可读期复制自有文件、顺序队列、引用归属、迟到回调隔离；Android 保护 URI grant 与原文件 |
| P27 | 相机 API 报支持但模拟器 scanner 黑屏 | 区分框架能力和真实相机可用；缺硬件走明确图片选择路径；不代替真机扫描测试 |
| P28 | 模态遮罩下隐藏 Amazon 对话仍被无障碍点击 | 面板期间禁用/隐藏阅读底层交互，测试不点被遮住控件；保持原站点安全策略 |
| P29 | 公共 JS 构建误用脏 sibling checkout，引入非本次提取改动 | 锁定依赖 commit、重建 bundle 并审 diff；iOS 使用 readout-desktop `2f060971136c61b3b7f407a155fbbb65ed43ce80`，不是要求 Android 盲目退回该版本 |
| P30 | SwiftUI 根泛型在 iPhone 真机冷启动栈溢出，模拟器正常 | 稳定 AnyView 边界修复；Android 对等要求是真机冷启动/重建 smoke，不是搬 AnyView 技巧 |
| P31 | 单测删除真实登录 Keychain；无签名审计包覆盖后账号不可读 | 独立测试应用/存储/凭据范围；正式覆盖保持签名身份，安装前审计；Android 不卸载解决签名冲突，不清真实应用数据 |
| P32 | 测试账号 Pro 到期，克隆请求被正常拦截 | 先确认真实身份/区域/权益/额度，门禁拒绝不计模型通过；仅在明确测试授权内处理权益，不改生产鉴权 |
| P33 | 旋转测试失败其实是模拟器连桌面都不转 | 先系统对照，再重启同一设备，不建第二个设备或清数据来逃避问题 |
| P34 | Command/Escape 测试失败；连原生文本框 Command-A 也异常 | 保留未验证结论、做真键盘确认；不添加裸数字快捷键或抢焦点补丁 |
| P35 | 0 tests/skipped 也返回成功；runner 环境变量未传进程 | 校验执行数量>0、用显式 runner 配置；SKIP 不是 PASS，Debug 开关不进 Release |
| P36 | 自动化断言通过但 screenshot 有遮挡/断标；SVG 像素采样假失败 | 逐张目检；只修采样位置/bitmap 格式且保留颜色与不透明断言，不能删产品要求 |
| P37 | 测试把自然切段当旋转重启，把几何 reveal 当真实续页 | 固定场景验证段内保持；边界另测合法递增；真实翻页计数+新 source+实际播放+可见新 ink 联合断言 |
| P38 | 镜像占用/低电/测试 runner Code 74 导致反复等待 | 开始前确认电源、连接、真实账号与可操作通道；runner 未启动不算产品失败/通过；保留通过证据避免整轮重做 |
| P39 | 高 build 号或新目录被误当最新手机基线 | 发布源码祖先、逐文件摘要、独立构建目录、Release 回归共同确定候选；先正式整合再打包 |
| P40 | 上传截图时旧脚本可能删 iPhone 图；上传包被误称已提交 | 仅目标集合增量更新、日志可恢复、资产顺序/摘要核对；读取最终 build 和审核状态，不停在草稿 |

P06 的 Android 触控/键盘要求参见 [Adaptive optimized](https://developer.android.com/docs/quality-guidelines/adaptive-app-quality/tier-2)。其他条目均来自本项目 iOS 实施和发布记录，不是对 Android SDK 的泛化结论。

## 7. 源码定位与移植方法

iOS 路径相对 CastReader 仓库；Android 路径除 Manifest/Gradle 外，相对 `app/src/main/java/com/same/castreader/`。以下均在调查时实际存在。用固定提交查看实现，再对照最新 Android 合并，不整文件替换。

| 模块 | iOS 参考入口 | Android 现有落点 |
| --- | --- | --- |
| 窗口布局/导航 | `CastReader/Utils/AdaptiveLayout.swift`、`CastReader/Views/MainTabView.swift` | `MainActivity.kt`、`ui/navigation/CastReaderNavHost.kt`、`ui/screens/reader/ReaderShell.kt` |
| 场景与持久恢复 | `CastReader/Services/ReaderSceneContext.swift` | `reader/DocSession.kt`、`content/ResumeCoordinator.kt`、`content/ResumeSystemEntry.kt` |
| 音频所有权 | `CastReader/Services/AudioPlayerService.swift`、`CastReader/ViewModels/PlayerCoordinator.swift` | `player/manager/{PlayerCoordinator,GlobalPlayerState,PlaybackController,AudioPlayerManager}.kt`、`player/service/AudioPlaybackService.kt` |
| 重排锚点 | `CastReader/Models/ReadingResumeCheckpoint.swift`、`CastReader/Utils/KindleViewportTextAlignment.swift`、`CastReader/Services/ResumeCoordinator.swift` | `player/progress/{ReadingCheckpoint,WeReadReadingCheckpoint,CommercialPlaybackCheckpointStore}.kt`、`googlebooks/GoogleBooksPlaybackCheckpoint.kt` |
| 原生阅读 | `CastReader/Views/Reader/`、`CastReader/Utils/ReadingAnchorResolver.swift` | `ui/screens/{epubreader,pdfreader,photoreader}/`、`util/{ReadingAnchorResolver,MarkAnchoring}.kt`、`pdf/PdfNativeEngine.kt` |
| Kindle | `CastReader/Services/WebReaderBridge.swift`、`CastReader/Utils/KindleViewportTextAlignment.swift` | `ui/screens/kindle/`、`kindle/{KindleWebScripts,KindleSpreadGeometry,KindleMarkGeometry,KindleVisualTurnGate}.kt`、`kindle/offline/` |
| 其他书架 | `CastReader/Services/{WebReaderBridge,WeReadWebScripts}.swift`、`WebReader/` | `googlebooks/GoogleBooksWebScripts.kt`、`kobo/KoboWebScripts.kt`、`weread/WeReadWebScripts.kt`、`web/{google-books,kobo}/`（后两目录在仓库根） |
| 导入/拖放 | `CastReader/Utils/ReaderDropImport.swift` | `ui/screens/import_feature/`、`ui/screens/capture/`、`reader/DocSession.kt`、`cloud/` |
| 键盘/无障碍 | `CastReader/Utils/ReaderWindowKeyboard.swift` | `MainActivity.kt`、`ReaderShell`、各表单/实际 WebView 焦点 |
| 测试入口 | `CastReaderUITests/iPadAdaptationUITests.swift`、`PlatformLiveIPadAcceptanceUITests.swift` | 已有 `PdfViewportAcceptanceTest`、`ReadingResumeAcceptanceTest`、`ResumeMatrixTest`、`MobileSessionOwnerTransitionTest`、商业书籍冷恢复/合同测试；新增 tablet 专项，不冒称现有测试覆盖全部 |

查阅示例：[iOS 最终应用树](https://github.com/vinxu/CastReader/tree/fe64420dad87d7262c3d7de144a4b30c5ee7feb3)、[Android 调查树](https://github.com/vinxu/CastReader-Android/tree/63341f991f72a973098e87c8f8d8de26fa0e0013)。链接需要对应仓库访问权限。

## 8. 验收方法：每完成一个模块就过门禁

### 8.1 一个可复用的模块流程

1. 保存当前源码/配置 hash、模块范围、真实设备/窗口、账号地区和样本 hash。
2. 用确定性测试覆盖边界/迟到回调/几何；用真实 WebView 检查 JS/DOM/Canvas；构建目标 flavor。
3. 在固定、保留账号的平板设备/模拟器上逐项操作：功能→旋转→短/窄窗口→大字号/IME→恢复。需要新硬件时先明确目的，不反复新建已登录设备。
4. 采集完整窗口 screenshot、真实播放日志和必要录像，**人工复核可见 UI**。不能只相信语义树或状态字段。
5. 实际出现的问题修复后重跑失败项及受影响合同；同源码已通过的其他模块不无理由全量重测。
6. 更新唯一报告：PASS/FAIL/BLOCKED/NOT_RUN/SUPERSEDED、原因、证据、下一步。该模块门禁通过后再进入下一模块；公共基础修复需回归受影响的先前模块。

### 8.2 最小设备与状态矩阵

| 维度 | 必测 |
| --- | --- |
| 窗口 | 四方向（系统支持时）；320/360/375 紧凑；599/600、839/840、1199/1200、1599/1600 边界；实际分屏/自由窗口；短高与键盘遮挡 |
| 设备 | 真实 Android 平板至少一台 + 平板模拟器；已有真实手机回归；折叠/桌面窗口对等能力按支持声明补验，不由尺寸预览代替 |
| 系统 | 当前目标 API 36 的强制大屏行为；产品支持范围内旧系统代表；OEM 与系统 WebView 版本记录清楚 |
| 内容 | 中文长句/短句、英文连字符、重复标题、中英混排/emoji；EPUB 图片/SVG/目录；旋转/扫描 PDF；大文档；商业阅读真实长正文和短章节 |
| 播放状态 | idle、loading、buffering、playing、user-paused、segment boundary、page boundary、completed、error；不能只在暂停空闲页面旋转 |
| 生命周期 | 前后台、锁屏/通知控制、配置重建、系统回收、强停后手动重开、任务窗口关闭、两个窗口交接；不同场景区分记录 |
| 可访问性 | 最大字号、显示缩放、深色、TalkBack、Tab/方向键/Enter/Escape/Space、文本编辑时不抢快捷键、鼠标/触控板/笔基础操作 |
| 身份 | 已有有效 Pro、免费/耗尽、未知额度、过期、切账号、跨区边界；真实支付流程使用合法测试条件，不动用户真实付费记录 |

以上尺寸是覆盖点，不是要求创建同等数量的模拟器。连续 30 次旋转不能代替 60 分钟性能/能耗与资源稳定性验收。性能先量同内容手机/平板基线，再设可比较预算；目前 iOS 资料没有可直接复制的真机性能 SLA。

### 8.3 核心服务矩阵（最终 Android Release APK）

CN/中文和 Global/英文分别完成下表，每个格至少有一组真实新生成、实际播放推进、下一段/下一块、可见高亮或 marks 的完整证据。

| 模式 | 常规/Kokoro | 社区声音 `vl_` | 私人声音 `vc_` |
| --- | --- | --- | --- |
| 朗读 | 真实 TTS→播放→下一段 | 同左，另确认身份/额度 | 同左，另确认本人有权使用 |
| 解读 | plan/block/compose→讲解播放→原文 marks→下一块 | 同左 | 同左 |

两种模式各做 常规→社区→私人→常规，包含播放中与主动暂停后切换；私人准备中切回常规后旧请求不得接管。再做 朗读→解读→朗读、试听借用与恢复、等待中暂停、余额刷新/未知/不足、定时停止与用户恢复。缓存/冷准备分支可用合同测试覆盖；未观察线上冷启动就明确写 warm，不制造成本只为凑“冷”。

最终包验证至少记录：source/config hash、flavor、versionCode、签名/制品 hash、账号范围摘要、实际路由 host、样本 hash、voice kind/id（私人 ID 仅本地私有记录）、request/task ID、真实 position/duration/segment、physicalTurnCount、source hash、visibleInk/highlight、pause intent、quota 前后、截图/录像路径。日志不包含 token、私人音频 URL、账号邮箱或完整商业书籍正文。

### 8.4 证据分层，防止“假通过”

| 层级 | 能证明 | 不能单独证明 |
| --- | --- | --- |
| 单测/静态合同 | 所有权、锚点、幂等、超时/迟到、边界计算 | 真接口、声音实际播放、真实站点布局 |
| 实际 WebView fixture | frame/裁切/DOM/Canvas 的真实运行行为 | 生产登录和书籍、跨区服务 |
| Debug 观察 | 真实 VM/页身份/播放器日志；须无业务绕过 | R8/签名/Release 资源与行为 |
| 最终正常 Release + 真机 | 产品实际路径、系统生命周期、真实音频/视觉 | 未跑过的设备、账号、硬件矩阵 |

测试 runner 返回 0 tests、skip、bootstrap 失败均不能计 PASS。Android 现有 Compose 测试环境可能取消无限动画，loading 动画必须正常启动应用、真实时钟录像检查；不把测试时钟冻结误报为产品死锁。保留原失败报告，修复后新增通过证据，不改写旧结果。

## 9. 发布与商店资料

本节是未来 Android 实施后的发布清单，本次不执行发布。

1. 重新核对 Play 已发布/待审/最高占用 versionCode、CN manifest、对应源码；正式合并手机新功能和平板分支。两个 flavor 保持既有版本管理；同一次发布修复重打不无意义反复加号。
2. 遵守 Android 仓库 `AGENTS.md` 和 voice-clone-system-v1 架构锁；涉及声音/鉴权/路由/配置时先读权威合同并运行门禁。不能把 iOS 鉴权实现替换到 Android，尤其不能删除 Android 当前必需的构建解读 Key 校验或跨区规则。
3. 运行目标渠道的 Release 单测、lint、正式 APK/AAB；仓库要求的另一 flavor 编译/合同同样保留。构建期间冻结应用源码，不每次清缓存和重新预检。
4. 真机覆盖安装保持既有签名，测试包也不可卸载正式应用来绕过冲突；检查账号、书架、缓存和下载内容。正式 APK 不可调试，业务测试夹具/账号覆盖开关不得打入 Release。
5. 完成第 8 节最终 Release 核心矩阵和实际平板 smoke，再上传同源码 AAB/发布目标 CN APK。签名、hash、mapping/native 库兼容性、Manifest 和设备过滤以实际产物核查；确认相机等可选能力不会意外过滤无相机平板。
6. Google Play 素材用真实 Android 平板界面重新采集：①首页；②Kindle《地心游记》朗读；③同书解读；④音色；⑤“+”文件入口。至少中英文，其他现有语言按已确定的商店回退策略记录。准备目标平板尺寸集合及横屏支持画面，具体尺寸/数量以提交当天 Console 要求为准。
7. iOS 的 2048×2732 成品仅作风格参考，不能作为 Android 产品截图；它来自 11 英寸真实模拟器画面等比例嵌入，不能宣称 13 英寸真机验证。原图、成品、设备/版本、尺寸、顺序、hash 一起保存。
8. 只更新预期的 tablet 素材和说明，保留手机图、价格、订阅、地区和 Data safety 等既有值。商店若要求披露实际功能变化，先核实差异，不能靠随意改合规答案过门禁。
9. 上传后读回包处理结果、兼容设备变化、发布项和审核状态；区分已上传/草稿/审核中/已发布。CN 另验证下载文件与公开 manifest 指向同一 hash，上传失败不能先切线上 manifest。

推荐文案（只有实际完成才使用）：“新增平板适配：横竖屏与分屏布局更舒适，书架、朗读、解读、音色和文件导入完整支持大屏，调整窗口时保留阅读位置。” 未完成多文档窗口/折叠/外设验收时不得扩写相关承诺。

执行时使用现有 [Android 发布技能](/Users/xuxuheng/.codex/skills/release-castreader-android/SKILL.md)；它要求核心生成与播放先于上传。本文件不修改该技能，也不构成本轮 Android 发布授权。

## 10. 最终完成定义

- 配套任务表各模块通过，CSV 每行有实际状态与证据；继承已验证功能且手机回归通过。
- 已绑定平台真实账号逐个验收，缺条件项目不能藏在“全部完成”里；未支持的能力有明确产品范围决定。
- 旋转/分屏/缩放保持同一语义内容、正确暂停意图和唯一音频；长内容自然续页、窄↔宽冷恢复均实测。
- 多窗口、输入、无障碍、生命周期与真实平板性能达到本版明确标准；iOS 留下的验证空白不能原样变成 Android PASS。
- 最终 Release 核心服务、签名/资源/夹具排除、升级保数据、商店素材与提交回执齐全。
- 交付一份最终报告：版本/源码/制品、设备与窗口矩阵、服务矩阵、修复与跳过、截图、审核或下载状态、保留的验证边界。未经测量不使用“完全没问题”的绝对结论。

## 11. 原始资料索引

| 资料 | 用途 |
| --- | --- |
| [原始完整计划](https://github.com/vinxu/CastReader/blob/33d6001/docs/CastReader-iPad-Adaptation-Plan-2026-09-21.md) | 完整范围、默认产品选择；其中原型数字/阶段状态须结合最终源码看 |
| [iPad 阶段交付](https://github.com/vinxu/CastReader/blob/33d6001/docs/CastReader-iPad-Delivery-2026-09-21.md) | 单模拟器实际通过范围和未验证边界 |
| [六模块实施记录](https://github.com/vinxu/CastReader/blob/33d6001/reports/ipad-adaptation-20260921/README.md) | 每次失败、根因、修复、重跑入口 |
| [其他书架真实验收](https://github.com/vinxu/CastReader/blob/33d6001/reports/ipad-adaptation-20260921/PLATFORM-LIVE.md) | Google/Kobo/微信的细粒度问题与最终 276 项共享回归 |
| [最终 iOS 发布报告](https://github.com/vinxu/CastReader/blob/33d6001/docs/iOS-1.2.43-Release-Report.md) | 手机基线整合、核心服务、最终测试、归档、素材和送审状态 |
| [iPad 五场景素材](https://github.com/vinxu/CastReader/tree/33d6001/AppStoreAssets/1.2.43/iPad) | 原始/成品图片、来源说明、manifest；仅视觉参考 |
| [Android 本地发布记录快照](https://github.com/vinxu/CastReader-Android/blob/63341f991f72a973098e87c8f8d8de26fa0e0013/reports/android-release-60-20260920/README.md) | 现有手机功能、最终 Release 验收方法；实施前刷新线上基线 |
| [Android Adaptive app quality](https://developer.android.com/docs/quality-guidelines/adaptive-app-quality) | 平台验收框架，与项目的 TTS/书架专项矩阵一起使用 |

原始 xcresult、设备日志、账号截图和商业正文只保留在授权本地证据目录，不随交接文档扩散。以上官网说明核对日期为 2026-09-22，依赖版本和商店要求在实际开发/提交时再核对。
