# CastReader Android 云盘接入对齐交接

> 范围：Google Drive、Dropbox、Microsoft OneDrive
> 目标：Android 与已经完成本地验收的 iOS 版本保持产品行为、权限、隐私、安全和阅读体验一致
> 日期：2026-08-10
> iOS 详细规划：`docs/GoogleDrive-Dropbox-OneDrive-云盘接入规划.md`

## 1. 交接结论

Android 要实现的是“三家云盘作为新的文件来源”，不是新的阅读器，也不是新的上传通道：

```text
云盘授权/选取
    → 设备私有临时文件
    → 严格格式识别和资源限制
    → Android 现有 PDF / DOCX / EPUB 本地阅读路径
    → 现有朗读 / 解读 / 播放器 / 词级高亮 / 自动滚动 / 配额
```

以下边界不可变：

1. 只支持 PDF、DOCX、EPUB；不支持 `.doc`，也不把未知文件当 PDF 尝试。
2. 云盘原始文件字节不得进入 CastReader 的 `/sts`、COS、`/upload`、`/async-md-upload-by-url` 或 URL 转存接口。
3. 下载文件只保存在应用私有、排除系统备份的短期目录；打开或失败后按生命周期清理，不建立隐式永久离线副本。
4. 用户主动开始朗读或解读后，本机抽取出的必要文本仍按现有 TTS / QuickRead 数据流发送。授权前必须准确披露，不能宣称“完全离线”或“所有内容永不上服务器”。
5. 云盘进入阅读器后不另建播放器、朗读、解读、高亮或额度实现；必须复用现有链路。
6. 三家都只读；不申请写、删、移、改名或上传权限。
7. 每家首版只保留一个 active account，云盘账号与 CastReader 登录账号完全隔离。

## 2. Android 当前落点与先决重构

Android 仓库：`/Users/xuxuheng/Documents/CastReader-Android`

已经存在的主要复用点：

- 加号面板：`app/src/main/java/com/same/castreader/ui/screens/import_feature/ImportBottomSheet.kt`
- 当前本地文件入口：`app/src/main/java/com/same/castreader/ui/screens/import_feature/ImportViewModel.kt` 的 `openLocalFile`
- 根级弹层和导航：`app/src/main/java/com/same/castreader/MainActivity.kt`
- 阅读导航：`app/src/main/java/com/same/castreader/ui/navigation/CastReaderNavHost.kt`
- 阅读会话：`app/src/main/java/com/same/castreader/reader/DocSession.kt`
- PDF：`app/src/main/java/com/same/castreader/pdf/PdfNativeEngine.kt` 与 `ui/screens/pdfreader/`
- EPUB：`app/src/main/java/com/same/castreader/epub/EpubNativeEngine.kt` 与 `ui/screens/epubreader/`
- DOCX：现有 `ui/screens/webreader/` 路径
- 播放会话：`app/src/main/java/com/same/castreader/player/manager/PlayerCoordinator.kt`
- 本地历史：`app/src/main/java/com/same/castreader/data/local/HistoryStore.kt`、`ui/screens/library/`
- 分享文件入口：`app/src/main/java/com/same/castreader/share/ShareIntentImporter.kt`、`ShareInboxStore.kt`
- 现存但云盘严禁调用的上传路径：`upload/COSUploader.kt`、`data/remote/CastReaderApi.kt` 的 STS，以及 `ReaderServiceApi` 的上传接口。

实施前要先统一 Android 的本地导入：当前 `openLocalFile` 一次性 `readBytes()`，并且未知扩展会走 `setPdf`，不适合承接不可信远程文件。应抽出统一、可测试的 `DocumentImportPipeline`，至少让本地 picker、分享入口和三家云盘共享这些能力：

- 文件名、声明 MIME、魔数和容器内容交叉识别；扩展名不能作为唯一依据。
- PDF / DOCX / EPUB 严格白名单，拒绝伪装、截断、密码/DRM/IRM、损坏和不支持文件。
- 流式复制而非无界 `readBytes()`；支持进度、取消、大小上限、磁盘空间预检和临时文件清理。
- DOCX / EPUB ZIP 的条目数量、单条展开量、总展开量和压缩比上限，防 ZIP bomb/path traversal。
- 解析成功后只设置一次 `DocSession` 并导航一次；取消、解绑、换号或较新的导入发生后，旧任务不得覆盖会话或打开阅读器。
- 路由继续为 PDF → `PdfReader`、EPUB → `EpubReader`、DOCX → 当前 DOCX/Web reader。

云盘固定使用“禁止上传 fallback”的策略。不要把云盘实现放进仍注入 `COSUploader` 的旧 upload 方法，也不要以“上传成功后再复用文库”绕过本地阅读。

还有一个必须在接线前解决的隐私缺口：`PdfReaderViewModel`、`EpubReaderViewModel` 和 `WebViewReaderViewModel` 当前会把 `DocSession` 中的完整 bytes 交给 `HistoryStore` 持久化。云盘若直接调用现有 `setPdf/setDocx/setEpub`，即使下载目录随后删除，原文件仍会被复制到 `filesDir/history/*.payload`。因此 `DocSession` 必须携带 `origin`、`persistencePolicy`、`stableDocumentId`、`contentSessionKey` 和 remote reference；三个 reader 的历史写入都必须按策略分支，云盘记录不得写 payload 或内容封面。`ImportViewModel` 里已经不再使用的 `CastReaderApi`、`ReaderServiceApi`、`COSUploader` 注入也应删除，使 no-upload 边界可以被静态验证。

## 3. 建议的 Android 领域结构

名称可以按现有工程风格调整，但职责要保持分离：

```text
cloud/
  model/
    CloudProvider, CloudAccount, CloudItem, CloudRemoteReference
    CloudFormat, CloudRevision, CloudError, CloudImportStage
  auth/
    CloudCredentialStore / provider SDK cache adapters
  provider/
    CloudStorageProvider
    GoogleDriveProvider
    DropboxProvider
    OneDriveProvider
  data/
    CloudConnectionStore
    CloudStorageCenter
    CloudHistoryReopenService
  import/
    CloudImportCoordinator
    DocumentImportPipeline
  ui/
    CloudStorageFlowViewModel
    provider rows / disclosure / browser / progress / errors
```

`CloudStorageProvider` 应给上层统一语义，而不抹平 provider 差异：

- `connect` / `reauthorize` / `switchAccount` / `disconnect`
- Google 的 `authorizeAndPick` 原子流程
- Dropbox / OneDrive 的 `listFolder` / `search` / pagination
- `metadata` / `download` / 可选导出
- active account、credential generation、connection epoch

所有 provider client、下载器、连接存储、时钟和文件系统都要可注入，以便用 fake server / MockWebServer 做确定性测试。

## 4. 入口与交互契约

### 4.1 加号面板

在当前导入项下增加独立“云端文件”区域，始终显示三行：

- Google Drive
- Dropbox
- Microsoft OneDrive

每行支持：

- 未连接
- 已连接（脱敏账号或显示名）
- 正在连接/刷新
- 需要重新连接
- 未配置（生产配置缺失时安全禁用，不崩溃、不伪装可用）

已连接行提供菜单：更换账号、解除关联、查看隐私说明。解除关联要确认；可另提供“同时删除本机云盘阅读记录”，默认只清连接、不隐式删除历史。

### 4.2 首次披露

OAuth 前必须展示 provider 对应的说明，覆盖：

- 申请的只读权限；
- 用户选择的原文件只下载到此设备，不上传到 CastReader 文件存储接口；
- 开始朗读/解读时，本机抽取的必要文本会发送给现有 TTS / QuickRead 服务；
- 本机会保存脱敏账号信息、授权状态、远程文件引用和版本元数据；
- 解除关联会停止本机访问，但 provider 端撤销失败时不能谎称远程授权已撤销。

用户取消 OAuth / Picker 是正常取消，回到加号面板，不弹错误；配置、网络、策略、权限或服务错误才显示可操作的错误状态。

### 4.3 浏览和导入

- Google 使用官方移动 Picker，不画应用内整个 Drive 文件树。
- Dropbox / OneDrive 使用原生 Compose 文件浏览器：文件夹优先、返回栈、分页、搜索防抖、按稳定 ID 去重、滚动位置保持。
- 不支持项禁用并解释；首版单选。
- 导入进度统一为：获取信息 → 下载 → 检查 → 解析 PDF/Word/EPUB → 准备阅读器。
- 每个阶段都可取消，且取消必须传播到 HTTP body、文件写入、ZIP 检查、解析/OCR 和最终导航。

## 5. Provider 契约

### 5.1 Google Drive

权限和体验：

- 唯一 scope：`https://www.googleapis.com/auth/drive.file`。
- Authorization Code + PKCE；每次新 verifier/state；`prompt=consent`。
- 授权与官方 Picker 选文件是一轮原子操作，建模为 `authorizeAndPick()`；不要先展示虚假的通用“连接完成”再启动第二轮选择。
- 单选，只允许 PDF、DOCX、EPUB 和 Google Docs。
- Google Docs 默认导出 DOCX；同步 `files.export` 有 10 MiB 响应上限，超限要明确提示。
- Picker 返回 ID 后读取最小 metadata、下载能力、版本、修改时间、driveId、resourceKey；Shared drives 请求和 resource key 要正确传播。
- 首版不申请 restricted `drive.readonly`。若 Android 官方 Picker 能力或 API 状态与 iOS 不同，必须查阅当前 Google 官方 Android/OAuth/Picker 文档并以同样的最小权限目标设计，不能静默扩大为全盘读取。
- Drive OAuth client/project 必须与 CastReader Google 登录隔离，避免撤销 Drive 授权连带影响登录。

### 5.2 Dropbox

- 使用当前受维护的官方 Android SDK / OAuth PKCE 能力，依官方文档锁定版本。
- App 类型为 Full Dropbox；App Folder 不能满足浏览用户已有文件的目标。
- scopes：`account_info.read`、`files.metadata.read`、`files.content.read`。
- `listFolder` / continue 分页；`searchV2` / continue 搜索；结果按 `FileMetadata.id` 去重。
- 远程主键用 file ID，版本用 `rev`，不能把可变路径当主键。
- Team Space 使用 root namespace/path root；`invalid_root` 时刷新 root、丢弃旧 cursor、仅重试一次。
- `isDownloadable` 为真才直接下载；cloud-only 文档只有 `exportInfo` 明确支持 PDF/DOCX 才可导出。
- 多账号缓存中显式保存 active token UID。新授权先成为 candidate，用户确认后再提交；取消时只清 candidate。
- 解绑先使本机 association 立即失效，再 best-effort `tokenRevoke`；远程失败要诚实提示并进入有界补偿队列。

### 5.3 Microsoft OneDrive

- 使用当前受维护的官方 MSAL Android SDK处理 token cache、交互登录和 silent refresh；Graph 使用可测试的 HTTP client。
- delegated scope 只有 `Files.Read`；不申请 `Files.ReadWrite`、`Files.Read.All`，也不为头像额外加 `User.Read`。
- Entra app 支持组织账号和个人 Microsoft 账号；public client，不内置 client secret。
- 列根目录/子目录并完整消费 `@odata.nextLink`；nextLink 必须为 HTTPS 且 host 属于 Microsoft Graph 允许列表，不能手工拆改 skip token。
- 下载只接受真正的 `file` facet；folder/package 不按扩展名误判。`remoteItem` 使用目标 `driveId + itemId`。
- 下载接口可能 302 到短时预授权 URL。跨 host 后绝不能带 Graph `Authorization` header，预授权 URL 不持久化、不写日志。
- metadata 显式选择 `cTag,eTag`，内容版本优先 `cTag ?: eTag`；远程主键包含 `driveId + itemId`。
- `/me/drives` 仅标为账号可用 drives，不能宣称是完整 SharePoint/Teams 库发现器。
- 换号必须强制交互选账号；本机 MSAL sign-out 不等于全局微软授权撤销，产品文案要准确。

## 6. 凭据、账号切换和并发安全

### 6.1 凭据

- provider token 不得写入普通 SharedPreferences/DataStore、历史 JSON、日志、analytics、crash breadcrumb 或 CastReader 后端。
- 优先使用官方 SDK 的加密 token cache；自有秘密使用 Android Keystore 支持的加密存储。
- 持久化 UI 所需的 provider、脱敏显示、稳定本地 account key、credential generation 和连接状态；稳定 account key 应是本机伪匿名哈希，不是邮箱，不得上传 analytics。

### 6.2 两阶段换号

换号必须是事务：

```text
active A
  → 登录 candidate B
  → 展示 A → B 确认
  → 用户确认后原子提交 B 并递增 epoch
  → 再清理/撤销 A
```

取消、进程死亡或恢复失败不得把 B 静默变成 active，也不得先删 A 导致用户掉线。启动时要恢复或清理未完成事务。

### 6.3 epoch / generation / latest-wins

每个连接维护 epoch，每份凭据维护 generation，每次导入有 operation ID：

- disconnect 即刻递增 epoch、取消关联任务、清本机 active 状态；远程 revoke 失败不阻止本机断开。
- OAuth callback、silent refresh、列表、搜索、下载、解析和导航提交前都校验 provider + account key + epoch + credential generation + operation ID。
- 较旧 callback、取消后的下载、旧搜索页、旧 parser 结果不得回写 active account、历史或 `DocSession`。
- 401 最多 silent refresh 后重试一次；429 尊重 `Retry-After`；只自动重试幂等请求。
- Google 撤销补偿任务要绑定具体 account + credential generation，绝不能撤销后来绑定的新 token。

## 7. 下载、格式和资源限制

按最终有效格式执行上限：

| 格式 | 最大文件大小 |
|---|---:|
| PDF | 200 MiB |
| DOCX | 40 MiB |
| EPUB | 120 MiB |

要求：

- metadata 的 size 只用于提前拒绝；真实响应字节数和最终文件长度仍要硬限制。
- 未提供 size、chunked、错误 Content-Length 或导出后格式变化都不能绕过上限。
- 落盘前检查可用空间，并保留安全余量；下载中超限立刻取消并删临时文件。
- 使用应用私有 cache/no-backup 目录，文件权限最小化；成功打开后也要有明确清理策略。
- 文件名经过净化，不作为真实路径；临时文件使用随机 ID。
- MIME、扩展、魔数和 ZIP 内标志联合判断。DOCX 需要正确 OOXML 结构；EPUB 需要 `mimetype` / container / OPF；PDF 需要有效 `%PDF-` 与解析成功。
- ZIP 条目拒绝绝对路径、`..`、符号链接逃逸；限制条目数、单条/总展开字节和压缩比。
- 异常、取消、进程恢复、解析失败、导航失败均不得残留孤儿原文件。

## 8. 历史和重开语义

云盘历史只保存远程引用，不保存原始 payload 或从正文生成的封面：

- provider
- stable remote item ID（OneDrive 为 driveId + itemId）
- stable local account key
- revision/eTag/cTag/version/modifiedTime 等 provider 版本
- 最终格式、标题、必要的 drive/resource key
- createdAt / lastOpenedAt 等现有基础字段

不要把 OAuth token、预授权 URL、完整路径、原文件字节或正文摘要写进历史。

重开顺序：

1. 验证连接的是同一 account key；否则提示连接原账号。
2. 读取最新 metadata；文件删除或权限收回时提供“从历史移除”。
3. 重新下载最新版，并重新走统一 `DocumentImportPipeline`。
4. revision 或最终格式变化时，建立新的 content session identity，清空旧阅读器/播放器的易失状态，不能把旧高亮/段落状态套给新版本。

修改 `HistoryRecord` 时保持旧 JSON 可解码：新字段全部有默认值/可选值，写 migration/legacy fixture 测试。现有本地历史继续保存自己的 payload；“远程引用、不保存原件”只针对新的云盘 source kind。

## 9. 错误恢复与诚实文案

错误要映射为用户可操作状态：

- 未配置：联系开发配置/当前版本不可用；不可发起半套 OAuth。
- 用户取消：静默返回。
- token 过期/401：自动刷新一次，仍失败则“重新连接”。
- 权限不足/管理员策略：说明账号或组织策略限制，可换号。
- 404/已删除：允许从历史移除。
- 429：显示稍后重试并尊重 server retry time。
- 网络中断：保留安全的重试入口，不复用过期预授权 URL。
- 文件过大、格式伪装、损坏、加密/DRM、空间不足：在本机明确解释，不进入上传 fallback。
- 远程撤销失败：只说“已从此设备断开；服务商端授权可能仍存在”，并提供 provider 管理授权链接或重试。

任何错误都不能打印 token、Authorization header、code verifier、OAuth code、resource key 或预授权下载 URL。

## 10. 本地化、无障碍和品牌

- 覆盖 Android 当前正式支持的全部语言；iOS 已覆盖 `de/en/es/fr/hi/it/ja/pt-BR/zh-Hans`，Android 至少不能少于自身已发布语言集合。
- 深色模式、系统动态颜色、200% 字体缩放/最大可用 font scale 下入口、披露、浏览器、进度和错误页可操作且可滚动。
- TalkBack 顺序、按钮 role、进度语义、文件/文件夹状态、禁用原因、账号脱敏文本要可读。
- provider 图标按官方品牌规范使用；依赖的 LICENSE/NOTICE 与 privacy manifest/data safety 资料进入仓库和发布产物。
- 分析事件只记录 provider、格式、阶段、成功/错误类别、时长/大小桶；不记录账号、文件名、路径、file ID、搜索词、正文或 token。

## 11. iOS 可直接参考的实现和测试

产品/实现：

- `CastReader/Models/CloudStorageModels.swift`
- `CastReader/Services/CloudStorageProvider.swift`
- `CastReader/Services/CloudStorageCenter.swift`
- `CastReader/Services/CloudConnectionStore.swift`
- `CastReader/Services/CloudHistoryReopenService.swift`
- `CastReader/Services/CloudImportCoordinator.swift`
- `CastReader/Services/GoogleDriveProvider.swift`
- `CastReader/Services/DropboxProvider.swift`
- `CastReader/Services/OneDriveProvider.swift`
- `CastReader/Utils/DocumentImportPipeline.swift`
- `CastReader/ViewModels/CloudStorageFlowViewModel.swift`
- `CastReader/Views/CloudStorage/CloudStorageViews.swift`
- `CastReader/CloudStorage.xcstrings`
- `CastReader/Utils/Constants.swift`

测试：

- `CastReaderTests/CloudStorageCoreTests.swift`
- `CastReaderTests/GoogleDriveProviderTests.swift`
- `CastReaderTests/DropboxProviderTests.swift`
- `CastReaderTests/OneDriveProviderTests.swift`
- `CastReaderTests/CloudImportIntegrationTests.swift`
- `CastReaderTests/CloudHistoryTests.swift`
- `CastReaderTests/CloudHistoryReopenServiceTests.swift`
- `CastReaderUITests/CastReaderUITests.swift` 的 `testCloudProvidersAndPrivacyDisclosureAppearInPlusFlow`

不要逐行翻译 Swift 或照搬 iOS SDK。Android 实施前需重新核对三家当前官方 Android 文档、OAuth redirect/app-link 要求、SDK 支持状态、Play Data safety 和许可证，并记录所采用版本与理由；但权限和上述产品边界不得扩大。

## 12. iOS 实施经验和高风险坑

1. 最危险的失败不是“下载失败”，而是取消/解绑/换号之后旧 callback 仍成功并打开文件。所有异步边界都要做 latest-wins 校验。
2. “先清旧账号，再登录新账号”会在用户取消时把可用连接毁掉，必须 candidate 两阶段提交。
3. 只按扩展名路由会把 HTML 错误页、OAuth 登录页或伪装 ZIP 当文档，必须 sniff + container validate。
4. 只信 Content-Length 会被 chunked、导出和错误 metadata 绕过，必须边流式写边计数。
5. provider 的下载 URL 不等于普通公开 URL；OneDrive 跨 host redirect 的 Auth header 泄漏是高危项。
6. Google 的最低权限体验天然不同：`drive.file` 对应官方 Picker，不能为了 UI 统一改成 restricted 全盘 scope。
7. “解除关联”有两个层次：本机立即失效与 provider 远程撤销。后者失败时不能回滚本机断开，也不能宣称成功。
8. 云盘历史若保存 payload/封面，会违背“不永久保存原文件”的产品承诺；远程历史和本地历史必须区分策略。
9. 格式导出后要按实际格式重新套大小和解析限制，不能继续用云端原始类型。
10. SDK token cache 多账号选择不能依赖“第一个账号”；必须显式 active account ID。
11. `@odata.nextLink`、Dropbox cursor 和 Google resource key 都是服务端不透明值；验证边界后原样消费，不自行拼接或记录日志。
12. 隐私文案必须精确区分“原始文件不上传”和“朗读/解读文本会发送”，避免用无法证明的训练、保留期限、服务器地区或人工访问承诺。

## 13. 强制测试与完成定义

Android agent 只有在以下证据全部具备后才能报告客户端完成：

### 13.1 单元/契约测试

- provider 列表、搜索、分页、去重、metadata、下载/导出、scope 和错误映射。
- PKCE/state/callback、silent refresh、401 单次 retry、429 Retry-After。
- 两阶段换号、进程恢复、disconnect epoch、credential generation、晚到 callback/download/parser。
- 格式 sniff、大小边界（`limit-1/limit/limit+1`）、缺失/错误 Content-Length、空间不足、ZIP bomb/path traversal、损坏/加密文件。
- history legacy migration、remote reference、同账号验证、删除/撤权、新 revision 会话更新。
- MockWebServer/网络拦截断言：云盘路径对 `/sts`、COS、`/upload`、`/async-md-upload-by-url` 请求计数恒为 0。
- 日志脱敏和 analytics payload 契约。

### 13.2 集成/界面测试

- 加号面板三行、所有连接状态、首次披露、取消、菜单、解绑、换号。
- Dropbox/OneDrive 目录/搜索/分页；Google authorize-and-pick callback。
- PDF、DOCX、EPUB 各自从 fake provider 下载后进入正确 reader，并能启动现有朗读和解读；验证播放器、高亮和自动滚动没有分叉实现。
- 下载/校验/解析阶段取消后不导航、不留文件、不写历史。
- 历史重开、错误恢复和新版本刷新。
- 浅色、深色、最大字体缩放、TalkBack；至少覆盖所有正式语言的 resource completeness。

### 13.3 工程验证

在当前可用环境中至少执行并自修复到通过：

```bash
./gradlew test
./gradlew lint
./gradlew assembleDebug
./gradlew assembleRelease
./gradlew connectedAndroidTest
```

工程有 Global/CN flavor 时，发布证据还应展开到实际 variant，而不是只依赖聚合任务：

```bash
./gradlew testGlobalDebugUnitTest testCnDebugUnitTest
./gradlew lintGlobalDebug lintCnDebug
./gradlew assembleGlobalDebug assembleCnDebug
./gradlew assembleGlobalRelease assembleCnRelease
./gradlew connectedGlobalDebugAndroidTest
```

安装到可用模拟器/设备，执行真实 UI smoke；记录 APK 构建、安装、启动、关键流程和测试数量。若环境没有正式 OAuth 配置，使用 fake provider、MockWebServer 和 provider SDK 可测试接口完成客户端验收，真实账号流程只能列为发布前门槛，不能伪造“已实测”。

### 13.4 发布前外部门槛

这些不是客户端 agent 可以编造完成的事项，但必须安全降级并形成清单：

- Google Cloud Android OAuth client / redirect / signing certificate 与 production consent 配置。
- Dropbox App Console 正式 app、scopes、redirect 和 production approval/放量。
- Microsoft Entra Android redirect signature/hash、账号类型、publisher/tenant 验证。
- 公开隐私政策、Google Play Data safety 和三家授权披露更新。
- 正式测试账号 + 真机矩阵的授权、取消、换号、解绑、过期、管理员策略、共享项和大文件 E2E。

正式配置缺失时，三家入口仍展示为“未配置”并安全禁用；不得塞入测试 secret，不得提交 client secret、keystore 密码、token 或个人账号数据。

## 14. iOS 验收基线

Android 的验收深度应至少达到 iOS 当前基线：

- 云盘核心/provider/历史/no-upload 契约：124/124 通过。
- 云盘集成及相关阅读回归：73/73 通过。
- 非支付 App 测试：659 通过、1 条件跳过、0 失败。
- 云盘 UI 浅色与深色+辅助功能超大字号均通过。
- Debug/Release 构建、安装和启动通过。
- 九语资源、plist/entitlements、依赖许可和工程注册静态检查通过。

Android 不需要复制这些数字，但需要覆盖同样的风险面并给出自己的可复现命令、通过数、跳过/失败原因和产物路径。

## 15. 自主推进要求

目标 Android agent 应直接开始实施，不等待用户中途确认。遇到普通技术选择，以最小权限、设备端处理、可测试和与现有架构一致为准自行决策；持续编译、测试、故障注入、UI 检查和修复，直到所有客户端范围完成且没有已知功能问题。

只有确实需要外部开发者后台权限、正式账号、法务文本或发布授权的事项可以列为外部 gate；这些 gate 不应阻止完成 fake-provider 支撑的全部客户端代码和自动化验收。最终回报必须区分：

- 已由代码和自动化证明的客户端能力；
- 已由模拟器/设备实际证明的行为；
- 仍需正式凭据/后台/真实账号才能证明的生产事项。

## 16. iOS 源码核对后的精确补充

以下细节来自最终 iOS 源码与专项测试，Android 不应在移植时简化：

### 16.1 Google 回调和下载一致性

- OAuth 参数还包括 `access_type=offline`、`trigger_onepick=true`、`allow_multiple=false`；普通选择使用 `prompt=consent`，换号使用 `select_account consent`。
- callback 同时精确校验 scheme、host、path、state；picked file ID 必须恰好一个。若返回 scope，集合必须严格等于 `drive.file`，不是“包含即可”。
- `about.get` 的 `permissionId` 是原始稳定账号 ID，本机哈希后再使用；不额外申请 profile scope。
- Google 和 OneDrive 都要用下载前、下载后两次 metadata 包围同一传输。revision、MIME、size 或 name 发生变化时删除字节并重试一次；第二次仍变化返回可重试的 `file_changed_during_download`。

### 16.2 更严格的资源限制

- 磁盘空间预检除目标文件上限外，再保留 64 MiB 安全余量。
- DOCX：最多 20,000 entries，单条展开最多 32 MiB，总展开最多 256 MiB。
- EPUB/通用 ZIP：最多 20,000 entries，单条展开最多 64 MiB，总展开最多 512 MiB。
- 对展开后至少 1 MiB 的条目，压缩比不得超过 200；ZIP directory metadata 检查后，实际读取仍逐 chunk 计数。
- PDF 必须能打开、至少一页且未锁定；DOCX 必须包含 `[Content_Types].xml`、`word/document.xml` 和 WordprocessingML content type；EPUB 根 `mimetype` 必须精确为 `application/epub+zip`，并有合法 `META-INF/container.xml`。
- Android 现有 `PdfNativeEngine` 会复制 ByteArray 且会捕获 `Throwable`，不能吞掉 `CancellationException`；EPUB/OCR 循环也要加入协作取消。优先让大文件使用 file-backed payload，避免 200 MiB PDF 在内存和临时文件间多次复制；DOCX 的 Base64 渲染还会额外膨胀约三分之一。

### 16.3 历史身份和前向兼容

- 建议使用带长度前缀的组件再做 SHA-256：
  - `accountKey = hash(provider, rawAccountID)`
  - `documentID = hash(provider, accountKey, driveID, remoteItemID)`
  - `contentSessionKey = hash(documentID, finalRevision, effectiveFormat)`
- 远程改名保持同一 document ID，只更新标题；revision 或有效格式变化必须更换 content session key 并彻底重建 reader/player/highlight 状态。
- 加载旧索引时，若云盘记录意外残留 payload/cover 应主动删除。未知的未来 provider 要保留为不可打开的 inert remote record，不能因解码失败降级成 local payload。
- Google 断连后的历史重开不能静默启动 Picker；应提示用户显式连接原账号。Dropbox/OneDrive 可以 silent restore，但 account key 必须精确匹配。

### 16.4 Provider 特有恢复状态

- Google refresh 必须 single-flight；credential 写入使用 compare-and-swap。pending revoke 绑定 stable account key 与 credential generation fingerprint；revoke-only token 永远不能再调用文件 API。
- Dropbox 显式持久化 active/candidate/retired token UID；迟到 callback 只清自己的 orphan token，不能清当前 active 或新尝试。
- OneDrive 显式持久化 active/candidate/retired MSAL account identifier 及 crash-safe pending-cleanup 集合；每成功清理一个 identifier 就持久化剩余集合。旧 silent refresh 只能返回请求所需 token，不能把旧账号重新写成 active。
- 冷启动只回收 CastReader 命名的云盘临时目录，不扫描或清空整个应用/系统 cache。
- 浏览、分页、搜索共享一个 UI mutation lane；搜索防抖基线为 350 ms；全局仅允许一个活动导入。

### 16.5 Android 网络与 Activity 接线

- 建立独立的 provider OkHttp client，不复用会附加 CastReader session/TTS interceptor 的 first-party client；关闭 body/PII logging。
- `MainActivity` 当前为 `singleTask`，`onNewIntent` 已处理分享。如果 OAuth 需要自行接 deep link，必须按 owner/state 分流且单消费；能由官方 SDK/AppAuth receiver Activity 接管时优先使用官方机制。
- Google/Dropbox/OneDrive public client 配置从 `local.properties`/环境注入到 BuildConfig 或资源；正式与 debug 签名的 redirect/hash 分开登记。缺少或格式错误时 fail closed，SDK 初始化不得导致 App 启动崩溃。
- no-upload 除运行期网络 spy 外，再加静态架构测试：`cloud/` 与统一导入包不得 import `COSUploader` 或上传 API。

### 16.6 隐私与埋点的更窄边界

- 不复制未经审计的“无训练/无广告、正文不保留、30 天日志、服务器地区”等承诺。授权披露只陈述已经由产品和代码证明的事实。
- 日志、analytics 和 crash 附件除 token/正文外，也不得包含邮箱、账号 ID、drive/file ID、文件名、路径、搜索词、provider URL/query/header、预授权 URL、精确文件大小或敏感响应体。
- 允许的遥测仅限 provider、格式、大小/时延桶、首次连接、结构化错误类别、场景和朗读/解读模式；来源值固定为 `google_drive`、`dropbox`、`onedrive`。
