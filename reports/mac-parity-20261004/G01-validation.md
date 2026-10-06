# G01：Mac 工程与国际版基础验证

日期：2026-10-04。基线：`09456f1979cc14ca19977ede4b1edde043c5f840`，iOS 1.2.47 Build 72。

状态：PASS，仅限下述本机环境和 G01 工程/国际版本/启动窗口范围。G02 登录及后续功能尚未验收。

## 实现

- 独立 `CastReaderMac` Catalyst target，直接引用 iOS 的 226 个应用源文件、14 项资源与 ZIPFoundation/SwiftSoup 包。工程生成脚本重复执行不改变工程哈希。
- `CastReaderMacTests` 独立单元测试 target。测试在临时工作区、`com.same.castreader.releasechecksmac` 包身份和私有钥匙串中运行。
- Mac 产品区域和业务路由固定 Global；中国 storefront、时区、缓存、内部开关或启动参数不能切换。
- 正式 App Group 使用既有已授权组；测试组单独使用开发团队前缀。第一次 Mac 测试发现未授权的测试组会阻塞偏好写入，已修正测试组，不修改正式组。
- Mac 使用 iPad 的可变窗口布局；跳过手机方向锁。登录按钮取消 Catalyst 额外灰色框，保留 iOS 自绘外观。
- 修复既有 iOS 隔离测试脚本的 macOS Bash 空数组问题，并把临时启动适配方法放在正式启动实现之后，避免污染启动顺序的源码断言。

## 自动验证

| 检查 | 结果及证据 |
| --- | --- |
| 发布祖先门禁 | `scripts/build-voice-toc-integration.sh --check` 通过 |
| 共享源码/资源及原 iOS targets 不变 | `project-graph-check.json`，通过 |
| Mac 国际版本策略 | `unit-final/summary.json`（最终窗口修正源码再次通过），8 通过、0 失败、0 跳过 |
| iOS 区域/路由回归 | `ios-regression-retry/summary.json`，128 通过、0 失败、1 跳过 |
| 跳过项 | iOS 原有 `testLiveDirectPresetNineLanguagesAndSourceBoundaries` 需要显式开启真实服务测试；本阶段不据此声称音频已验收，留在 G04 |
| Mac Debug | `build-debug-window.log` 成功；小窗口实际滚动复核通过 |
| Mac Release | `build-release-window.log` 成功，最终 arm64/x86_64 产物已签名启动 |
| 签名 | 最终 Release `codesign --verify --deep --strict` 通过，Apple Development 本地候选 |

国际版测试覆盖：CHN/USA/HKG/无效商店区域，各中国时区，旧 CN 偏好，CN 启动参数，CN 后台缓存，内部发行覆盖开关，首次启动不等待 StoreKit，进程冻结，Global 登录/书库入口，以及账号、文档、上传、克隆、解读和 TTS 的实际端点解析。

TTS 保留当前 iOS 行为：预置声音首选 `tts.castreader.ai`，有明确未派发证据时可回退同区 `api.castreader.ai`；账号/克隆/文档/解读使用国际 API。没有把“国际版”错误等同于只能访问一个域名。

## 实际界面对照

- 对照来源：同一源码编译的隔离 iPad App，iOS 26.5 模拟器，不启用跳过登录或假权益参数。
- Mac 来源：真实签名 Debug 和 Release，本机 Apple silicon、macOS 26.2。
- 实际看到双方均有 Kindle/WeRead/PDF/Web/YouTube 价值说明，Apple/Google/邮箱入口和条款/隐私链接，无中国区手机号入口。
- Release 带 `-CastReaderRegion cn -CastReaderServiceRoute cn -CastReaderComputeRoute cn` 启动，仍呈现国际版。
- 普通窗口及最大化布局对照通过。缩小到约 520 × 372 点时发现手机布局裁切，修正后实际滚动可完整显示 Apple、Google、邮箱和条款/隐私入口；再放大窗口正常。
- 自动化工具的截图和 AX 树在本聊天工具记录中。未将这些截图当作后续阅读、同步或登录成功的证据。

## 当前边界

没有执行发布、商店提交、公证或订阅变更。Intel 只有编译结果；macOS 14.6 是编译解析的最低系统，没有该系统真机验证。真实账号登录、会话重开与切账号验证属于 G02，尚未通过；G03–G15 仍按门禁等待。

测试组依据：[Apple：macOS App Group 容器](https://developer.apple.com/documentation/xcode/accessing-app-group-containers)。
