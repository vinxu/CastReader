# Pro 跨端同步修复与发布验证 · 2026-09-25

当前结论：已复现并修复移动端“本地购买标记覆盖服务端 false”的缺陷，多渠道权益聚合回归通过。真实设备的最终朗读/解读及购买恢复验收尚未完成，因此移动端尚未上传/送审，也不能宣称全部端到端验收完成。

## 权益规则

- 同一个 CastReader 后端账号的订阅统一聚合。Apple、Google Play、Stripe、支付宝中任一仍有效的付费订阅或免费试用，均可以产生账号级 Pro；较新的失败记录不能覆盖另一渠道的有效订阅。
- 没有任何有效订阅/试用时，服务端返回 false。试用到期未转付费、过期及扣款失败记录本身不产生 Pro。已取消续订但仍在已付费期限内的权益不提前撤销。
- iOS/Android 使用当前账号最近一次成功查询的 true/false；本地 StoreKit/Play 标记仅用于验单/同步，不能独立恢复 Pro。
- 网络错误、超时、5xx 是未知结果，不伪装成 false，也不把上次 false 变回 true。沿用既有启动、前台、登录、购买/恢复刷新点，没有新增权益到期计时器或逐词/逐段查询。
- 登录账号变化或退出时清理旧权益，并拒绝旧请求延迟返回。离线时无法立即知道服务端账单变化；下一次成功查询收敛。新进程尚未取得服务端结果时不凭本地购买标记授予 Pro。

## 可重放的证据

| 场景 | 证据与结果 |
|---|---|
| 真实扣款失败投诉账号 | 2026-09-25 01:58:52 UTC，只读查询账单及现有会话；移动 status/v2 两种既有安装上下文和扩展状态接口均 HTTP 200、pro=false；没有改订阅或增长记录。账号私有信息留在本地私有报告。 |
| 修复前 iOS | 使用脱敏后的真实 HTTP 响应喂给实际 ProManager：serverPro=false，但旧 StoreKit=true 使 isPro=true，回归用例明确失败。不能据此断言投诉人历史 iPhone 一定具有同样的本地 StoreKit 快照。 |
| 修复前 Android | 实际 ProEntitlementPolicy 在 server=false/local Play=true 时仍为 true，回归用例明确失败。 |
| 修复后 iOS | 13 项 Pro 同步测试通过，包括 false 覆盖旧购买、true 恢复、100 次未知结果保持最后值、乱序回复、账号切换及退出。受影响套件 258 项：257 通过、1 项显式 live probe 跳过。 |
| iOS 完整回归 | 首轮 1,886 项：1,877 通过、1 失败、8 跳过。失败来自测试假定段首自然落在视口底部 10%；仅修正夹具摆放后完整 ReaderViewportTests 7/7 通过。合并最新逐项结果为 1,878 通过、0 未解决失败、8 跳过，并保留原失败日志。 |
| Android 完整回归 | 最终 1.0.54（61）Release 构建中，Global 2,058 项、CN 2,084 项全部通过，0 失败/错误/跳过；涵盖实际响应解析、乱序、线程竞态、退出、换账号和跨午夜的权益/每日额度隔离。 |
| 多渠道数据库 | 使用两份实际线上源码（API 和 .com）的权益模型，在一次性本地 PostgreSQL 中验证：有效 Apple/Play/Stripe/支付宝 + 较新失败 Stripe => true；有效记录全部到期 => false；有效试用 => true；试用转付费失败 => false；不同账号不继承。两个源码测试均通过。没有向生产插入测试订阅。 |
| 购买验单路径 | Apple/Google Play 验单与归属模型 53 项测试通过；验证结果绑定 canonical account。真实商店购买/恢复与全部客户端 UI 的联合验收仍待设备条件。 |

8 项 iOS 跳过项属于需要额外私有 EPUB/PDF、可选文件语料或显式启用的 live/network probe，不冒充通过。PaymentTests 未在共享模拟器中执行，以免 StoreKitTest 清理现有交易；本轮使用隔离应用命名空间完成 Pro 回归，保留原 iPad 的登录、Kindle 和书架。

## 源码与版本

- iOS：最新已发布 1.2.44 的 main 基线 b8fcc99a8476e291d4e504001fd8194d1c1523b9；候选 1.2.45（67），修复 c43e48e，测试夹具修订 66fc2e1，均已推送并合入 main。保留 App/Share/Widget、一包支持 iPhone/iPad 和 iPad 四向旋转。
- Android：Play Console 当天读回最新线上及最高上传制品 1.0.53（60），生产 100% 且无待发布变更；以已发布源码后继 d3d7828 为基线，候选 1.0.54（61），提交 4cf9de529bbf06114a0ef97c607a6049c59c825f 已推送。未混入另一工作树仍在开发的 Pad 功能。
- 后端：生产运行代码无需新增修改或部署；只补充数据库回归测试 d78abe9b，已推送独立分支。没有新增过期字段、后台轮询或支付策略。
- Chrome 控制台已读回扩展 1.2.46 待审核、1.2.45 线上；没有替换已提交包。

## 发布状态与剩余门禁

iOS 的 Release 编译、归档、App Store 分发签名和本地 IPA 导出全部成功；九语资源、App/Share/Widget 版本、iPhone/iPad 设备族及 iPad 四向旋转校验通过。归档通过 54 项测试夹具排除检查，导出的 IPA 另检查 54 项夹具和 2 项 Pro 调试标记，均无命中。IPA 是商店分发包，尚未上传，不能当作任意真机可直接安装的调试包。

Android 两区 Release 单测、lint、全球 APK/AAB、中国 APK 在同一次冻结源码构建中成功完成。lint 无 Error/Fatal，Global 有 480 项、CN 有 485 项非阻断 Warning，未隐藏或标成已修复。三个制品签名均与现有发布证书一致。APK 实际清单确认 package=com.same.castreader、版本 1.0.54（61）、minSdk=24、targetSdk=36、不可调试；CN 无 Play Billing 权限或 Play/Google services/YouTube 包查询，保留支付宝活动和钱包查询，生产手机号 fallback 关闭。AAB 签名通过，与已审计全球 APK 使用同一冻结源码及配置。

交付目录：`/Users/xuxuheng/Desktop/CastReader-Pro-Sync-20260925/`。以下均是候选制品，不表示已经通过真机验收或发布：

| 制品 | 相对交付目录的路径 | 字节数 | SHA-256 |
|---|---|---:|---|
| iOS 1.2.45（67） | `iOS/AppStore/CastReader.ipa` | 43,670,244 | `e20c9efdb7ebec2f306c1d7a9300def8d1f3686d12c069a0666adf9256f472de` |
| Android 1.0.54（61）全球 APK | `Android/CastReader-1.0.54-61-global.apk` | 73,111,024 | `de6467938295ab81f72b770cd9858ea2f040b7f4bc1d0f20b79376facf7fe02d` |
| Android 1.0.54（61）Google Play AAB | `Android/CastReader-1.0.54-61-global.aab` | 54,958,380 | `95b4a51ec4670d3c1f36677b6db6f577fb06dad8530c005aa3eee0e5d68a8249` |
| Android 1.0.54（61）中国 APK | `Android/CastReader-1.0.54-61-cn.apk` | 72,966,532 | `26c2b85ad7416b903ac695ac8ea30b1f4b701c9baf2780b0813a68f077241bcb` |

交付目录内 `iOS/制品校验.json`、`Android/制品校验.json` 保存源码提交、签名、生产配置及验证状态；证据不含签名密码、会话令牌或用户私人音色 URL。

当前设备：iPhone 15 Pro Max 开发连接 tunnelState=unavailable、ddiServicesAvailable=false；Android 只有 emulator-5554，没有连接真机。不能以配对记录、模拟器画面、HTTP 200 或单测总数代替候选包的真实播放。

仍须在最终正式候选完成 Global 英文、CN 中文的朗读/解读 × Kokoro、社区 vl_、私人 vc_：实际生成、播放推进、跨段/块、高亮/原文标注及切换，再验证同账号购买恢复与跨端状态。通过后才上传 App Store/Google Play 和发布 CN APK；目前均未执行。

证据目录：
- iOS：reports/pro-sync/ 与 reports/ios-release-1.2.45/。
- Android：Android 发布工作树 reports/pro-sync/。
- 真实账号只读结果：主目录 reports/ios-pro-expiry-20260925/（private 文件不入库）。
- 数据库与验单：readout-web-mobile-pro-deadline-20260925/reports/pro-sync/。
