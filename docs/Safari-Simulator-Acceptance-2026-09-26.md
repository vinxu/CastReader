# iPhone / iPad Safari 朗读适配验收

> 后续更正：本轮纯文本/Range 验收遗漏了 WebKit inline 高亮像素残留。后续修复和复测请见 [高亮残留修复报告](Safari-Highlight-Repaint-2026-09-26.md)。最新版真机包已安装，真机 Safari 验收仍待完成。

日期：2026-09-26。范围：本地开发候选，普通英文文章的前台朗读；没有提交 App Store。

## 环境与方法

- iPhone 15 Pro Max，iOS 26.5，Safari；视口宽度 430 / 814 CSS px。
- iPad Air 11-inch M4，iPadOS 26.5，Safari；视口宽度 820 / 1180 CSS px。
- iOS App/appex：1.2.45（68），扩展 manifest：1.2.46；从已核对的 iOS 1.2.45 发布基线 `ffc7c8f` 增量整合，原生会话修订 `769e1a0`。
- 扩展分支：`codex/safari-iphone-adaptation-20260926`，本轮实现提交 `0c28af8`；iOS 分支：`codex/ios-safari-iphone-20260926`。
- UI 操作通过 Simulator 实际点击完成；测试文本为本地自建文章，包含标题及 12 个正文段落。调用真实线上预设 TTS，未替换音频或播放器。
- 专用验收构建每 250 ms 只读采样真实 `HTMLAudioElement.currentTime`、音色、段落、CSS Highlight 的 DOM Range、滚动位置和错误计数。探针仅允许 `127.0.0.1:4327/safari-acceptance.html`，不输出账号、凭据或正文，也不控制播放。
- 普通构建关闭 `CASTREADER_SAFARI_ACCEPTANCE_TEST`。发布门禁检查探针不存在；普通构建已重新编译，并在 iPhone / iPad Safari 验证播放、高亮与滚动。

## 发现并修复的问题

1. **原生会话字段不完整**：Swift handler 没有返回 JS 解析器要求的 canonical account、存储隔离 ID 和登录边界。只在私有原生会话响应中投影经过校验的身份；退出登录返回明确状态，不暴露 OAuth token。新增真实 Swift 输出 → JS 解析器集成回归。
2. **iOS manifest 缺少 `nativeMessaging`**：静态 mock 没有发现 Safari 拒绝原生通信，实际点击会报无法取得 App 账号/线路。补齐 iOS 权限，并加入打包产物检查。网站访问仍通过 Safari 的逐站授权完成。
3. **触摸首次点击被 hover 消耗**：iPad 需要第二次点击才开始。仅真实 mouse pointer 触发悬浮展开；hover 提示受媒体查询约束。iPhone 和 iPad 均验证单次点击启动，鼠标拖拽回归通过。
4. **旋转重排后当前词落在屏幕外**：停止后重启与旋转重叠时，Safari 重置滚动位置、取消初始平滑滚动，旧实现直到下一段才恢复。启动/恢复和宽度变化后重查当前词的真实 Range，持续覆盖当前段落的后续词，仅在屏幕外时恢复文章滚动。第一版仅恢复 1.5 秒，iPad 复测发现后续词仍可能出屏，最终修订覆盖到当前段读完。保留手动滚动宽限，不接管 Canvas/iframe 分页器，也没有暂停或停止后的迟到定时器。

## 核心流程结果

| 场景 | iPhone | iPad | 实际证据 |
|---|---|---|---|
| 首次点击播放 | 通过 | 通过 | 一个点击后真实音频时间推进 |
| 逐词高亮 | 通过 | 通过 | 读取实际 CSS Highlight Range，与当前音频时间戳比较 |
| 自动滚动 | 通过 | 通过 | 普通长文累计滚动到 2337 / 1410 CSS px |
| 跨段续播、自然结束 | 通过 | 通过 | 标题和全部 12 个正文段落均播放；到末段进入 idle |
| 暂停 | 通过 | 通过 | 音频时间分别固定 24.696 秒 / 45.384 秒，高亮保持 |
| 恢复 | 通过 | 通过 | 从暂停点继续，并自动进入后续段落 |
| 换音色 | 通过 | 通过 | Heart ↔ Bella；实际 segment voice 跟随选择，继续朗读 |
| 倍速 | 通过 | 通过 | iPhone 1.25→1.0；iPad 1.25→0.75，实际播放速率同步改变 |
| 停止、重新开始 | 通过 | 通过 | 停止清空音频队列和高亮；连续观察 21.677 / 31.504 秒没有自行复播，之后可再次启动 |
| 横竖屏、面板 | 通过 | 通过 | 朗读、音色和倍速控件可操作；复测重排后的当前词位置 |

“通过”限于这里列出的测试环境、文本和操作。自然结束与用户停止的状态不同：自然结束可保留已播放队列，但不再推进；用户停止要求队列清空。

## 数值记录与回归

- iPhone 主流程：565 个 playing 采样，564 个带有效词 Range；iPad 主流程：641 / 635。少量采样处于词与段落边界，不把“有 Range”当成所有瞬间均已验证。
- 当前高亮词对应的时间戳区间到音频时钟的 P95 距离：iPhone 77.54 ms，iPad 59.53 ms。这衡量客户端同步，不是听感或语音强制对齐精度。
- 修复前 iPhone 重排用例有 44 个屏外高亮采样，约 11 秒；修复后同类用例 126 个播放采样均有词高亮，屏外采样为 0。iPad 第一版短时恢复仍有 13 个屏外采样；最终 `ipad-reflow-paragraph-final` 共 272 个播放采样、270 个词高亮采样，屏外采样为 0，跨段继续至第 12 段自然结束。
- 成功主流程和最终重排用例中，TTS 错误、丢失锚点、断开锚点计数均为 0。
- 原生 `SafariExtensionContractTests`：12 项通过，含真实模拟器 Keychain 与身份隔离。
- Swift→JS 会话投影、打包 nativeMessaging 回归通过。
- 播放缓冲、暂停期间生成与取消回归通过；触发按钮位置与拖拽回归通过。
- 新增真实 DOM 重排回归：旋转后恢复当前词、暂停不抢滚动、恢复、手动滚动优先、停止无迟到回调；通过。现有逐词源文本映射浏览器回归通过。
- Voice Clone 合同、类型检查、浏览器回归通过；浏览器集成 399 assertions / 46 scenarios，使用隔离 profile 和 fixture 响应，不代表在 iOS 实测了个人克隆音色。
- Chrome / Safari 生产构建成功；Safari 资源门禁 **180** 项通过，Chrome/Safari 结构与合同对齐门禁 **263** 项通过。这些是打包/合同检查，不等于跨浏览器所有网站的端到端等价证明。

构建初次门禁还发现独立工作树只准备了英文 OCR 模型；已从已验证基线补齐全部十个语言模型并通过模型检查后重建，最终资源保留既有多语言能力。

## 证据与复跑

- [采样摘要](evidence/safari-simulator-20260926/summary.json)
- [原始采样，gzip JSONL](evidence/safari-simulator-20260926/samples.jsonl.gz)
- [验收包与普通包哈希](evidence/safari-simulator-20260926/builds.json)
- [iPhone 普通构建截图](evidence/safari-simulator-20260926/iphone-production.png)
- [iPad 最终验收构建截图](evidence/safari-simulator-20260926/ipad-acceptance.png)
- [iPad 普通构建截图](evidence/safari-simulator-20260926/ipad-production.png)

run 名称比 phase 更可靠：phase 是操作员标记，部分标记跨操作沿用；最终判定依据播放状态、实际时钟、段落和 DOM Range。失败的初始 run 保留在原始记录中，不能与修复后的 run 混为一谈。

```bash
node eval/safari-simulator-acceptance-server.mjs /tmp/safari-evidence.jsonl
# 单独生成验收资源，然后同步到指定的 iOS 候选工作树并编译安装。
CASTREADER_SAFARI_ACCEPTANCE_TEST=1 CASTREADER_SAFARI_PLATFORM=ios pnpm exec wxt build --browser safari
node scripts/prepare-safari-output.mjs ios
# 在 Safari 打开 http://127.0.0.1:4327/safari-acceptance.html?run=<case>
# 启用扩展并只给测试站点/API 站点授权，然后通过 UI 操作。
pnpm test:highlight:viewport
CASTREADER_IOS_PROJECT=<candidate-checkout> pnpm test:safari:ios-native
```

## 尚未覆盖

本轮未用最新版真机包回归，也未实测真实 Pro 登录/购买、个人或赠予克隆音色、所有语言、Kindle/WeRead/Canvas 网页、PDF、复杂第三方网站、iPad 分屏窗口、后台/锁屏或长时弱网。音频通过真实媒体时钟和浏览器播放状态验证，未做外放录音或逐字听感审校。不能据此宣称“所有场景无 BUG”或“完全等同 Chrome/Mac Safari”。

架构审核：`voice-clone-system-v1`。本次没有扩大网站 host 域名、修改克隆 API 或扩展区域路由；修复的是既有 iOS 原生会话投影和 manifest 原生通信权限。
