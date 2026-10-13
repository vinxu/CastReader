# iOS 1.2.34（54）已提交审核

2026-09-06 12:16（北京时间），版本与 Review Submission 均已回读为 `WAITING_FOR_REVIEW`，审核通过后自动发布。

本次在独立发布树整合，保留完整 1.2.33 基线；不要用本目录仍停留在旧基线的工程直接覆盖正式版本。发布代码已推送 `origin/codex/ios-release-1.2.34`，记录提交 `578bd91`。

- [完整发布报告](/Users/xuxuheng/Documents/.worktrees/CastReader-ios-release-1.2.34/docs/iOS-1.2.34-Release-Report.md)
- [提交后回读](/Users/xuxuheng/Documents/.worktrees/CastReader-ios-release-1.2.34/reports/ios-release-1.2.34/post-submit-audit.json)
- [正式包模拟书架排除检查：119 个文件、30 类标记、零匹配](/Users/xuxuheng/Documents/.worktrees/CastReader-ios-release-1.2.34/reports/ios-release-1.2.34/no-shelf-fixtures.json)
- [正式归档](/Users/xuxuheng/Documents/.worktrees/CastReader-ios-release-1.2.34/build/CastReader-1.2.34-54.xcarchive)

Build ID：`c7e03dec-5c12-4914-a69b-ec1a7db2c7b6`（VALID / APP_STORE_ELIGIBLE）；Review Submission ID：`59fab953-41d1-4cd3-94f7-3221822b70f8`。

## 真机测试包纠正（2026-09-06 13:55）

用户反馈邀请录音、上传音频及第三张首页 banner 缺失后，读回 iPhone 仍安装旧基线 Kobo 测试包 1.2.32（53），其二进制没有这两个新入口。送审 1.2.34（54）归档包含入口，上传开关为 true；邀请入口另受账号服务端能力控制。

已从同一 Release 归档重新导出开发签名包并覆盖安装，回读手机为 1.2.34（54），主程序 UUID 与归档一致；119 文件/30 类模拟书架标记检查为零匹配。手机锁屏阻止自动启动，界面等待用户解锁后核验。

[真机安装核验](/Users/xuxuheng/Documents/CastReader/reports/ios-release-1.2.34-device-install-validation.json)
