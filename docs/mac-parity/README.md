# CastReader for Mac 开发与验收入口

唯一产品区域：Global。中文界面、中文内容、中文音色和微信读书继续支持；Mac 不提供中国版入口或区域切换。

当前状态以[实施进度](progress.md)为准；完整功能来源见[40 项功能对齐表](feature-parity.md)。先完成当前 G 阶段的自动测试和真实 iOS/Mac 对照，再进入下一阶段。不能把共享源文件、编译成功、入口展示、mock 或历史 iOS 报告当作真实 Mac 功能通过。

## 工程维护

Mac 与 iOS 引用同一份源文件。新增/删除 iOS 应用源文件时，用 `xcodeproj` 更新 iOS target，再执行：

```bash
ruby scripts/sync-mac-project.rb
ruby scripts/verify-mac-project.rb
```

第一个脚本同步源文件、资源和包依赖，保持重复执行结果稳定；第二个脚本检查 Mac 引用及原有 iOS target/编译配置/扩展依赖没有被意外改变。后续合法修改 iOS 工程时，要在相应提交中记录原因并重新建立审查基线。

## 构建与测试

需复用本机已授权且被 Git 忽略的 `Secrets.xcconfig`，不打印或提交其内容。

```bash
xcodebuild -workspace CastReader.xcworkspace -scheme CastReaderMac \
  -configuration Debug \
  -destination 'platform=macOS,variant=Mac Catalyst,arch=arm64' \
  -derivedDataPath /tmp/CastReaderMacParity -allowProvisioningUpdates build

python3 scripts/verify-mac-bundle.py \
  /tmp/CastReaderMacParity/Build/Products/Debug-maccatalyst/CastReaderMac.app

bash scripts/verify-mac-unit-tests.sh
```

账号、路由及配额单测必须走隔离脚本，不在日常登录的应用容器中直接执行。脚本创建临时源码工作区、独立 Bundle ID、测试 App Group 和钥匙串，验证签名隔离后才运行。正式应用启动代码不添加跳过认证/假 Pro 的测试分支。

Release 使用 `-configuration Release` 和独立 `/tmp/CastReaderMacParityRelease`。当前 target 继承 iOS 17.6，Xcode 解析最低 macOS 为 14.6；这仅是构建下限，最低系统实机验收另列。

安装前对相应 Release `.app` 同样运行 `verify-mac-bundle.py`。它校验主程序、Share 和 Widget 的严格签名、明确的应用身份、沙盒和 App Group 的签名声明及 provisioning profile 授权。三个 Mac targets 均需 `REGISTER_APP_GROUPS=YES`；只有 entitlement 声明或 Xcode 编译成功不足以证明共享容器可用。如果更新 profile 后出现资源签名不一致，只重建该 DerivedData 下可再生的应用/扩展产物，重新校验后再安装，不手动绕过签名。

开发机保留多个相同 bundle ID 的 Debug/Release `.app` 时，系统分享可能选择临时构建目录中的扩展。系统入口验收前用 `pluginkit -m -v -i com.same.castreader.CastReaderMacShare` 核对已选路径，并在实际启动后核对扩展与主程序进程路径。只注销本任务的重复构建副本、登记已安装候选；正常启动一次更新后的主程序后再测冷启动。不得把临时 Debug 命中的结果记作 Release，也不得注销既有 Safari 宿主。

## 证据规则

- 每次测试记录源码基线、候选差异、系统、架构、测试宿主和结果路径。
- 保留脱敏 `summary.json`、源码摘要和阶段报告；完整构建日志及 `.xcresult` 留在本机，不提交凭据或用户私有内容。
- 失败与修复过程保留记录，不能只删除失败结果再宣称首次通过。
- 已存在的 Safari Mac 宿主 Bundle ID 为 `com.castreader.CastReader`；本工程为 `com.same.castreader`。不覆盖 Safari 宿主，协作和账号移交在 G13 单独验证。
- iOS 当前预置 TTS 走 `tts.castreader.ai`，允许合同规定的同区 API 回退；其余国际账号/文档/克隆/解读业务按现行国际 API 合同。禁止为了“统一域名”改变已验证的 iOS 行为。
