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
