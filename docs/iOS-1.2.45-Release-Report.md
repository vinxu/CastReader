# iOS 1.2.45（67）Pro 同步修复送审记录

2026-09-25 **15:12:50 +08:00** 正式提交 App Store，版本与审核单均回读 **WAITING_FOR_REVIEW**，`releaseType=AFTER_APPROVAL`，审核通过后自动发布。尚未代表已上线。

## 版本与构建

- App：`6757636395` / `com.same.castreader`。
- 提交前回读最新线上 1.2.44（66），基线 `b8fcc99a8476e291d4e504001fd8194d1c1523b9`。
- Pro 修复 `c43e48e`，仅测试夹具修订 `66fc2e1`；已在最新发布基线上增量合入主线，后续文档提交不改变归档应用源码。
- App / Share / Widget 全部 1.2.45（67）；保持 iPhone/iPad 通用及 iPad 四向旋转。
- 版本 ID：`ae746723-b147-4254-bd52-52b3ce7d8345`。
- Build ID：`c2ddecfa-6045-4eeb-b451-b6b3d1cc5e97`，官方 Xcode 上传成功，Apple 处理为 VALID / APP_STORE_ELIGIBLE，绑定与回读一致。
- Review Submission：`cb9eea26-98e2-4888-b80a-f15cd0fbb04b`，仅包含本版本一个项目。

## 变更与检查

Pro 权限以同账号最近成功服务端布尔值为准，本地 StoreKit 标记仅作验单同步证据；防止服务端 false 被旧购买标记覆盖。错误保留同账号最后成功状态，退出/换账号清理权益，过时请求不能覆盖新值，没有加入到期计时器或逐段查询。服务端任一有效付费/试用来源仍可授予账号级 Pro，不让单渠道扣款失败覆盖另一有效来源。

13 项 Pro 回归通过；受影响套件 257 通过、1 项可选 live probe 跳过。全量首轮 1,886 项含一项视口测试夹具失败，修正夹具后对应完整套件 7/7 通过，合并逐项最终结果为 1,878 通过、8 跳过、无未解决失败，并非另一次全量重跑。真实账号只读反馈、多支付渠道数据库与验单验证见 [完整验证报告](Pro-Sync-Verification-2026-09-25.md)。

11 种语言更新说明逐项回读一致，其他版本文案、App Info 标题/副标题及审核资料与 1.2.44 一致；55 张现有截图均 COMPLETE。支持/营销/隐私公开链接检查通过。保持价格、订阅配置、目标地区和法律声明。归档/IPA 排除测试夹具和 Pro 调试开关校验通过。

最终候选真机朗读/解读音色矩阵与真实购买恢复端到端验收为 **NOT_RUN**：iPhone 候选已安装启动，镜像仍需手机端身份验证。用户知悉限制后明确要求直接提交，本次按此执行，不将该项写作通过，不修改后续 SOP。

## 制品与回执

- 归档：`/Users/xuxuheng/Desktop/CastReader-Pro-Sync-20260925/iOS/CastReader-1.2.45-67.xcarchive`。
- IPA：`/Users/xuxuheng/Desktop/CastReader-Pro-Sync-20260925/iOS/AppStore/CastReader.ipa`，43,670,244 字节，App Store 分发签名。
- SHA-256：`e20c9efdb7ebec2f306c1d7a9300def8d1f3686d12c069a0666adf9256f472de`。
- 本地回执：`reports/ios-release-1.2.45/submit-review-result.json`。
- 门户审计：同目录 `final-submission-audit.json`、`metadata-patch-audit.json`、`review-detail-audit.json`、`public-links-audit.json`。
- 私有基线和签名凭据不入库。
