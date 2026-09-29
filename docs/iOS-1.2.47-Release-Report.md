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

2026-09-29 上午连接恢复后的进展：

- 正常 Debug 1.2.47（70）已通过 USB 安装到原 `com.same.castreader`，保留用户数据。Release 开发签名包已重新构建，四组件版本、iPhone/iPad、严格签名、54 个夹具标志扫描及 Safari 摘要复核通过；独立 DerivedData 移至桌面发布目录，避免此前临时构建目录被清理。
- 09:54 确认手机 `passcodeRequired=false` 后，首次完整真机回归执行了 1,950 项，32 项跳过，25 个用例失败（29 个断言/异常）。失败包含真机无法读取 Mac 源码路径、BLOB 测试仍要求旧的截断哈希，以及两处以生成完成/HTTP 失败时间代替音频缓冲就绪/播完时间的测试同步问题。
- 真机测试改为在 XCTest 包中携带白名单源码、合同与本地化快照；不包含 Secrets、会话、收据或正式 App 资源外的用户数据，也不进入发布 App。BLOB 断言校验测试图片完整 SHA-256；预取断言等待下一段缓冲就绪；失败续播断言等待已缓冲前缀自然播完再重试缺失后缀。26 项定向真机回归通过、0 失败、0 跳过，正在补跑完整套件。
- 本轮没有修改 App/Share/Widget/Safari/WebReader 的 415 个冻结文件；工程改动仅为测试目标的助手与构建资料。Release 包不包含 `RepositorySnapshot`。最终完整回归与两区实际播放仍按上表记录，不用定向回归替代核心格。
- App 审核备注已更新为本版购买路径并回读验证，3,364 字符，其余审核联系/登录字段不变。本地 11 语元数据文档的 What's New 已与已上传 JSON 一致。Apple 文档提示首次内购需通过网站随 App 二进制送审；最终提交时需核实同批包含本版 App 和额度商品，不能只提交其中一项。

10:17 回归收尾：`physical-unit-tests-r5-full` 执行 1,950 项，1,929 通过、20 跳过、1 失败；失败项发现额度购买新增 22 条文案缺少日/西/法/德/巴葡/意/印地语。已补齐 154 个译文，保留中英文和其他现有条目。受影响的完整 `LocalizationCatalogTests` 在同一真机上复测 50 项全部通过。合并两份真实结果后为 1,930 通过、20 跳过、0 未解决失败；这不是伪称一次全绿的 xcodebuild，失败原始记录保留。

20 项跳过包括 10 项依赖 Mac localhost 的 StoreKit/额度集成夹具，另 10 项需要未提供的本地真实文档或显式实网开关；真实购买及核心服务仍通过产品真机流程验收，不将这些跳过算作通过。明细见发布证据 `physical-unit-tests-combined.json`。此次变更的正式应用资源仅为购买文案本地化；Debug/Release 包均已重建。更新的 Debug 1.2.47（70）已装机并按 Global 正式线路启动，禁用 Debug Pro，不使用私人 Preview 或注入音频。
