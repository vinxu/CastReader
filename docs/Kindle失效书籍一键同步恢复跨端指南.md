# Kindle 失效书籍一键同步恢复跨端指南

## 1. 问题背景

Kindle Cloud Reader 的本地书架记录并不保证长期有效。用户一段时间未打开 Kindle、Amazon 会话或 Cloud Reader 内部状态变化后，从 CastReader 本地缓存直接打开书籍，可能出现 Amazon 原生错误弹框：

- `Oops... Something Went Wrong`
- `Please try to open this book from the library again.`
- `Back to Library`

用户手工可通过以下流程恢复：

1. 退出当前书。
2. 进入 Kindle 书架。
3. 点击刷新并重新同步书架。
4. 同步完成后退出书架。
5. 再次点击该书。

普通用户不知道这条恢复路径，因此 CastReader 必须把它产品化为“一键修复”。

## 2. 最终产品合同

检测到上述 Kindle 错误页后，CastReader 显示原生恢复面板：

- 标题：`Kindle 书籍需要重新同步`
- 主操作：`修复并打开`
- 次操作：`返回`
- 明确说明不会清除音色、语速、朗读/解读模式等 CastReader 设置。

“修复并打开”必须完整复现人工恢复流程，而且要复现**客户端运行环境边界**：

1. 创建与正常书架页配置一致的干净书架 WebView：默认移动端 UA、共享默认 Cookie/DataStore、不注入阅读器脚本。
2. 把书架 WebView 以正常尺寸挂入当前可见视图层级，再加载 Kindle 书架。
3. 等待书架 SPA 的真实内容渲染完成。
4. 完整扫描并同步书架到本地缓存。
5. 同步完成后，从新书架快照中重新查找当前书。
6. 销毁书架 WebView，创建全新的桌面阅读 WebView。
7. 使用新同步得到的书籍入口重新打开。

恢复期间显示阶段状态：

- 正在打开 Kindle 书架…
- 正在等待 Kindle 书架加载…
- 正在同步 Kindle 书架…
- 正在重新打开书籍…

## 3. 关键结论

### 3.1 不能只重试旧链接

Amazon 明确要求从 Library 重新打开。直接 reload 当前页面或再次请求本地缓存的 `readerURL`，仍可能得到相同错误。

### 3.2 必须先完成书架同步，再解析当前书

正确顺序是两个阶段：

1. 完整同步书架并更新本地缓存。
2. 从本轮同步结果中匹配目标书并重新打开。

不能边扫描边命中目标后立即退出，否则本地书架只得到不完整快照。

### 3.3 书架运行时与阅读运行时必须隔离

最终验证表明，“复用当前阅读 WebView 进入书架”仍然不等价于用户手工同步。两类 WebView 的配置不同：

| 运行时 | User-Agent | 注入脚本 | 职责 |
|---|---|---|---|
| 书架同步 | 默认 iPhone/移动端 UA | 无阅读器脚本 | 登录、刷新 Kindle 书架、扫描元数据 |
| 书籍阅读 | 桌面 Mac/Chrome UA | Kindle capture/layout/gesture 脚本 | 渲染正文、翻页、OCR、TTS 高亮 |

Amazon 会把 UA、页面运行时状态与共享 Cookie/DataStore 一起用于 Kindle 会话。共享 Cookie 并不意味着两个页面运行时可以互换。已经进入 stale-book 错误态的桌面阅读 WebView，即使导航到书架并抓到目标书，再从 DOM 点击该书，仍可能返回同一个 `Back to Library` 错误。

因此恢复时必须创建与正常书架同步页面**同配置**的干净移动端 WebView；不能把桌面阅读 WebView临时当成书架同步器。

### 3.4 恢复 WebView 必须可见挂载

不要创建零尺寸、未加入视图层级的隐藏 WebView 扫描 Kindle 书架。Kindle 书架是 SPA，并使用响应式/懒加载/虚拟列表；零尺寸后台 WebView 即使触发 `didFinish`，也可能始终返回：

```text
rows=0 signals=N auth=N
```

恢复书架 WebView 可以被原生进度面板覆盖，但自身必须以真实阅读区域尺寸挂入视图树。同步完成前不能 detach、置为 0x0 或只保留离屏对象。

### 3.5 同步后必须创建新的阅读运行时

访问书架并更新本地缓存只完成了恢复的第一阶段。旧阅读 WebView 已经处于 Amazon 错误状态，不能继续承担重新打开任务。

同步成功后必须：

1. 销毁移动端书架 WebView；
2. 保持原生阅读容器仍处于 presented 状态，避免用户看到退出/闪回；
3. 创建全新的桌面阅读 WebView；
4. 使用本轮同步得到的 ASIN/入口加载书籍；
5. 重新安装阅读脚本并以正文 blob/翻页控制出现作为成功证据。

不要在恢复开始时清除原生 reader owner/session，否则界面会退出，用户再次点击会创建第二条并发恢复链路。

### 3.6 `didFinish` 不等于书架已就绪

`didFinish` 只代表 HTML 外壳加载完成。Kindle 的书架内容随后由 JavaScript 异步渲染。

进入书架后必须轮询真实状态，直到出现以下任一条件：

- 抓到至少一本书；
- 明确检测到 Amazon 登录失效；
- 达到等待超时。

空结果不能在前三次轮询后直接解释成“书架没有这本书”。

## 4. 状态机

```text
reader_error_detected
  -> mobile_library_runtime_creating
  -> library_loading
  -> library_waiting_for_content
  -> shelf_syncing
  -> target_resolving
  -> mobile_library_runtime_destroying
  -> desktop_reader_runtime_creating
  -> book_reopening
  -> success

失败分支：
  -> sign_in_required
  -> shelf_load_timeout
  -> target_not_found_after_nonempty_sync
  -> recoverable_error
```

只有满足以下条件，才允许报告 `target_not_found`：

1. 书架已真实加载；
2. 至少扫描到一本有效书；
3. 完整扫描结束；
4. 仍无法按稳定身份匹配目标书。

## 5. 错误页检测

不要只在导航完成时检测一次。Amazon 弹框可能在 SPA 渲染数秒后出现，应进行短时轮询或 MutationObserver 检测。

建议组合特征：

- body 文本包含 `please try to open this book from the library again`；
- dialog 文本包含 `something went wrong`；
- 可交互节点包含 `Back to Library` 或 `Return to Library`；
- DOM 包含 `[role=dialog]`、`[aria-modal=true]` 或 Kindle alert button。

检测应容忍空白、大小写和 DOM selector 变化。

## 6. 书籍匹配

优先级：

1. 本地 `book.id == syncedBook.id`；
2. 归一化 ASIN 相同；
3. 必要时用 Amazon 返回的稳定 reader identity 兜底。

不要用标题作为主键。标题会因语言、版本和标点变化。

匹配成功后必须使用本轮书架同步返回的书籍元数据和入口，不使用恢复前的旧缓存。

## 7. 书架扫描

对 Kindle 虚拟列表分段扫描：

1. 抓取当前 viewport。
2. 合并到 `bookId -> book` 去重表。
3. 找到真实 scroll container。
4. 按约 80% viewport 高度滚动。
5. 等待 500–700ms，让虚拟列表渲染。
6. 连续两轮无新增且已抓到有效书后结束，最多约 12 轮。

书架为 0 本时不能使用“连续两轮无新增”提前结束；应继续等待 SPA readiness 或报告书架加载超时。

## 8. JSON/WebView 桥接避坑

Kindle 书架抓取脚本当前返回 JSON 字符串。客户端应：

1. 如果 WebView 返回 String，直接 UTF-8 转 Data 后解析。
2. 只有 `isValidJSONObject` 为 true 时，才对桥接对象调用 JSONSerialization。

不要对返回的 JSON 字符串再次 `JSON.stringify`，否则会形成双重 JSON。也不要把未经验证的 WebKit 私有桥接对象直接传给 JSONSerialization；iOS 会抛 Objective-C exception，Swift `do/catch` 无法捕获并导致 SIGABRT。

## 9. iOS 落地位置

- 错误检测、恢复状态与重新打开：`CastReader/Views/Kindle/KindleBookView.swift`
- 一键书架同步服务：`CastReader/Services/KindleLibraryRecoveryService.swift`
- 书架抓取脚本：`CastReader/Services/KindleWebScripts.swift`
- 本地书架合并：`CastReader/Services/KindleLibraryStore.swift`

已验证真机流程：失效书籍 -> 挂载移动端书架 WebView -> 完整同步 -> 重新匹配 -> 创建全新桌面阅读 WebView -> 正文 blob 出现。

真机成功证据（2026-07-13）：

```text
library readiness rows=16 matched=Y ua=Mozilla/5.0 (iPhone; CPU...)
synchronized book=B002RKRMSY fresh-reader=required
fresh-reader created book=B002RKRMSY
layout probe blobs=1
geometry ok=true
stale-entry probe clear attempts=48
```

同一轮恢复后，`B000JQUU00` 与 `B015YGAXHO` 也能直接打开并出现正文/翻页控制。

## 10. Android 落地要求

Android 不照搬 Swift 架构，但必须保持相同产品语义：

1. 在桌面 UA 的 Kindle reader WebView 检测 Amazon 错误 dialog。
2. 显示原生 Compose 修复面板，包含阶段状态、重试和返回。
3. 创建与 Android 正常 Kindle 书架页完全相同配置的干净 WebView：移动端 UA、共享 CookieManager、无 reader bridge/capture/layout 注入。
4. 把恢复书架 WebView 以正常尺寸挂入当前 Activity/Compose AndroidView；不能使用 0x0、`GONE`、未 attach 或纯后台 WebView。
5. 等待 SPA 真实书架内容出现后再开始 scrape。
6. 完整滚动扫描并更新 Android Kindle shelf repository。
7. 同步完成后按 bookId/ASIN 匹配当前书。
8. 销毁移动端书架 WebView，创建新的桌面 UA reader WebView；不要复用已经进入错误态的 reader 实例。
9. 用本轮同步结果打开该书，并以正文图片/canvas/翻页控制出现作为成功条件。
10. 原生 reader owner/navigation 必须保持 presented，替换 WebView 不应 pop Activity 或返回书架列表。
11. generation/task token 取消旧恢复任务，快速重复点击只保留最后一次。
12. 登录失效时明确进入登录处理，不显示“找不到书”。
13. 新 reader 再次失败时停在可重试状态，不自动开启第二轮同步。
14. 恢复过程不得清除 CastReader 播放设置、进度锚点或 Pro 状态。

## 11. 跨端日志合同

至少记录：

```text
kindleRecovery errorDetected book=<truncated>
kindleRecovery libraryRuntime created uaFamily=<mobile> attached=<Y/N> viewport=<w>x<h>
kindleRecovery libraryLoad start/finish url=<redacted>
kindleRecovery readiness attempt=<n> rows=<n> signals=<Y/N> auth=<Y/N> uaFamily=<mobile|desktop>
kindleRecovery scan pass=<n> rows=<n> unique=<n> matched=<Y/N>
kindleRecovery shelfCommitted count=<n>
kindleRecovery targetResolved id=<truncated> asin=<truncated>
kindleRecovery libraryRuntime destroyed
kindleRecovery readerRuntime recreated uaFamily=<desktop>
kindleRecovery reopen start/success/failure
kindleRecovery result=<success|auth_required|timeout|not_found|error>
```

不得记录书籍正文、Cookie、token 或完整账户信息。

## 12. 验收矩阵

1. 失效旧链接：一键修复后自动打开书籍。
2. 正常书籍：不出现恢复面板，不增加导航。
3. SPA 延迟 3–10 秒：等待内容，不误报找不到。
4. 大书架虚拟列表：可滚动扫描到非首屏书籍。
5. Amazon 登录失效：提示重新登录，不提示书籍不存在。
6. 目标书确实移出书架：同步到其他有效书后才提示找不到。
7. 重复点击修复：仅一个恢复任务运行。
8. 恢复中返回：任务取消，界面可退出。
9. 恢复成功：音色、语速、朗读/解读模式和本地进度锚点不被清除。
10. 横竖屏与前后台切换：恢复任务不创建第二个播放器或第二个阅读会话。
11. UA 隔离：书架阶段必须记录 mobile UA，阅读阶段必须记录 desktop UA。
12. 运行时隔离：旧错误 reader 不被复用；同步后只创建一个新 reader。
13. 可见挂载：书架 SPA 恢复期间 viewport 非 0，能渲染虚拟列表。
14. 防循环：新 reader 再失败只显示错误，不自动开始下一轮同步。
