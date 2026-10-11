# CastReader iOS App Store 送审 SOP

更新：2026-09-20。**先证明核心服务可用，再处理商店资料。** 正常流程只有五步；同一候选源码的有效结果可复用，不因继续任务而重跑。

使用 `$submit-castreader-ios-to-app-store`。完整“送审”指令授权到正式审核状态回读；仅修改 SOP、检查或打包不授权上传送审。

## 1. 一次确认基线与发布范围

- 读当前 `AGENTS.md`、最新发布记录及差异，选已验证发布工作树，记录 commit、应用源码/配置摘要、版本、Build。**不要默认从主目录旧分支打包。** 每次从远端 `main` 的最新发布基线建立发布分支，功能先正式 merge 到主线，不从孤立功能分支归档。运行 `bash scripts/build-voice-toc-integration.sh --check`：缺少已发管线、目录、本轮修复或插图原页分支任何祖先就停止打包。发布报告必须保存各必备提交的祖先校验，不以版本号或单文件复制代替合并。
- `release_ops.rb inspect` 一次读取商店版本、最大 Build、已有审核单；后续用保存的 ID 续跑。App / Share / Widget 同版同 Build，Build 高于已上传最大值。
- 短预检一次检查签名身份、密钥权限、三个组件、九语资源、29 个商店 locale 文案和发布夹具。Xcode 账号在长构建前确认团队可用；不把本地有证书当作上传登录有效。
- 用户明确授权移动 Safari 发布时，App / Share / Widget / Safari 四组件均须同版同 Build、设备族 1/2，运行 `ruby scripts/verify_safari_extension.rb`，并给 preflight 增加 `--include-safari`。需验收真实 iPhone/iPad Safari 的高亮、滚动、跨段续播、暂停/恢复、换音色、变速和停止清理；静态配置通过不代替这些效果。历史未完成 Safari 禁止入包的规则仍适用于未授权或未通过验收的候选。
- 将当前 ASC 元数据及截图作为基线，只列本次要改的字段/图片。历史模板不能覆盖用户现有资料或删除操作。

## 2. 必过：朗读/解读 × Kokoro/克隆

详细操作和证据格式见 [核心服务验收](iOS-Core-Service-Release-Gate.md)。**四格都要通过；测试通过数量不能替代这个结论。**

| 管线 | 通过条件 |
| --- | --- |
| 朗读 × Kokoro | 原文 → 选中常规声音生成 → 真机出声 → 对应高亮/滚动 → 连续进入下一段 |
| 朗读 × 克隆 | `vl_` 社区与 `vc_` 私人声音均正确生成、出声、续读；身份和额度正确 |
| 解读 × Kokoro | 真实 QuickRead 生成讲解 → 常规声音朗读讲解 → 标注落在原文 → 连续进入下一块 |
| 解读 × 克隆 | 同一解读链路使用 `vl_ / vc_`，不能回放旧声音或把原文当讲解 |

中国线路用中文、国际线路用英文各做一组四格；克隆格内顺带覆盖社区和私人 ID。两种模式都覆盖常规 ↔ 克隆切换、暂停、重试；冷声音准备、旧响应、未知额度用确定性测试覆盖。无需把线上四格机械扩成九语全排列。

先跑相关单测快速定位，再做同源码正常 App 的真实接口/真机播放验收；全量单测在候选冻结后跑一次。`preflight.rb` 和现有试听 UI 用例**不执行这四条服务验收**。核心格失败、跳过或无证据，不能上传/送审；先修复或补齐该格。

## 3. 一次归档、验证、上传

- 核心通过后，在独立 DerivedData 中做 Release archive。校验三个组件版本、签名、entitlements、加密声明、九语编译资源及测试夹具未混入；Safari 未完成扩展不得入包。
- 仅用仓库 `scripts/AppStoreExportOptions.plist` 和 Xcode 官方 `-exportArchive` 上传。归档固定后不改包，记录实际 IPA/归档摘要。
- 等精确 Build 达到 **`VALID / APP_STORE_ELIGIBLE`**。上传成功但暂不可见时等待同一 Build，不重复上传。可读的 upload receipt 作为补充，不为不可用的列表接口反复绕路。

## 4. 等待 Apple 时完成资料差异检查

- 可并行完成 29 个商店 locale 的 What's New、改变字段校验、受影响 UI/截图检查；同一模拟器或同一 ASC 对象的写入串行。
- 创建/恢复版本，继承当前资料。默认只改本版 What's New；功能说明确需更新时只改对应字段。标题/副标题默认保留，空推广文字合法。
- 元数据拒审须检索 **29 个商店 locale 全部当前字段**（名称、副标题、描述、关键词、推广文字、更新说明）及审核备注中的同类问题，不能只验证审核意见点名的单个字段。2.3.10 修复后用 `scripts/audit-app-store-copy.py` 检查本版文案及实际 pending ASC 回读；旧模板/历史报告不作为当前文案。Google Play 名称及其链接不得重新写回当前 iOS 商店说明。保持功能实现和法律声明不变。
- 未变化且有效的截图保留；不为每次送审重做全套九语截图。仅对本次需要替换的图检查原始 UI、语言、顺序和 `COMPLETE`。不得恢复已删除的旧付费图（“Try Pro Free for 7 Days”、$4.99/$34.99）。
- 回读 29 locale、截图及回退、审核资料、链接、准确 Build 和发布方式。金额、订阅、地区、隐私、年龄及法律声明保持原样，除非本次明确要求改变。

### ASO 本地化门禁（2026-10-11）

- 名称、副标题、关键词以 `docs/aso/search-localizations.json` 为当前目标；`approved-keywords.json` 是兼容镜像，必须一致。目标文案不等于已经上线，以实际 ASC 回读为准。
- iOS 的 29 份完整说明以 `docs/aso/ios-description-localizations.json` 为当前目标，逐条包含语言审查说明。首段说明用户收益，随后区分朗读原文与 AI 生成的讲解；保留输入限制、订阅/克隆额度、隐私与 EULA。中文明确国际版 28 种、中国地区服务 9 种语言。此描述源不适用于 Mac。
- 国际版 28 种应用语言对应 27 种可直接填写的商店语言，加既有繁体中文及墨西哥西班牙语，共 29 个 locale。菲律宾语没有独立 ASC 栏位；不得伪造 `fil`，需记录菲律宾市场英文承接策略。
- `ruby scripts/verify_aso_keywords.rb --catalog-only` 检查语言覆盖、字符/字节限制、本地文字、英文占位及镜像一致性。`ruby scripts/tests/aso_metadata_test.rb` 验证防漏逻辑。
- 发布前后用 `ruby scripts/verify_aso_keywords.rb --platform IOS --version-id <真实ID> --app-info-id <真实ID>` 检查所有分页、29 个 locale 的三个搜索字段和完整说明。Mac 必须显式指定 `--platform MAC_OS`，仅比较三个共享搜索目标字段。新语言缺失、英文占位、未知 locale 或旧模板覆盖完整说明均为失败，不能只告警后放行。
- `audit-app-store-copy.py` 默认为 iOS，Mac 使用 `--platform MAC_OS`。只有检查尚未填写 What's New 的元数据草稿时可加 `--allow-empty-whats-new`；输出会标记 `draftOnly: true`，不能用作发布前检验。完整同步允许推广文本为空，禁止为了通过校验补写无依据的促销文案。
- 只同步已核对的差异，保存原值及回读。不得因名称/关键词锁定而自动撤回其他审核，也不得用旧的 11 语模板覆盖。仅文案修复不构成上传新二进制的授权。
- 每种语言至少保留三条核心/场景查询假设。搜索接口样本不冒充真实商店排名或搜索量；上线后按国家、App Store Search 来源比较展示、下载和转化，区分 Apple Ads、CPP 及其他同时发生的变化。

## 5. 审核门禁、提交、回读

- `release_ops.rb audit` 无阻塞项；核心验收仍匹配最终应用源码、配置及后端线路。
- `submit_review.rb` dry-run 后 execute；恢复同一审核单，不能重复创建，不使用旧 `appStoreVersionSubmissions` 创建接口。
- **版本和 Review Submission 均为 `WAITING_FOR_REVIEW` 或更后状态才算完成。** 报告版本/Build、源码、四格结果、提交时间/ID、发布方式、跳过与非阻塞问题，附完整证据。

## 重测与续跑：只重做失效部分

| 变化/故障 | 处理范围 |
| --- | --- |
| 同源码已经验证，任务中断后继续 | 读取发布记录和精确对象状态，从未完成步骤继续 |
| 修复产品代码 | 失败用例 → 受影响完整套件 → 受影响的核心格；新归档。跨管线依赖变更才重跑所有相关格 |
| 改 TTS/QuickRead/播放器/选择/鉴权/额度或对应后端配置 | 重跑所影响的核心模式、声音类型、地区及切换；无法证明隔离时重跑四格 |
| 仅翻译、商店文案、截图或文档 | 验证相应差异，不重跑全量服务；包内资源有改动需新归档，上传后的二进制改动需更高 Build |
| 已上传后应用代码/版本/构建配置改变 | 更高 Build + 新归档上传；不得修改旧归档冒充同包 |
| 网络临时错误 | 查连通性，恢复后原用例重试；保留失败原因，不删除断言或把失败改成 skip |
| 手机锁定/账号不可用 | 保留已完成证据，先做独立资料工作；核心缺证据仍未通过，不能用模拟器样本代替 |
| Apple 写入结果不明 | 先回读，再恢复已有 version/build/screenshot/submission；不盲重发 |

九语缺键/占位符检查每版一次；UI 大改时九语小屏回归，局部变化仅检查受影响页面和长文本语言。全量 UI 仅在导航/渲染大改或存在未消除风险时扩展，避免把截图采集当成核心播放验收。

## 命令与单份记录

先进入已验证的发布工作树，变量取本次计划的真实值。预检必须显式传工作树与本版文案文件：

```bash
RELEASE_SKILL=/Users/xuxuheng/.codex/skills/submit-castreader-ios-to-app-store
ruby "$RELEASE_SKILL/scripts/release_ops.rb" inspect
ruby scripts/run-release-skill-locales.rb preflight.rb --project "$PWD" \
  --metadata "$RELEASE_METADATA" --whats-new "$RELEASE_WHATS_NEW"
ruby "$RELEASE_SKILL/scripts/release_ops.rb" wait-build --build-number "$RELEASE_BUILD"
ruby "$RELEASE_SKILL/scripts/release_ops.rb" create-version --version "$RELEASE_VERSION"
# 核对 dry-run 后，用同参数追加 --execute 创建/恢复版本。
ruby scripts/run-release-skill-locales.rb release_ops.rb audit \
  --version-id "$RELEASE_VERSION_ID" --build-id "$RELEASE_BUILD_ID" \
  --pending-app-info-id "$RELEASE_APP_INFO_ID" --baseline-app-info-id "$RELEASE_BASELINE_INFO_ID" \
  --title-policy preserve
ruby "$RELEASE_SKILL/scripts/submit_review.rb" 6757636395 "$RELEASE_VERSION_ID"
# 核心门禁与 audit 通过后，用同参数追加 --execute 正式提交。
```

每版一份 `docs/iOS-<version>-Release-Report.md`，一个 `reports/ios-release-<version>/` 证据目录：发布计划/对象 ID、[核心结果](iOS-Core-Service-Release-Gate.md#4-最小证据)、测试摘要、归档校验、ASC audit/提交回执。记录关键结论和实际文件路径，避免多份状态表互相矛盾。凭据不进入日志或仓库。

固定 App ID 和归档命令见发布技能 `references/castreader-app-store-config.md`；旧 helper 的 11-locale 常量已落后于当前范围，使用 `scripts/run-release-skill-locales.rb` 运行 preflight/audit，将范围严格替换为已审查的 29 个 locale，其余检查不变。仅遇对应步骤/失败时查 `references/app-store-runbook.md`。不要重新阅读旧版本全部过程日志。
