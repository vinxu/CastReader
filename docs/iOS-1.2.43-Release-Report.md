# iOS 1.2.43（65）通用 iPhone / iPad 发布记录

状态：发布准备与验收中，尚未上传、尚未送审。不得将本记录视为已发布。

## 正式合并与功能保留

2026-09-21 从远端重新获取 `main`，最新为 `8298f84`。ASC 同时确认 1.2.42（64）为 `READY_FOR_SALE`，没有其他活动审核单。新发布分支 `codex/ios-release-1.2.43` 从该提交建立，以双亲合并 `e2b3878` 纳入整个 `codex/ipad-adaptation`（`bcd9778`）。合并无冲突，合并结果与 iPad 功能分支的树完全一致，不是从孤立旧分支打包。

- iPhone 应用发布源码 `1ce1e56` 与 1.2.41 完整发布增量 `94499d2` 均为祖先。
- 保留既有语音/声音发现、社区与私人声音、换声续播、额度隔离、EPUB 目录与插图、PDF 原页/OCR、Kindle 离线、书架恢复、更多/Aa/定时及播放器失败恢复。
- 必备提交 `64c2dbd`、`633f6bb`、`ad4b885`、`48998e7`、`f94b41d`、`9935c6d`、`94499d2`、`d4e427c`、`d165045`、`1ce1e56` 的祖先门禁通过；新增 7 个 iPad 功能提交全部包含。
- App / Share Extension / Widget 均为 1.2.43（65），支持设备族 `1,2`。相同 Bundle ID `com.same.castreader`、相同商店 App ID `6757636395`，同一个下载同时支持 iPhone 与 iPad。
- iPad 支持四方向旋转、按窗口宽度布局、多窗口会话、导入、原生与商业阅读器、书架和播放控件。保持用户确认的移动端 Safari 不在发布范围。
- 源码身份与逐文件摘要保存于 `reports/ios-release-1.2.43/`。原 iPad 验收详情见 `docs/CastReader-iPad-Delivery-2026-09-21.md`。

## 验收范围与状态

已保留 iPad 各模块与 Kindle / Google Play Books / Kobo / 微信读书实际账号验收证据；最终共享平台回归 276 通过。O’Reilly 没有可用绑定账号，不声称新增真实在线验收。合并没有改变这些已验证功能的源码；版本与发布配置另行验证。

合并后在 iPhone 15 Pro Max 发现根视图泛型元数据初始化导致的启动栈溢出（`startup-crash.ips`）。在主导航、窗口生命周期与展示层之间加入稳定 `AnyView` 边界后，正常开发签名真机包可冷启动、恢复阅读并处理冷启动导入链接；保留所有已有状态对象和业务实现。窗口探针绑定时优先消费待处理链接，避免先恢复无关旧会话。

首次广泛单测为 1,842 通过、13 失败、8 跳过。修正未登记的“正在导入…”本地化键、拖入测试对真实登录的依赖、iPad 可视阅读带测试取样、离线多窗口保留合同及启动源检查后，相关套件 189 通过、0 失败、1 跳过。新增账号边界缺失/切换时丢弃迟到拖入结果两例。

首次执行中，一条旧 `ServiceRoutingTests` 用例直接删除了真实模拟器的本地登录 Keychain。此为测试隔离疏漏；用户随后重新登录，既有 Kindle、Google Play、Kobo、微信读书书架仍可读取。修复该用例的保存/恢复，并新增 `scripts/verify-isolated-unit-tests.sh`：复制当前候选到临时工作目录，仅替换独立测试 App/扩展 Bundle ID、App Group、私有 Keychain group/service 与旧迁移组，审核模拟器嵌入 entitlement 后才执行。该脚本始终使用原有同一台模拟器，独立应用不共享正式账号容器。

最终隔离单测 **1,857 通过、0 失败、8 跳过**，耗时约 601 秒；另显式排除会改变账号状态的 `PaymentTests`。8 项跳过分别为两个外部 EPUB 样本、线上解读评估、真实 Google 图书 shell、用户 PDF 性能样本、用户 PDF 内存样本、九语线上 TTS、注入公共 URL 的 YouTube 线上提取。完整证据：`reports/ios-release-1.2.43/isolated-20260921T223653/`。

合并后又在同一台 iPad 上完成九语 375 pt 窄窗口首页、音色搜索和文件导入入口检查。前七语证据在 `compact-ui-20260922T005036`；意大利语与印地语补验在 `compact-ui-20260922T010220`（PASS）。测试先遇到系统评分弹窗、快速滚动越过目标行和拖动被横向控件截获，已改为关闭“稍后评分”、按目标方向拖动纵向滚动区域的边缘，未删减可点击及窗口边界断言。各语抽样截图已目检。九语检查使用独立应用、无账号，不作为真实书架或真机核心证明。

`testUniversalNavigationAndAllOrientations` 在 `compact-ui-20260922T005036` PASS：四方向首页，以及书架、音色、设置、首页和导入弹层横竖屏。此前模拟器系统旋转未响应；仅重启原有同一台模拟器后恢复，未新增、抹除设备或账号。

真机 iPhone 使用正常开发签名候选。国际英文常规朗读已观察到 `af_bella` 新生成、真实播放、段落继续和词高亮；选择社区 `vl_d1efb23a380bdaa2f6b0` 成功生成待播放音频。因设备低电量及镜像连接超时，完整换声与两区核心矩阵尚未完成，**不将这些部分证据记为核心 PASS**。用户已充电锁屏，等待镜像恢复继续验收。模拟器不替代真机核心门禁。

2026-09-22 00:42，Xcode 已可见有线 iPhone 15 Pro Max（iOS 26.7），设备报告 `unlockedSinceBoot=true`、`passcodeRequired=false`，但镜像仍显示连接超时。另尝试不跳过登录、不注入内容的 Xcode 真机启动检查，编译签名成功，00:57 测试运行器初始化返回 `com.apple.LocalAuthentication Code=-4`（认证已取消），实际测试尚未执行。证据为 `device-authorized-launch.log/.xcresult`。仍需用户手动恢复系统认证/镜像显示后继续。

| 地区/输出语言 | R-K | R-C（vl/vc） | E-K | E-C（vl/vc） |
| --- | --- | --- | --- | --- |
| CN / zh | NOT_RUN | NOT_RUN / NOT_RUN | NOT_RUN | NOT_RUN / NOT_RUN |
| International / en | NOT_RUN | NOT_RUN / NOT_RUN | NOT_RUN | NOT_RUN / NOT_RUN |

现有且唯一启动的模拟器为 `BFCF61DE-9C45-4467-8996-6F4E03AE7725`；本地登录已由用户恢复，各平台绑定和缓存保留。真机为已配对 iPhone 15 Pro Max。

## 商店资料与构建计划

- 已保存当前 ASC 11 语 App Info、11 语版本文案及 9 组共 45 张 iPhone 截图快照。
- 保留标题、副标题、关键词、推广文字、原有描述与有效 iPhone 截图；仅在 11 语描述增加 iPhone/iPad 通用支持段落，更新 What's New，并新增 iPad 物料。
- 不修改价格、订阅、地区、隐私、年龄分级或法律声明。发布方式沿用审核通过自动发布。
- Xcode Apple Accounts 中已看到正确团队及证书/设备权限，正常签名构建成功；正式上传凭据仍以 export 返回为准。
- Preflight 已通过；独立构建目录 `/tmp/CastReader1243Device`，归档/上传必须在核心门禁通过后执行。
- Release 真机开发签名构建 `/tmp/CastReader1243Release` 已成功（不是 App Store 归档）。三个组件均 1.2.43（65）、团队 `KQW6UNZE8J`、设备族 1/2；四方向 iPad 声明、多窗口、九语编译资源、严格签名校验通过。扫描 124 个文件、54 个书架夹具标记，Release 无匹配，Debug 正对照通过；Safari 扩展不在包中。证据为 `release-device-artifact.json`、`release-device-components.json` 和 `release-device-fixtures.json`。
- 当前应用/配置身份固定为 `3013b71`，309 个文件 SHA-256 汇总 `a08ee45fbac599cf4e21e97fa6f136dcaf9c777e00ef539f14dd1c2ac8b30466`。此后仅测试、截图、脚本和报告变更，已逐文件核对没有改变应用源码或配置。

## iPad 五张商店物料

按用户指定顺序：首页、《地心游记》朗读、同书解读、音色、加号内文件入口。英文版真实采集与五场景自动验证通过（`capture-en-20260921T221924`），5 张成品已逐张目检，尺寸 2048×2732。原始 1640×2360 来自唯一的 11 英寸 iPad 模拟器，等比例完整嵌入商店画布；不冒充 13 英寸硬件实测，不重画产品界面、不裁掉底部控件。

物料位于 `AppStoreAssets/1.2.43/iPad/`，浅暖底色、标题与现有 iPhone 风格一致。中文版采集在修正测试对播放状态的本地化识别后也已 PASS（`capture-zh-Hans-20260922T003214`），5 张成品已逐张目检；失败采集不作为最终物料。共 10 张原图与 10 张成品，`README.md` 保存来源和复现方式，`manifest.json` 保存每张尺寸及 SHA-256。

计划新增 en-US、zh-Hans 各 5 张 iPad 图，其余版本语言回退到英文 iPad 图；上传后仍须核对 ASC 实际回退。保留既有 iPhone 45 张截图。新 `scripts/upload-ipad-app-store.rb` 仅处理本版两语的 iPad 集合，保存每个上传 ID、对不确定写入先回读，不删除旧素材或操作 iPhone/预览。离线检查覆盖完整资产复用、语言不匹配拒绝、不确定预约拒绝重复创建；尚未执行真实上传。

## 仍待完成

1. 恢复真机系统认证/镜像，补齐上表 CN/zh 与 Global/en 四条管线及社区/私人声音子项。
2. 核心门禁通过后，再核对远端主线增量并正式合并到 main；从主线候选归档、官方上传 Build 65，等待精确 Build 为 VALID / APP_STORE_ELIGIBLE。
3. 创建 1.2.43 版本，应用已准备的 11 语说明差异，上传两组 iPad 图，保留原 iPhone 图，绑定 Build、审核资料检查、正式送审并回读状态。

尚未创建 App Store 1.2.43 草稿、归档、上传或审核单；不可将发布准备完成视为已提交。发布技能要求 “Missing/failed/skipped core evidence blocks upload/submission.”，本版的真机核心证据仍未齐全。
