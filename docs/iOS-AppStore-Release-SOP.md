# CastReader iOS → App Store 发布 SOP

## 自动入口

用户说“提交到 App Store 审核”“提交到应用市场去审核”“发布 iOS 新版本”时，使用：

`$submit-castreader-ios-to-app-store`

Skill 路径：`/Users/xuxuheng/.codex/skills/submit-castreader-ios-to-app-store/SKILL.md`。

该指令授权从版本选择、归档上传、11 语资料到正式送审的完整流程；“检查/规划/打包”不授权上传和送审。

## 固定项目参数

- App Store Connect App ID：`6757636395`
- Bundle ID：`com.same.castreader`
- Workspace / Scheme：`CastReader.xcworkspace` / `CastReader`
- Team：`KQW6UNZE8J`
- App 运行时 9 种语言：英语、简体中文、日语、西班牙语、法语、德语、
  巴西葡萄牙语、意大利语、印地语
- App Store 元数据 11 个 locale：`en-US`、`zh-Hans`、`ja`、`es-ES`、
  `fr-FR`、`pt-BR`、`it`、`hi`、`de-DE`、`zh-Hant`、`es-MX`
- 当前文案源：`docs/CastReader-AppStore-Metadata-11-Languages-1.2.20.md`
  （旧版 `CastReader-AppStore-Metadata-8-Languages.md` 仅作历史基线）
- API Key 安全路径：`/Users/xuxuheng/.appstoreconnect/private_keys/AuthKey_6QN4G1IJDEP1.p8`

## 完成链路

1. 读取现有版本、审核状态、最大 Build、待处理 Review Submission。
2. 确定未占用的版本号和更大的 Build，统一 App、Share Extension 与 Widget 版本字段，并确认 Safari Extension target 不存在。
3. 校验 11 语功能声明、元数据长度和真实代码差异，运行测试。
4. Release archive，检查 Bundle ID、版本、Build、entitlements 和加密声明。
5. 使用 `xcodebuild -exportArchive` 的 App Store Connect upload 方式上传；等待 `COMPLETE / VALID / APP_STORE_ELIGIBLE`。
6. 当前版本仍在审核时保留已上传 Build，等待其可发布后再创建下一商店版本，不擅自撤审。
7. 创建新版本并选用新生成的 `PREPARE_FOR_SUBMISSION` App Info；不能修改历史 `READY_FOR_SALE` App Info。
8. 写入 11 语名称、副标题、隐私链接、描述、关键词、推广文本、支持/营销 URL 和 What's New。
9. 回读截图组，绑定准确 Build，核对审核联系人、内容版权、出口合规和发布模式。
10. 使用 Review Submission 三步流程正式提交；旧 `appStoreVersionSubmissions` 创建接口不可用。
11. 回读版本和审核单，二者进入 `WAITING_FOR_REVIEW` 或后续状态才算完成。

完整 API 请求、失败恢复、截图回退和字段限制，以 Skill 的 `references/` 为准。
