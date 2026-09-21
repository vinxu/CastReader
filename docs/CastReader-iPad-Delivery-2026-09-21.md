# CastReader iPad 适配交付记录

日期：2026-09-21。独立分支：`codex/ipad-adaptation`。基线：`8298f84`，应用源码 `1ce1e56`（1.2.42 / 64）。本次没有修改版本号、上传商店或提交审核。

## 交付内容

- 同一个应用原生支持 iPhone / iPad，iPad 四方向与按实际窗口尺寸布局；宽屏导航、阅读栏宽度、迷你播放器和短窗口播放条适配。
- 文本、EPUB、PDF、扫描页、照片、DOCX、网页的朗读高亮、解读标注、旋转位置和缩放恢复。
- Kindle 实际账号书架与朗读/解读，重排期间保留播放会话和原文标注，并从未读内容继续；在线平台、离线阅读和 YouTube 的布局与重排路径。
- 导入、目录、Aa、定时、音色搜索、录音、账号与 Pro、系统分享扩展的窗口和键盘避让。
- 窗口独立的阅读与弹窗状态、唯一音频所有者、切换窗口与关闭窗口时的播放交接，以及进程退出后的暂停恢复。
- 文件/图片/文本/链接拖入、最多 8 项的顺序导入队列、逐项结果、取消清理和重复内容去重；YouTube 待读取字幕的链接不会误报已保存，拖入后不自动播放。
- 大字号、深色、减少动态效果、44 pt 主要播放按钮、指针反馈与场景键盘命令。

详细实现和每个阶段的截图、失败原因、修复后重跑记录见 [实施记录](../reports/ipad-adaptation-20260921/README.md)。原始完整范围仍保留在 [适配计划](CastReader-iPad-Adaptation-Plan-2026-09-21.md)。

## 验证环境与结论边界

按用户要求，后续始终只运行 `CastReader-iPad-11-Adaptation`（iPad Air 11 英寸 M3，iPadOS 26.5）。账号和 Kindle 绑定保留。窄窗口使用同一设备的真实 375×497 窗口；320～1366 pt 的额外尺寸由布局/几何测试覆盖，不冒充其他型号实测。

代码实现与当前单模拟器可执行的核心回归已完成；原计划的完整验收仍有键盘与真机项目未通过验证，不能据此宣称所有设备和输入方式均无问题。

| 最终检查 | 结果 |
| --- | --- |
| 安全单元回归 | 270 个用例均有通过记录：批量运行 269/270，唯一 SVG 像素采样问题修复后单独通过；保留原失败记录 |
| 真实 Kindle | 书架、朗读高亮、解读原文标注、横竖屏、收起展开、重排后自然续读/续解读通过 |
| 窗口与导入 | 375×497 窄窗口、PDF 实际拖入、多项结果、触摸新建窗口、音频交接、关闭窗口和进程恢复通过 |
| 显示与稳定性 | 最大辅助字号、深色、44 点播放按钮、PDF 手动缩放与位置恢复、连续 30 次旋转通过；截图已逐项复核 |
| 构建与资源 | Release 编译、iPhone/iPad 与扩展配置、四方向、多窗口、语言和 Web 资源审核通过 |

最后的真实 Kindle 自然续解读、多窗口修复回归见 `module6-repaired-flow-gate-20260921T130216`；大字号与 SVG 修复见 `module6-final-visual-check-20260921T130828`。详细数据保存在本机实施记录旁。

键盘 Space 播放/暂停及 30 次旋转已通过；Command 组合键和 Escape 的模拟器验证未通过。对照实验中，系统原生文本框的 Command-A 也失效，且曾捕获到请求带 Command 的按键以零 modifier 到达应用；原因尚不能完全归结于应用或模拟器。保留失败记录，需要真实外接键盘确认。

以下没有可用验证条件，均不计为已通过：iPad 真机与 60 分钟稳定性/性能/能耗、相机和多页实体扫描、Pencil/触控板/外接显示器、VoiceOver 与完整键盘导航、17.6/18 等旧系统、其他 iPad 型号和 iPhone UI、两区免费/过期/切换账号与购买退款全矩阵，以及本节追加验收范围之外的第三方阅读器/云盘线上流程。已有 Pro 登录状态、付费页显示与调用编译通过不等于实际购买或完整会员验收。

本次覆盖安装持续保留现有账号、书架与样本文档；未执行降级安装旧 iPhone-only 包再升级的完整迁移实验。其缓存兼容、账号隔离和阅读恢复有独立回归证据。

## 已同步书架的追加验收

2026-09-21 在 `f2b5df6` 之后继续增量适配，仍使用上面的同一台已登录模拟器。Google Play 图书 2 本、Kobo 2 本、微信读书 65 本已同步；没有清空账号、Cookie 或书架，也没有重复要求登录。

| 平台 | 实际验证与修复 |
| --- | --- |
| Google Play 图书 | 首页/完整书架、最大辅助字号与深色、搜索排序、375×497 窗口、目录与原生 Aa；正文朗读/解读、横竖屏与暂停恢复、自然续页通过。修复重排后音频位置、高亮与标注原文定位，并消费新露出的未读内容。 |
| Kobo | 两本真实书籍、搜索排序、最大辅助字号与深色、375×497 窗口、原生字体与目录通过；朗读/解读、旋转、冷启动恢复和自然续页通过。修复 iframe 裁切、实际正文点击、重排遮罩和前后页位置恢复。 |
| 微信读书 | 真实第一章朗读/解读、播放/暂停旋转、字体 18→21→18、标注、迷你播放器、手动翻页与自然续页通过；保留 Canvas 重排中的原文范围与音频位置。最大辅助字号/深色、搜索排序、加载更多、375×497 窗口、全屏/窄窗口双向冷启动句子位置与实际音频恢复、竖屏精确章节跳转与横屏双栏目录均通过。 |
| O’Reilly | 当前连接记录为未连接，缓存书籍为 0；没有真实账号正文验证，不计为已通过。 |

逐次失败、修复、真实服务结果和截图路径见 [平台追加验收记录](../reports/ipad-adaptation-20260921/PLATFORM-LIVE.md)。上述覆盖是平台功能验证，并非逐本朗读全部已同步书籍。三个平台的真实模块验收均已通过。最终共享回归 `platform-contracts-20260921T195948` 为 **276/276 通过，零失败、零跳过**，包含原有 Kindle 位置恢复兼容检查与真实 WebKit 目录控件回归。微信读书新增的双向冷启动恢复见 `platform-weread-resume-20260921T194650`，竖屏精确目录与横屏目录见 `platform-weread-contents-20260921T195730`，相关截图已复核。

追加版本的正常签名 Release 编译与资源/签名审核通过，已覆盖安装到同一模拟器并无测试参数启动；真实微信读书正文恢复没有进度错误提示；实际朗读、高亮推进、横屏双栏播放、暂停后回到竖屏均复核通过，最后停在已登录首页和暂停的迷你播放器。源码和候选包对应关系、二进制哈希记录在候选包旁的本地元数据中。

## 本地复现与验收入口

工作树：`/Users/xuxuheng/.codex/worktrees/castreader-ipad-adaptation/CastReader`。

本地 Release 模拟器候选包：`reports/ipad-adaptation-20260921/platform-final-candidate/CastReader.app`，版本仍为 1.2.42（64）。包与哈希审核结果保留本机，不提交仓库；现有唯一模拟器已覆盖安装，无测试启动参数，账号与 Kindle 绑定可继续使用。

```bash
bash scripts/build-voice-toc-integration.sh --check
bash scripts/verify-ipad-module.sh <记录名称> <XCTest 标识> ...
bash scripts/verify-ipad-live-platform.sh <google_books|kobo|weread> <core|layout|continuation>
bash scripts/verify-ipad-live-platform.sh weread contents
bash scripts/verify-ipad-live-platform.sh weread resume
bash scripts/verify-ipad-platform-contracts.sh GoogleBooksContractTests GoogleBooksWebBridgeTests KoboContractTests ReadingResumeTests WeReadOpeningPlaybackTests WeReadPageAvailabilityTests ReaderAppearanceTests WeReadTOCWebTests
/usr/bin/python3 scripts/verify-ipad-artifact.py /path/to/CastReader.app
```

只使用模拟器 UDID `BFCF61DE-9C45-4467-8996-6F4E03AE7725`。不要运行会登出用户的 `PaymentTests`。原始 `.xcresult`、截图与账号相关日志只保留本机，不提交到源码仓库。

Release 模拟器包需使用正常签名构建，安装前必须通过上面的资源/签名检查。不要将 `CODE_SIGNING_ALLOWED=NO` 生成的纯编译检查包覆盖到已登录设备；它缺少展开后的私有 Keychain 分组，不能代表账号迁移结果。交付包使用原有分组，生产鉴权规则没有放宽。

验收时可从首页分别打开已同步的 Kindle、Google Play 图书、Kobo、微信读书，依次体验朗读、高亮、解读标注、旋转、收起/展开、目录与 Aa；设置中的“新窗口”可体验独立阅读窗口和播放交接。公共样本文本、PDF 和导入测试结果见本地报告。
