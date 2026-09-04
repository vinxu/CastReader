# 核心服务与客户端提交索引（2026-09-04）

按用户“对应的修改都 commit，避免丢失”的要求，重新核验本轮涉及的八个工作区。下列修改均已提交，记录的关键提交都能从对应分支 HEAD 到达。没有为归档重新部署、发布客户端或执行 push。

## 已保存的提交

| 组件 | 代码 / 证据提交 | 分支 |
|---|---|---|
| iOS | 区域修复 `a1ee5f0`；审计、部署与验证归档 `78a70bf` | `codex/adaptive-voice-clone-denoise` |
| Android | 区域修复 `14b884b`；七个解读入口连续朗读修复 `91e3040`（HEAD） | `codex/android-region-continuity` |
| 扩展 | 区域路由与音频交付修复 `8681577`（HEAD） | `codex/extension-region-continuity-20260904` |
| Kokoro / 监管脚本 | R131b 运行源码 `4eee2f9`；克隆监管解耦及两区部署证据 `77daa03`（HEAD） | `codex/kokoro-playback-priority` |
| 国际 API / Web | 已部署 `2d5575b6`；后续验证 `bcbc5ce4`；本地合并 HEAD `b973ec4b` | `codex/core-audio-regional-continuity` |
| 中国 API / Web | 已部署 `62386e90`；部署与恢复证据 `9852d153`（HEAD） | `codex/cn-local-core-services` |
| 两区 QuickRead 服务 | 已部署源码 `5728d1c`；最终上线与备份清单 `611a6df`（HEAD） | `codex/quickread-server-continuity-20260904` |
| QuickRead 网关 | `d0ded1de`（HEAD），已集成进上述两区 API 发布 | `codex/quickread-continuity-20260904` |

服务端的已部署版本与后续证据提交分开记录；本地 HEAD 不自动代表新的生产版本。iOS 的原隔离分支 `codex/ios-region-continuity-20260904` 仍保留原提交 `c33fc6f`，其修改已通过 `a1ee5f0` 保存到当前 iOS 工作区。

## 工作区位置

- [iOS 与总报告](/Users/xuxuheng/Documents/CastReader)
- [Android](/Users/xuxuheng/Documents/.worktrees/castreader-android-region-continuity)
- [扩展](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-desktop-region-continuity-20260904)
- [Kokoro / 监管脚本](/Users/xuxuheng/Documents/MyProject/.worktrees/castreader-tts-playback-priority)
- [国际 API / Web](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-regional-continuity)
- [中国 API / Web](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-cn-local-core-services)
- [两区 QuickRead 服务](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-desktop-quickread-server-continuity-20260904)
- [QuickRead 网关](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-quickread-continuity-20260904)

核验时，上述七个独立工作区以及 iOS 原隔离工作区均为干净状态。当前 iOS 主工作区还有与本轮无关的 ASO 文档修改和未跟踪文件，未混入本次提交；本轮代码及审计证据没有未提交改动。

完整修改、测试范围、线上版本和待验收边界见[核心服务迭代与验收](/Users/xuxuheng/Documents/CastReader/reports/backend-core-iteration-20260904.md)。客户端源码已保存不等于商店已发布；国际存储与 LLM 处理地域仍需控制面证明。
