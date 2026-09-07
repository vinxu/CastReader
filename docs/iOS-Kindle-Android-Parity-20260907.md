# iOS Kindle：Android 问题映射、修复与验收

本轮基线为 `fe2c3f71a268e40368fce3cf88e12022909f2006`，隔离分支 `codex/ios-kindle-parity-20260907`。Android 邮件及截图是调查线索，不计作 iOS 复现成绩。范围为已确认的阅读缺陷；全文搜索、手动书签、点词起读按用户要求暂缓。

## 当前状态

**最终候选的379项受控回归、真实字号短测及完整Kindle流程均通过。** 已完成代码映射、真实 WK/HTTP/AVPlayer 复现、九语设置 UI 检查，以及登录后 Kindle 的多轮实网测试。最后一轮修正字号的持久化方式：关闭设置保留同一WK文档、不主动reload；字号本身的重排仍可能改变页首。

| 交付项 | 状态 |
|---|---|
| 最终构建 / 实际安装身份 | iteration26，Debug 1.2.35 (55)，App executable SHA256 `267ea5743880c410bde3d831c7bb3286ef76bdc33ac82e2ae5d1574d13373305`；实际安装已核对一致；业务代码`CastReader.debug.dylib` SHA256 `bb32e145facc6edc1eada6bd7546193a4b5cdafa05f81ae5f6bae9f43ec1c308`也一致，未发布 |
| 最终受控回归 | `regressions-run16`：25类、379/379、0失败/跳过，115.742秒（wall115.885秒）；新增真实WK兼容7项均通过 |
| 最终字号短测（含旋转、重启） | `font-live-run12`：86.764秒通过；原生6→7、Done不reload、横→竖、重开/进程重启仍7，恢复5/skip1；原图及关键视频窗已独立复核 |
| 最终真实完整流程 | `live-acceptance-run17`：252.783秒通过，覆盖下文全部阅读步骤及实际App版本；原图及关键视频窗已独立复核 |
| 九语、深浅色、大字体设置 UI | 已验证36场景、108张PNG；另6场景长说明复核 |
| 交还模拟器 | 完整测试已恢复字号5、脚注跳过开启、1x、竖屏暂停；已正常启动测试App并实际查看交还截图，中文首页的授权US Kindle书架保留 |

## 用户反馈逐项映射

| 编号 | Android 反馈 | iOS 检查结果与本轮实现 | 验收边界 |
|---|---|---|---|
| I1 | 段末停3–4秒 | 修复自然队列耗尽和用户暂停混淆、在途生成被取消；Kindle 增加按倍速计算的12秒前瞻，至少2/最多8个后继，第3–8段合计≤1600 UTF-16字符。 | 受控流式HTTP与真实AVPlayer验证；实网10个同页软件切换61–138ms、中位75ms。两次跨页仍2616/2683ms；这不包含MP3尾静音和扬声器延迟，不承诺所有可听停顿≤1.5秒。未新增可调段间静音。 |
| I2 | 字号过大、左右裁字、没有字号入口 | 新增本地化阅读设置；单次操作原生A±、只读确认。呈现缩放与网页CSS viewport分离，采样稳定后包含整页。启动保留Kindle已有字号/边距/单双栏。关闭设置重新捕获供下一次明确Play，不复用旧段落索引。 | 原客户《Stalin》未在iOS同书复现；已在授权测试书验证布局并复现字号回退。旋转写回旧字号的最终兼容修补与实网结果见下文；不把模拟器成绩等同于原客户设备。 |
| I3 | 句中/整段漏读 | TTS生成失败保留未处理尾文，重试只续尾文，失败不跳段；Vision已经识别但缺词框的token保留文本并标记估算几何。 | 受控尾文7项、缺框保全4项；不能修复OCR引擎完全未识别的字，也未证明客户原书就是此分支。 |
| I4 | 脚注号码被朗读 | 新增默认开启的“跳过脚注引用号”；可信Vision来源、同行、抬高短数字、独立墨迹和语义共同满足才过滤，原文与源词ID保留。 | 策略13项+真实Vision图4项；支持en/de/es/fr/it/pt。其余语言、未知来源/不可信框保留；普通数字和脚注正文仍读，不承诺所有引用样式。 |
| S1 | App内取消订阅 | iOS已有Pro条件下“管理订阅”，调用Apple系统管理页。 | 外部订阅来源识别和入口仍有产品差距，本轮未猜测provider或改订阅路由。未用模拟器替代真实Apple订阅验收。 |
| S2 | App内版本显示 | 设置页显示并可复制bundle实际版本/构建号，提供`settingsAppVersion`标识。 | 最终完整UI流程核对实际安装值；不是写死版本。 |
| S3 | 书内全文搜索 | 暂缓。 | 目录/书架搜索不计作全文搜索。 |
| S4 | 手动书签 | 暂缓。 | 自动播放进度不计作书签。 |
| S5 | 点选正文位置开始朗读 | 暂缓。 | 自动高亮不计作可点击起读。 |

## 另外复现并修复的跨端问题

- **翻页先缩小后放大、收起再展开比例变化：** 将可视呈现与分页viewport分离，保留已确认几何，拒绝零尺寸/过渡尺寸与旧请求回包；同尺寸且图像已解码、面积/viewport正确的健康展开只读确认并恢复高亮，不额外派发resize。坏图、缺失页面或真实viewport变化继续走恢复。
- **横屏底部挡字：** 播放条占独立预留区，横屏68pt、竖屏72pt，页面不放到控制条下面。
- **翻页结果不确定时重复翻页：** 单次派发后仅观察确认；无法确认不再用第二入口补点击。Previous方向也已修正。
- **首次播放遇到迟到的同步提示被取消：** 保留当前book/mode/请求的播放意图；用户处理同步后恢复准备。用户取消、打开设置、导航或销毁会撤销，旧回包不能提交。
- **过早打开Aa破坏初始化：** 主文档安装capture/turn/lock/sync observer后才开放；导航撤销旧ready。迟到同步提示收起设置，交由用户选择，不由应用自动点No/Yes。
- **Aa菜单关闭、旋转后的原生控件识别：** 单次Close派发加只读关闭确认；仅确权的原生菜单允许公开`close()`回退。保留disabled/inert/aria/动画等门禁，避免把Ionic布局容器的disabled标记误判为按钮不可用。
- **OCR取消时崩溃：** 实网曾触发重复resume continuation的SIGTRAP；改成单一完成路径，6项取消测试覆盖。

## 字号持久化：根因与最终方案

真实诊断显示：用户原生A±已将字号保存为6；同尺寸展开的synthetic resize及实际旋转的trusted resize都曾把存储写回5，而当前画面仍是6，重启后才明显变小。去掉多余resize只能解决展开，无法覆盖真实旋转。

两份实际被本轮iOS加载的公开Amazon资源解释了机制：

| 来源 | 已核对机制 |
|---|---|
| [阅读器91FlWPKIGuL.js](https://m.media-amazon.com/images/I/91FlWPKIGuL.js) | 空依赖resize回调捕获首次设置闭包。画面更新用当前React状态，保存偏好时却从旧闭包合并；只改navigationMode也可能把旧fontSize/fontSizeIndex写回。SHA256 `f913f7d2541dfb868bd02f95443afc6b0d046e6b2c2a7b684cb9afd3bdceab97`。 |
| [组件C1I2cjCoo7L.js](https://m.media-amazon.com/images/I/C1I2cjCoo7L.js) | A±直接调用原生字号回调，无需额外blur；`useLocalStorage`同步写存储，再广播`onLocalStorageChange`，React偏好使用事件detail。因此只改存储、不更新同一原生通知会再次失配。SHA256 `b632412985eb6ff3758f1980272b9e0e5c05507bc315e598de2f709fa3ed4d81`。 |

一度采用“确认字号后Done单次reload”。该候选字号旋转/重启短测及372项回归通过，但实网视觉复核发现reload前后正文页首改变，还会再次出现同步提示。因此最终撤销这种自动reload，保留当前文档，改为针对已知偏好协议的窄兼容修补：记录resize前合法字号，只在确认是同次resize写入且之后没有新的有效写入时恢复`fontSize`与`fontSizeIndex`，保留其余字段并发送原生存储通知。缺失/畸形字段、事件不匹配或后续用户修改都取消处理。该协议属于当前Kindle实现，升级后需重跑真实验收。若未来异步派生写入抢先发生，兼容层会保守取消处理；不承诺对未知后续网页实现仍有效。

此前失败仍留在`build/kindle-parity/`：full12/13及font10证明字号回退；font11证明自动reload候选能保留字号；full15视觉证明重新定位副作用。full16的播放等待失败另有明确原因：截图期间同步提示覆盖Play，XCTest命中点为`{-1,-1}`，应用未收到Play请求；不是“已开始的播放又被吞掉”。最终测试在截图后重新确认加载结束、同步选择完成和按钮可点击，只发送一次Play。

## 最终实网结果

同一候选iteration26：`font-live-run12`于13:03:14完成，86.764秒通过；`live-acceptance-run17`于13:08:06完成，252.783秒通过。两场之后没有再改生产代码。版本1.2.35(55)、主程序及Debug业务dylib均与实际安装比对一致。

- 字号短测：原生6→7，关闭设置不reload；实际横→竖、重开设置与进程重启均仍7，最后恢复5和脚注开关。独立原图/视频复核首次Done前后为同一段正文，没有旧reload额外换页/同步弹窗。旋转仍约2秒白页重排，返回竖屏页首有提前；这不代表严格保词位或无缝旋转。
- 完整流程：首次Play、3次Next、1次Previous、旋转、字号5→6及脚注开关、Done后Play、收起后2次实际自动变页、展开播放/高亮、进程重启保持6、恢复5/skip1，以及设置中实际版本1.2.35(55)均通过。独立录像复核Done前后正文一致，字体重排发生在此前的字号操作内；mini展开字形/断行稳定，逐词高亮贴合正文。重启后的页首与关闭前有差异，字号持久化通过不能外推成严格文本位置恢复。
- 最终恢复原图由主任务实际复核：正文左右边缘完整，Play表示暂停、1x可见，没有加载遮罩或Most Recent Page Read提示。扩大后的播放原图也确认高亮贴词、正文位于独立播放条上方。

证据索引：`regressions-run16-summary.json`、`font-live-run12.log/.xcresult`、`font-live-run12-attachments/visual-evidence.md`、`live-acceptance-run17.log/.xcresult`、`live-run17-attachments/visual-evidence.md`、`final-installed-handoff.png`、`candidate-identity.json`、`installed-candidate-identity.json`，均在`build/kindle-parity/`。失败迭代原日志和原图仍保留，未改成通过。

## 验证组成与限制

受控测试使用真实WKWebView、Vision、AVPlayer和受控HTTP输入，不把mock页面当成真实Kindle结果。最终候选 iteration26 的379项组成（`regressions-run16-summary.json`逐项去重核对）：

| 测试组 | 项数 |
|---|---:|
| Audio失败/所有权/流式暂停/权限暂停 | 7+6+6+3 |
| 尾文续读/Kindle前瞻 | 7+11 |
| 初次同步与布局恢复 | 10 |
| 翻页证据/原生WebView容器 | 17+14 |
| 阅读设置所有权/原生设置脚本 | 28+28 |
| 脚注策略/真实Vision图 | 13+4 |
| OCR缺框/取消/墨迹 | 4+6+7 |
| Photo快照/布局/布局图 | 4+21+4 |
| 站点/书架 | 34+20 |
| 通用/本地化/播放条/端点 | 65+50+9+1 |

最终完整实网流程要求：首次明确Play→3次Next/1次Previous→横竖屏→字号与脚注修改→Done后明确Play→收起后2次真实自动变页→展开→重启保持字号/脚注→恢复基线→核对实际App版本。另跑改字号后立即横竖屏的短测。视频与原图复核页面边缘、正文、高亮、缩放和最终交还状态，不能仅依赖方法返回passed。

**九语设置UI：** en/zh-Hans/ja/es/fr/de/pt-BR/it/hi × Light/Dark × 正常/AXXXL，36场景、2个方法，539.019秒，108张PNG复核。另en/zh-Hans/pt-BR × Light/Dark AXXXL的6场景长说明，82.536秒通过，6张原图确认全文/末行/Done可见。90条新增译文非空、translated与占位合同通过。pt-BR最大字体导航标题省略，但完整AX标题和Done保留。主题证据来自实际SwiftUI视图环境与像素，非仅文件名或设备getter；不代表Kindle网页自身夜间主题、所有VoiceOver顺序。

**未覆盖：** 客户原书B01KUYX372、客户Pixel/WebView组合、物理iPhone、所有脚注样式/语言、所有网络条件和声学尾静音。已知这些边界不以模拟器或单元测试代替。未发客户邮件、未提交iOS发布。

## 复现环境

- Xcode26.6，iOS26.5 Simulator，App最低iOS17.6。
- 已授权实网：iPhone17Pro，`6A08602F-01D6-4B70-979D-5A5028E894E6`；US站、B002RKRMSY《A Journey to the Centre of the Earth》。保留用户登录及同步书架。
- 独立QA：`5E6C9500-D581-413A-8D75-A8586AB3C60B`；受控测试使用nonPersistent WebKit store，避免影响授权会话。
- 产物与截图/日志：`build/kindle-parity/`（不入git）；提交的测试源码及下列命令可重新构建复现。

## 可复现环境与运行入口

受控 WK/HTTP/AVPlayer 回归只在独立 QA 模拟器运行；真实 Kindle 测试只选用户已登录、已同步书架的 live 模拟器。保留它的 App 数据和 WebKit cookies，不卸载/清容器、不复制登录信息。测试选择书架第一本 Kindle，实际请求 TTS、翻页、改字号及重启 App；其 wait helper 遇到可见 Most Recent Page Read 会点 No 保留本次页，需沿用本轮对此测试的授权。不要与人工操作或另一场测试并行操纵同一模拟器。恢复值5/skip1是本轮约定基线，换环境应先记录该环境原值。

仓库入口为 [KindleLiveAcceptanceUITests.swift](/Users/xuxuheng/Documents/.worktrees/CastReader-ios-kindle-parity-20260907/CastReaderUITests/KindleLiveAcceptanceUITests.swift) 和 [CastReader shared scheme](/Users/xuxuheng/Documents/.worktrees/CastReader-ios-kindle-parity-20260907/CastReader.xcodeproj/xcshareddata/xcschemes/CastReader.xcscheme)。完整方法是 `testAuthorizedKindleReadTurnSettingsMinimizeAndRelaunch`；字号短测为 `testAuthorizedKindleFontCommitSurvivesSettingsCloseAndProcessRelaunch`。二者默认跳过，必须为 **UITest runner** 显式开启，不能只设置被测App的launchEnvironment或假定shell变量自动继承。

在仓库根目录执行下面的构建命令；`<LIVE_SIM_UDID>` 替换为已授权live模拟器ID。下列命令可从提交的源码重新生成测试产物。

```bash
xcodebuild build-for-testing -workspace CastReader.xcworkspace -scheme CastReader \
  -configuration Debug -destination 'platform=iOS Simulator,id=<LIVE_SIM_UDID>' \
  -derivedDataPath build/kindle-repro/DerivedData
```

从这次构建生成的 `.xctestrun` 派生专用副本，在 Xcode scheme 的测试环境配置所对应的 UITest target `EnvironmentVariables` 中设置下表（当前格式为 `TestConfigurations[].TestTargets[]`，按 `IsUITestBundle` 识别）。保留原环境，不覆盖整个字典；不要改 `UITargetAppEnvironmentVariables` 来代替 runner 环境。

| 环境变量 | 本轮值 / 来源 |
|---|---|
| `CASTREADER_KINDLE_LIVE_ACCEPTANCE` | `1` |
| `CASTREADER_TEST_RESTORE_KINDLE_FONT` | `5` |
| `CASTREADER_TEST_RESTORE_KINDLE_SKIP` | `1` |
| `CASTREADER_TEST_APP_VERSION` | 本次 `CastReader.app/Info.plist` 的 `CFBundleShortVersionString (CFBundleVersion)`，不得写死 |
| `CASTREADER_KINDLE_FONT_ROTATE_AFTER_COMMIT` | 字号短测需验证提交后旋转时设 `1`；完整方法自身已有旋转步骤 |

以下片段可独立生成副本，不依赖忽略目录里临时的 `refresh_candidate.py`；版本预期直接取自同次产物：

```python
from pathlib import Path
import plistlib
products = Path("build/kindle-repro/DerivedData/Build/Products")
sources = list(products.glob("CastReader_*.xctestrun"))
assert len(sources) == 1, "请选择本次构建对应的唯一 xctestrun"
run = plistlib.loads(sources[0].read_bytes())
info = plistlib.loads((products / "Debug-iphonesimulator/CastReader.app/Info.plist").read_bytes())
for config in run["TestConfigurations"]:
    for target in config["TestTargets"]:
        if target.get("IsUITestBundle"):
            target.setdefault("EnvironmentVariables", {}).update({
                "CASTREADER_KINDLE_LIVE_ACCEPTANCE": "1",
                "CASTREADER_TEST_RESTORE_KINDLE_FONT": "5",
                "CASTREADER_TEST_RESTORE_KINDLE_SKIP": "1",
                "CASTREADER_TEST_APP_VERSION": f"{info['CFBundleShortVersionString']} ({info['CFBundleVersion']})",
                "CASTREADER_KINDLE_FONT_ROTATE_AFTER_COMMIT": "1",
            })
            target["SystemAttachmentLifetime"] = "keepAlways"
            target["UserAttachmentLifetime"] = "keepAlways"
(products / "KindleLiveAcceptance.xctestrun").write_bytes(plistlib.dumps(run))
```

```bash
xcodebuild test-without-building \
  -xctestrun build/kindle-repro/DerivedData/Build/Products/KindleLiveAcceptance.xctestrun \
  -destination 'platform=iOS Simulator,id=<LIVE_SIM_UDID>' -parallel-testing-enabled NO \
  -only-testing:CastReaderUITests/KindleLiveAcceptanceUITests/testAuthorizedKindleReadTurnSettingsMinimizeAndRelaunch \
  -resultBundlePath build/kindle-repro/live-full.xcresult
```

字号短测将 `-only-testing` 的方法名换为上面的focused方法，结果目录另取新名。每场保留日志与 `.xcresult` 附件，核对同次bundle版本/可执行SHA和实际安装身份；出现失败按首个断言及截图定位，不用重复点Play绕过。完成后确认暂停、字号/脚注恢复、同步提示已处理且页面可操作；只有方法通过并不自动保证最后交还状态。

## 关键源码索引

以下以函数名和最终 SHA 定位，避免并行修改后的旧行号误导。

| 文件 | 主要入口 |
|---|---|
| `Services/OCRService.swift`、`Utils/OCRTokenGeometryCoverage.swift`、`Utils/OCRWordInkBounds.swift` | recognizeLines、取消、文字保全、布局及墨迹证据 |
| `Utils/KindleFootnoteSpeech.swift`、`Models/ReadingDocument.swift`、`Services/PhotoOCRCache.swift` | prepare/mapTimestampWords、源词字段、snapshot v2 |
| `Views/Kindle/KindleBookView.swift` | startCurrentMode、handleKindleSyncDialogEvent、buildTextQueue、readSpeechFingerprint、设置生命周期、requestKindlePageTurnTarget |
| `ViewModels/ReadAloudViewModel.swift`、`Services/AudioPlayerService.swift`、`Services/TTSService.swift` | retry/generate、preloadKindleHorizon、暂停/session、TTSContinuation |
| `Views/Kindle/KindleLibraryConnectView.swift` | KindleViewportPresentationPolicy、KindleWebViewContainer |
| `Services/KindleReadingSettingsScript.swift` | 原生字号/菜单确权、resize偏好兼容入口 |
| `Views/Kindle/KindleReadingSettingsView.swift`、`Localizable.xcstrings` | 设置 UI、DEBUG 主题 probe、九语资源 |
| `Views/Settings/SettingsView.swift`、`Services/ProManager.swift` | bundle 版本显示、已有 Apple 管理订阅入口 |
