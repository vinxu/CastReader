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

1. 用 Skill 的 `release_ops.rb inspect` 读取现有版本、审核状态、最大 Build、待处理 Review Submission 和下一版本创建门禁，并保留输出 ID 供续跑。
2. 确定未占用的版本号和更大的 Build，统一 App、Share Extension、Widget 的 Debug/Release 版本字段。
3. 运行 `preflight.rb`；先跑单元测试，再跑耗时较长的 UI 测试。失败修复后先重跑目标测试。
4. Release archive，检查 Bundle ID、版本、Build、entitlements 和加密声明。
5. 使用仓库固定的 `scripts/AppStoreExportOptions.plist` 上传；用 `release_ops.rb wait-build` 等待精确 Build 达到 `VALID / APP_STORE_ELIGIBLE`。API 可读取 build upload 时再核对 `COMPLETE`。
6. 当前版本仍在审核时保留已上传 Build，等待其可发布后再创建下一商店版本，不擅自撤审。
7. 用 `release_ops.rb create-version` 先 dry-run、再 `--execute`，创建或恢复版本并取得 `PREPARE_FOR_SUBMISSION` 与基线 App Info ID；不能修改历史 `READY_FOR_SALE` App Info。
8. 写入 11 语版本资料。用户要求名称/副标题不变时设置 `ASC_SKIP_APP_INFO=1`，完全跳过 App Info 写入，并用 `release_ops.rb audit --title-policy preserve` 对 11 语基线逐项核对。
9. 回读截图组，绑定准确 Build，核对审核联系人、内容版权、出口合规和发布模式。
10. 用 `submit_review.rb` 先 dry-run、再 `--execute`；脚本恢复已有审核单并确保只有一个版本项，避免重复提交。旧 `appStoreVersionSubmissions` 创建接口不可用。
11. 回读版本和审核单，二者进入 `WAITING_FOR_REVIEW` 或后续状态才算完成。

## 标准命令入口

```bash
SKILL=/Users/xuxuheng/.codex/skills/submit-castreader-ios-to-app-store
ruby "$SKILL/scripts/preflight.rb"
ruby "$SKILL/scripts/release_ops.rb" inspect
ruby "$SKILL/scripts/release_ops.rb" wait-build --build-number <build>
ruby "$SKILL/scripts/release_ops.rb" create-version --version <version>
ruby "$SKILL/scripts/release_ops.rb" create-version --version <version> --execute
ruby "$SKILL/scripts/release_ops.rb" audit --version-id <version-id> --build-id <build-id>
ruby "$SKILL/scripts/submit_review.rb" 6757636395 <version-id>
ruby "$SKILL/scripts/submit_review.rb" 6757636395 <version-id> --execute
```

除明确带 `--execute` 的创建/送审命令外，上述状态检查与 dry-run 都是只读操作。REST 读取会对临时网络错误自动退避重试；写请求结果不明确时不得盲目重发，必须先回读并恢复已有对象。

完整 API 请求、失败恢复、截图回退和字段限制，以 Skill 的 `references/` 为准。
