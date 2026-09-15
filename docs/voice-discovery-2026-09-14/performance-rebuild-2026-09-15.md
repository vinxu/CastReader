# Voice 性能重构与真机验收 · 2026-09-15

## 结果与边界

在 `codex/mobile-voice-explore-20260914` 的完整上线版本 `192ba4253d757d69786b6f40eebb3cdb25b2bb98` 上增量重构。源代码包含已验证的 `64c2dbd` / `b6dd4d7` 发布祖先；未修改 Kindle、阅读位置恢复、字号、睡眠定时和播放器实现。构建前通过 `scripts/build-reader-more-integration.sh --check`，使用独立 DerivedData。

2026-09-15 已安装并启动到 iPhone 15 Pro Max。真机人工验证首页与 Voice 切换、进入运营专题、社区音色试听进入播放状态、共享每月 2 小时的额度说明。用户随后实际切换、滚动、搜索，反馈“已经明显流畅”。本次未取得真机 Instruments 帧率数据，不能将下面的函数耗时解释成真机整页耗时。

## 数据流

目录及运营内容原本已经通过 API 提供，本次没有修改服务端或运营后台：

- `/api/tts/mobile-catalog?contract=tts-voice-catalog-v1&region=cn|international`：完整元数据及已发布专题。
- 后台仍负责中国区和国际区的专题、模块样式、排序、发布/下架；阅读语言独立于运营区域。
- iOS 在后台恢复缓存、解码和校验网络目录、建立只读快照，再一次性发布到界面。
- 快照预计算音色 ID 查询、语言成员及语言数量；每次读取不再把 1,606 条记录重新转换。
- `VoiceBrowseWorker` actor 处理搜索、筛选、分类、推荐和专题成员。SwiftUI 只读取已准备的结果。
- 搜索索引按目录版本和界面语言缓存，输入防抖 120ms，取消和请求序号阻止旧结果覆盖新输入。分类详情同样走后台处理。
- 推荐数据缓存按偏好和语言区分；运营期次到期自动失效。快照替换时丢弃旧派生缓存。
- 页面按模块延迟构建；试听、额度等状态的观察范围缩小到相关组件。
- 音色头像/封面独立使用缩略图管线：后台磁盘读写、ImageIO 降采样、重复请求合并、最多 4 个同时加载任务，内存缓存上限 100 项 / 24MB。磁盘使用系统可清理的 Caches 目录，文件名使用 URL 摘要。

仍保留完整元数据缓存，未实现服务端分页或服务端搜索。头像、封面和音频不会随目录全量预下载；用户打开相关内容时才加载。当前 1,606 音色规模的卡顿原因已通过客户端处理方式修复，后续若规模明显扩大，可在同一数据层接入分页 API。

## 性能证据

同一台 Mac，真实中国区生产目录（1,606 条：1,323 社区 + 283 常规），Swift Debug 提取函数基准，每项 5 次取中位数。提取脚本使用相同本地化桩，不包含网络、图像、布局耗时。

| 项目 | 重构前 | 重构后 |
| --- | ---: | ---: |
| 获取中文可选音色 | 62.290ms | <0.001ms |
| 获取全部语言摘要 | 396.596ms | <0.001ms |
| 查询中文语言摘要 | 441.601ms | 0.001ms |

实际新后台管线（Debug，包含 actor 调度）：

- 首次建立索引并搜索 `Calm`：83.611ms，266 个结果。
- 9 种不同关键词循环搜索 100 次，使用已建索引：p50 12.244ms，p95 16.767ms。
- 首次准备发现页：29.222ms，5 个运营模块、8 个专题。
- 缓存的发现页请求 100 次：p50 0.007ms，p95 0.022ms。
- Simulator 回归测试：完整目录 1,000 次缓存语言查询合计约 0.256ms；性能防退化阈值 200ms。

20 秒 Simulator 切页采样（`/usr/bin/sample`，1ms 间隔）中，旧版主线程 `availableLanguages` 有 893 个包含子调用的采样点，`voices(for:)` 有 999 个（两者嵌套，不可相加，也不是调用次数）。新版首次/再次进入 Voice 的采样中，这两个函数及反复转换 `option(from:)` 的主线程栈均未出现。该采样确认热点移除，不是帧率测量；两轮 UI 操作和采样点数不完全相同。

本地原始证据：

- 重构前：`/tmp/castreader-voice-diagnostics-20260915/`
- 重构后：`/tmp/castreader-voice-performance-after-20260915/`
- 新版 Simulator 采样物理内存约 99.5MB，峰值约 109.5MB，仅记录本轮观测，不作跨版本内存结论。

## 验证

全部通过：

- 159 项音色相关单元测试：目录/缓存/路由、克隆与额度合同、完整规模查询、跨语言身份、分类顺序/去重、过期运营模块、地区切换、搜索结果一致性和查询竞态。
- 3 项 Simulator UI 测试：中文头部与专题搜索、完整 1,606 目录末尾音色检索、周专题试听/收藏/语言身份/额度说明。另 1 项仅真机 XCTest 在 Simulator 按设计跳过。
- 148 项阅读基础回归：朗读语言、Kindle 导航与阅读设置所有权、位置恢复、播放失败恢复、睡眠定时和 WeRead 开篇播放。
- iPhone 人工测试和用户实际体验，见首节。未声称仅真机 XCTest 或 Instruments 通过。

测试结果：

- `/tmp/CastReaderVoicePerformanceRegression20260915.xcresult`
- `/tmp/CastReaderVoicePerformanceReaderRegression20260915.xcresult`

独立构建：

- Simulator：`/tmp/CastReaderVoicePerformance20260915`
- 真机：`/tmp/CastReaderVoicePerformanceDevice20260915`
- 真机命令：`CASTREADER_DEVICE_DERIVED_DATA=/tmp/CastReaderVoicePerformanceDevice20260915 bash scripts/build-reader-more-integration.sh --device`
- 本地包标识：1.2.40 (61)，`com.same.castreader`；版本号仅作展示，源码以本分支提交和构建记录为准。

不改变声音身份、模型路由、月度生成计量、常规声音权益、跨语言能力，也没有开启新的周度自动发布任务。
