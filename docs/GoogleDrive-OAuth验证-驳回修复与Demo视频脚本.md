# Google Drive OAuth 验证 — 驳回修复与 Demo 视频脚本

> Google Cloud 项目：`castreader-drive-ios`
> 申请权限：`https://www.googleapis.com/auth/drive.readonly`（**restricted scope**）
> 最新补件日期：2026-08-23 ｜ 本文档更新：2026-08-24

## 最新明确堵点（2026-08-23）

Google 最新回复只保留一个问题：新视频仍未充分证明
`drive.readonly` 对 CastReader 的**现有核心功能**为何必要，以及为何
`drive.file` 等更窄权限不能完成同一体验。隐私政策 / Limited Use 没有在
这封最新邮件里再次被提出。

本轮不能只重复“选文件后朗读”。最终视频必须把下面这条因果链拍完整：

1. 授权前说明明确写出完整只读权限用于 CastReader 自己的目录浏览与跨文件搜索；
2. Google 同意屏展开后逐字可读，且只出现 `drive.readonly`；
3. 在 CastReader 原生 Drive 浏览器中进入目录、返回、搜索**同一份示例文件**；
4. 导入同一文件后展示朗读词级高亮、自动滚动与解读标注；
5. 回到入口再次打开 Google Drive，直接恢复到 Drive 目录，不重复 OAuth，证明它是持续连接而不是一次性文件挑选器。

## 0. 验证中心当前状态

| 项 | 状态 | 处理 |
|---|---|---|
| 品牌推广指南 | ✅ 通过（08-10） | — |
| 请求最小范围 | ✅ 通过（08-10） | — |
| **隐私权政策要求** | ❌ 驳回（08-12） | **已修复并上线**，见 §1 |
| **应用功能** | ❌ 驳回（08-12） | 原文：「您的演示视频未充分展示应用的功能。」按 §2 重录 |
| 首页要求 | ⚪ 未审 | 已自查通过，见 §3 |
| 其他要求 | ⚪ 未审 | 见 §3 |

## 1. 隐私权政策（已修复）

**驳回原文**：「您的隐私权政策表明，应用会出于除提供或改进应用功能以外的原因而使用 Google 用户数据。」

**根因**：`castreader.com/privacy-policy` 全文没有任何 Google 用户数据专章，而通用条款里写了审核员判定为超范围的用途：

- §2.2「measure product funnels / 衡量产品漏斗」
- §4「prevent fraud or misuse」「enforce our Terms of Service」
- §5「service providers for ... analytics, speech, and model processing」
- §2.3 正文发往 `api.castreader.ai` 与模型服务，但**未声明不用于训练模型**（Workspace/Drive 数据的硬性禁止项）

**修复**（commit `6e816db`，en + zh 同步，已部署）：

新增 **§2.6 Google Drive Data (Limited Use)**，逐条对应 Limited Use 四要求：

1. 只用于用户明确请求的浏览、导入、朗读、高亮、解读功能；
2. 不用于广告 / 再营销 / 定向广告；
3. **不用于开发、改进或训练通用（非个性化）AI 或 ML 模型**；
4. 不出售，不进入产品分析、漏斗衡量、增长指标、营销或画像；
5. 传输仅限提供所请求功能所必需（该文档的文字发往语音与解读处理方，处理方受合同约束不得用于训练自有模型）、遵守法律、或经明确事先同意的并购；
6. 人工不读取，除非用户为自己发起的支持请求明确同意、安全目的、或法律要求；
7. 只读，绝不创建/修改/重命名/移动/删除/上传，不做后台同步或索引；
8. 服务器不存原始文件字节，文库只存引用（账号 + 文件 ID + 版本）；
9. 可在 App 内解绑或在 myaccount.google.com/permissions 撤销。

并在 §2.2 / §4 / §5 三处加 Google 数据例外，明确 **§2.6 优先于通用条款**；§1 补云盘来源，§6 补 token 保留，§7 补撤销入口。

回信时给审核员的定位链接：
`https://castreader.com/privacy-policy`（章节 2.6）

## 2. 应用功能 — Demo 视频重录脚本

**驳回原文**：「您的应用未满足"应用功能要求"要求。请解决以下问题：**您的演示视频未充分展示应用的功能。**更新您的演示视频，以充分展示应用的功能。」

这条只有一句话，没有更细的指引。Google 用这句话时，实际指的几乎总是这三件事之一没拍到：

1. **只拍了授权，没拍到授权之后拿这些数据做了什么** —— 视频到 OAuth 同意屏或"连接成功"就结束了；
2. **没有证明为什么非要这个 scope** —— 拍了"打开一个文件"，但那用 `drive.file` 就能做到，审核员看不出 `drive.readonly` 的必要性；
3. **没拍到应用的核心功能本身** —— 只演示了导入，没演示 CastReader 实际拿这份文档做什么（朗读、词级高亮、解读）。

下面的脚本三条全覆盖。

### 2.1 硬性要求

- **生产环境**：必须用 Google Drive 正式 iOS client ID（`940934097271-...`）跑，不能误用登录模块的 `338957209183-...` client，也不能是 test/staging 或模拟器假流程。
- **一镜到底**：不剪辑、不加速、不跳切。审核员要看到连续的因果链。
- **必须拍到 OAuth 同意屏全文**：应用名 "CastReader"、权限描述 "See and download all your Google Drive files"、以及底部的开发者信息。同意屏停留 ≥ 3 秒，别一闪而过。
- **公开可访问**：YouTube「不公开列出（unlisted）」即可，Google 明确接受；但不能是"私享"。
- **语言**：英文旁白或英文字幕。中文界面可以，但要有英文字幕说明每一步。
- **时长**：3–5 分钟。

### 2.2 逐镜脚本（最终版，4:20–4:50）

| # | 画面 | 旁白 / 字幕（英文） | 要点 |
|---|---|---|---|
| 1 | 真机打开 CastReader → ➕ → Google Drive | "CastReader is a productivity and education app that reads and explains documents." | 直接进入审核相关功能，不浪费时长 |
| 2 | **授权前披露页停留 8 秒**，完整显示 “Why full read-only access is needed” | "Full read-only access powers CastReader's own persistent folder browser and cross-file search. CastReader never writes to Drive or scans it in the background." | 新增的最小权限论证必须可读 |
| 3 | 点 Continue → 选择 `vinxu` 测试账号 → 处理未验证警告 | "This is the production iOS OAuth client for project castreader-drive-ios." | 真机 + 正式 client ID |
| 4 | **展开 Google 同意屏权限，停留至少 8 秒**，完整显示 "See and download all your Google Drive files" | "The consent screen shows the one requested scope: drive.readonly." | **最关键证据**；必须可暂停逐字读清 |
| 5 | 授权完成 → CastReader 原生 Drive 目录 → 进入 `Shared with me` → 返回 | "Users navigate accessible Drive locations inside CastReader before selecting a document." | 证明不是本地文件入口，也不是 Google 网页版 Picker |
| 6 | 在 CastReader 原生搜索框搜 `CastReader OAuth Demo Reading Sample` | "The same native connection searches across accessible Drive files." | 目录导航 + 搜索同时出现 |
| 7 | 打开搜索到的同一示例文件 → 下载 / 本机解析 → 阅读器 | "Only the selected document is downloaded to this device and parsed locally." | 同一文件闭环 |
| 8 | 点朗读，展示词级高亮和自动滚动 25–35 秒 | "The document is read aloud with word-level highlighting and automatic scrolling." | 证明 Drive 数据服务于核心 TTS 功能 |
| 9 | 切换解读，展示讲解与原文手写标注 45–70 秒 | "Explain narrates an AI-assisted explanation and animates annotations on the source text." | 证明第二个核心功能 |
| 10 | 退出阅读器 → 再次点 Google Drive，**直接进入原生目录，不再出现 OAuth** | "On the second open, the stored refresh-token grant restores the same Drive browser without asking the user to authorize again." | 证明 Speechify 式一次授权、持续连接 |

### 2.3 录完自查

- [ ] 同意屏那一镜能否**暂停截图后读清每一个字**？（审核员就是这么看的）
- [ ] 是否在 **CastReader 自己的原生 Drive 界面**里同时演示目录导航和跨文件搜索？
- [ ] 目录浏览、搜索、导入是否使用同一份示例文件，形成连续证据链？
- [ ] 最后是否再次打开 Google Drive，并且直接进入目录、没有重复授权？
- [ ] 全程是否为真机？模拟器的状态栏（9:41、满格信号）容易被识别。
- [ ] 视频里是否**不含**任何真实个人隐私（邮箱全名、私人文件名）？建议用测试 Google 账号，Drive 里放几个公开示例 PDF。
- [ ] 英文说明是否已经**烧录进画面**，而不是只依赖 YouTube CC？

## 2.4 回复 Trust & Safety 的邮件正文（直接复制）

> Google 不会自动重扫，**必须回到原邮件会话串**回复，否则一直挂着。
> 视频录完拿到链接后，把 `<YOUR_VIDEO_URL>` 替换掉再发。

```text
Subject: Re: [Your existing thread subject] — CastReader (project: castreader-drive-ios)

Hello,

Thank you for the review. We have addressed both items raised on August 12.

1) Privacy policy requirements

Our privacy policy has been updated and is live at:
https://castreader.com/privacy-policy

We added a dedicated section — "2.6 Google Drive Data (Limited Use)" — which
states explicitly that our use and transfer of information received from Google
APIs adheres to the Google API Services User Data Policy, including the Limited
Use requirements. Specifically, data obtained through Google APIs is:

- used only to provide the user-facing browsing, import, read-aloud, and
  explanation features the user explicitly requests;
- never used for advertising, retargeting, or personalized ads;
- never used to develop, improve, or train generalized or non-personalized
  AI/ML models;
- never sold, and never included in product analytics, funnel measurement,
  growth metrics, marketing, or profiling;
- transferred only as necessary to deliver the requested feature, to comply
  with law, or in a merger after explicit prior consent;
- not read by humans, except with the user's explicit consent for a support
  request they initiate, for security purposes, or where required by law.

We also added explicit carve-outs in sections 2.2 (analytics), 4 (how we use
data), and 5 (service providers) stating that Google API data is excluded from
those general-purpose uses, and that section 2.6 takes precedence wherever the
two differ. A Chinese translation with identical terms is at
https://castreader.com/zh/privacy-policy

2) App functionality

We have recorded a new demonstration video using the production OAuth client:
<YOUR_VIDEO_URL>

The video shows, in one continuous real-device take: the in-app disclosure
presented before authorization, the fully expanded OAuth consent screen for the
single requested scope (https://www.googleapis.com/auth/drive.readonly), and the
resulting production functionality. It uses the same sample document to show
folder navigation, cross-file search in CastReader's native Drive browser,
on-device import, read-aloud with word-level highlighting and auto-scroll, and
AI-assisted explanation with animated source annotations. It then opens Google
Drive a second time and goes directly back to the native Drive browser without
another authorization prompt.

Regarding scope minimization: drive.readonly is required for CastReader's
prominent, user-facing persistent Drive connection. Users browse accessible
folders and search across accessible files in CastReader's own native browser,
then reopen that same connection later without repeating OAuth. The narrower
drive.file scope grants access only to files individually selected or created
for the app. When paired with Google Picker it can hand one user-selected file
to an app, but it cannot authorize CastReader's own persistent native directory
and cross-file search over the user's accessible Drive. We request read-only
access only; CastReader never creates, modifies, moves, or deletes any Drive
file, performs no background synchronization, scanning, or indexing, and does
not store original Drive file bytes on our servers.

Please let us know if any further information would help.

Best regards,
[Your name]
CastReader / Enid Ltd
```

## 3. 首页要求 / 其他要求（自查）

| Google 要求 | 现状 | 结论 |
|---|---|---|
| 首页可公开访问且与 OAuth 一致 | `https://castreader.com` 正常 | ✅ |
| 首页有指向隐私政策的可见链接 | 全站 footer `agreement.items` 含 Privacy Policy | ✅ |
| 隐私政策与首页同域 | 都在 `castreader.com` | ✅ |
| 首页说明应用做什么 | landing 页说明朗读/解读 | ✅ |
| 域名所有权已验证 | 品牌验证已通过（08-10） | ✅ |
| 隐私政策可公开访问、无需登录 | 是 | ✅ |
| App 内有授权前披露 | `CloudPrivacyDisclosureView` | ✅ |

## 4. 通过之后还有一步

`drive.readonly` 是 restricted scope，验证通过后还需 **CASA Tier 2 第三方安全评估**，且**每年复审**。提前预算与排期，别等 Google 发邮件催。

## 5. 相关代码与文档

- 客户端：`CastReader/Services/GoogleDriveProvider.swift`（scope 常量在 `Configuration`，授权在 `browserConnection` 路径）
- 授权前披露：`CastReader/Views/CloudStorage/CloudStorageViews.swift` → `CloudPrivacyDisclosureView`
- 隐私政策源码：`castreader-content` 仓库 `content/pages/privacy-policy{,.zh}.mdx`
- 原始规划（注意：其中"首版不申请 restricted scope"的结论已被推翻）：`docs/GoogleDrive-Dropbox-OneDrive-云盘接入规划.md`
