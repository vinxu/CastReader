# iOS 1.2.47（70）发布记录

状态：合并完成，发布验收进行中；尚未上传或提交审核。

本轮以当前 App Store 1.2.46（69）、远端 main `9eb758b` 为基线，将 Pro 克隆音色额度购买与 Kindle 原生 BLOB 页序、跨页整句和播放预取修复合入独立发布分支。保留 Safari、Share、Widget、阅读位置恢复和其他已发布子系统。四组件目标版本均为 1.2.47（70）。

ASC 基线版本 ID：`f835f4df-b17b-4c1b-a71f-50de22006ae7`，READY_FOR_SALE；基线 App Info：`a3a05161-de19-4dd4-8c99-363187f758c7`。最大已上传 Build 69，当前无活跃审核单。沿用 AFTER_APPROVAL。

## 本轮验收

Kindle 功能分支 `bbe7ef7`：114 项受影响真机测试通过；最终实书连续自动呈现 8 个下一页，23 次 AVPlayer 切换中位 168 ms、最大 243 ms，未出现 >600 ms 样本，31 次 TTS 请求无重复。包含切克隆→Bella、暂停和手动 Next/Previous 往返。指标来自应用事件，不是声学静音测量，也不是任意网络的零停顿保证。详见 [Kindle 真机记录](Kindle-原生缓存页序与真机验收-2026-09-29.md)。

额度购买：已完成私人 Preview 的真实 Apple Sandbox 购买、取消、重启补单、重复入账幂等及实际时长扣费；仍需完成发布配置与解读耗尽购买续播验收。历史隔离数据库/模拟器测试单列，不替代本轮真机。用户已要求本轮不使用模拟器。

提交前审查补充：iOS App Review 的 Sandbox 订阅使用隔离账本，沙盒购买必须 Apple 验签、账号归属匹配，不写生产订阅/订单。客户端余额环境依据当前签名 StoreKit 环境，不沿用上次沙盒购买的偏好值。中国和全球账号/声音按现行发布架构隔离；退款通知需送达相应区域账本。

| 地区/语言 | Read Kokoro | Read clone vl/vc | Explain Kokoro | Explain clone vl/vc |
|---|---|---|---|---|
| CN/中文 | NOT_RUN | NOT_RUN / NOT_RUN | NOT_RUN | NOT_RUN / NOT_RUN |
| Global/英语 | NOT_RUN | NOT_RUN / NOT_RUN | NOT_RUN | NOT_RUN / NOT_RUN |

最终源码、完整隔离单测、两区核心实测、服务端部署、归档身份、11 语商店差异、Build VALID 与审核单状态在完成后补齐。任何 NOT_RUN 不计为通过。

商店准备：1.2.47 草稿 ID `138a0a05-56de-42f7-b841-31fdfb842418`，待发布 App Info `acf27d07-c6bd-48e9-abaa-af0f93b723e7`；已仅更新并回读 11 语 whatsNew，description/keywords/promotionalText/supportUrl/marketingUrl 保持基线不变。现有 55 张截图已备份，未替换。Xcode 中开发团队已确认可用。

2026-09-29 服务端与商店准备进展：

- Global 已通过正式工作流 `36471567236`，源码 `6acd3933db95926b7426e1d068e936f30fb24324`，候选 `readout-kokzmoito-castreader.vercel.app`，发布 ID `dpl_DptAVPWCZ8iDrXeNWiCexMSvjB8x`。新鲜 PostgreSQL 额度测试、Apple 归属/隔离、已有音色目录、实际赠送/匿名赠送、Kindle 真实模型、Pro 一致性和阅读修复回执门禁通过；两域名切换与正式线路回读通过。`cloneCredits` 的 enabled/salesEnabled/sandboxIsolated 为 true，包容量 7,200,000 ms。
- CN 原正式源码 `2251845f` 的 10 个应用提交已在 beta 有 patch-equivalent 实现，剩余压缩配置和记录通过 PR #57 合并，未用旧分支替换最新应用。CN 候选 `036a5a9067daa50a46353e93363d88b6c1779b60` 同时继承两区正式基线，应用/依赖与 Global 上述已验证源码逐文件一致。CN 独立部署仍在进行中。
- 额度 IAP `6816697780`、SKU `ai.castreader.clone.minutes120`、版本 `f267f0a8-d537-4fa7-9cc1-1796fc44b71c` 已回读 11 语商品名称/说明；不修改价格或销售地区。正式真机购买页审核截图仍待采集。
- 新提交工具支持 Apple 新版 IAP version 审核项，保留精确审核对象校验与模糊写入恢复；6 个隔离模拟 API 用例通过。在线 dry-run 计划为同一审核单的 App 版本 + IAP 版本两个项目，尚未执行提交。
- 全量真机隔离单测包已构建成功（独立 bundle `com.same.castreader.releasechecks1247`），未运行的原因是 Xcode tunnel unavailable。镜像可恢复但不等于安装通道可用；USB 设备列表当前没有 iPhone。不得将编译成功记为完整单测或核心实测通过。

2026-09-29 03:42 中国区发布完成：`release-20260929034148`，源码 `036a5a9067daa50a46353e93363d88b6c1779b60`，运行时账本、声音邀请数据库、声音克隆合同及入口健康检查通过。`cloneCredits` 与 Global 合同一致，两区未授权余额查询和清理均返回 401。CN 15 分钟清理定时器已启用并执行成功（purged=0），仅清除过期重放音频结果，不删除订单或余额。首次本机组装因磁盘不足停止，清理本轮可重建编译缓存后复用已构建产物成功上线；没有切换过失败候选。

正式发布 PR：<https://github.com/vinxu/CastReader/pull/2>，目前为草稿；代码已推送，尚待最终真机放行后合入 main。服务端 PR #56 / #57 已合并。原始证据目录：`/Users/xuxuheng/Desktop/CastReader-1.2.47-Release/evidence/`；保留私有日志，不提交任何会话、凭据、收据或正文。

2026-09-29 03:51 正式配置包已完成：Release 开发签名 `BUILD SUCCEEDED`，四组件均为 1.2.47（70）及 iPhone/iPad，`codesign --verify --deep --strict` 通过；204 文件/54 个夹具标志扫描为 0 命中，Debug 阳性对照有效，内部控制为 `NO`，Safari content.js 摘要与 1.2.46 一致。应用/组件/WebReader/工程 416 文件冻结清单摘要为 `55506dd555d32ef0170cc08bf38ed16b10d355d8108ae145c7225c5e1c499dff`（`candidate-source-identity.json`）。此包是用于最终真机验收的开发签名 Release 包，尚未归档或上传。

安装再次失败：CoreDevice error 1011，找不到已配对 iPhone；Xcode Devices 为 Disconnected，USB 列表未检测到 iPhone。镜像会间歇恢复，但仍运行前轮包，不能代替最终包安装和测试。当前交付仍未完成：App Store 版本为 PREPARE_FOR_SUBMISSION；最终完整真机单测、两区核心格、解读耗尽购买续播及审核截图待恢复物理连接后进行。未以历史测试、编译成功或服务端通过冒充这些真机验收。
