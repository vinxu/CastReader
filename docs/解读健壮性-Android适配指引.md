# 解读（QuickRead）健壮性适配 —— Android 对齐指引

> iOS 已实现，本文给 Android 做同样的适配。核心：**网络抖动自愈 + 提交前审查，不再一遇错就停、不无脑提交。**

## 一、问题现象

解读偶发 `HTTP 400`、直接停下报错让用户手动 Retry，两种场景：

1. **短内容解读直接报错**：如剪贴板里只有一句话「起草《听读习惯报告》初稿」，点解读 → 转圈几秒 → `Explain service error (HTTP 400)`。
2. **长内容解读到中途突然报错**：正常长文（mark 都画出来了）解读到一半，网络抖一下 → 切批/取块的某个请求失败 → 整条链路停、报 400。

## 二、根因

| # | 根因 | 说明 |
|---|------|------|
| 1 | **网络层零重试** | `QuickReadApi` 的 extract-plan / extract-block / compose-block 任何一次失败（网络抖动、网关瞬时 5xx/400、SSE 截断）直接抛出 → ViewModel 捕获 → 整个解读停。一次抖动 = 整条链路死。 |
| 2 | **无提交前审查** | 不管内容多短都无脑发后端。解读 = LLM 对内容生成讲解，一句话没东西可讲，后端 extract-plan 返回 400 拒绝。用户白等几秒重试才看到错。 |
| 3 | **Android 特有**：非 402 错误被静默 | `QuickReadApi.extractBlock/composeBlock` 当前只检查 `resp.code == 402`，其它非 2xx（400/500）不抛错、直接解析 body → 多半解析失败返回 `null` section → 该块被悄悄跳过。**要先补 code 检查，才能判断是否重试。** |

## 三、iOS 解决方案（4 层，Android 逐层对齐）

### 第 1 层：网络请求重试（指数退避）—— 最关键

iOS 在 `QuickReadService`（actor）里加了 `withRetry`，包住三个请求：

```swift
// 对网络层错误 / 5xx / 429 / 408 / 瞬时 400 / 流式截断自动重试（最多 3 次，0.6→1.2→2.4s 退避）
private func withRetry<T>(_ operation: () async throws -> T) async throws -> T {
    var attempt = 0
    while true {
        do { return try await operation() }
        catch {
            attempt += 1
            guard attempt < 3, Self.isRetryable(error) else { throw error }
            let backoff = min(4.0, 0.6 * pow(2.0, Double(attempt - 1)))   // 0.6, 1.2, 2.4s
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
        }
    }
}

private static func isRetryable(_ error: Error) -> Bool {
    if error is URLError { return true }                         // 网络层（超时/断连/DNS）
    if case QuickReadError.httpError(let code) = error {
        return code >= 500 || code == 429 || code == 408 || code == 400   // 服务端临时/限流/网关瞬时
    }
    if case QuickReadError.decodeError = error { return true }   // 流式截断/部分响应
    if case QuickReadError.noBlock0 = error { return true }      // SSE 中途断、没拿到首块
    return false
}
```

- `extractPlan`（SSE）整条流包重试（重连重建流）；`onBlock0`/`onStage` 回调要**幂等**（用「最后一次覆盖」的 box / 只更新 UI 文字），因为重试会再触发。
- `extractBlock`/`composeBlock` 直接包重试。
- **不重试**：402（付费墙）、401（鉴权）、invalidURL。

#### Android 落点：`QuickReadApi.kt`（extractPlan:68 / extractBlock:120 / composeBlock:139）

```kotlin
// 先补：每个请求检查 HTTP code（当前只检查 402），非 2xx 抛异常，才能让重试判断生效
private fun checkCode(resp: Response) {
    when {
        resp.code == 402 -> throw QuickReadPaymentRequiredException()
        !resp.isSuccessful -> throw QuickReadHttpException(resp.code)   // 新增异常类型，带 code
    }
}

// 通用重试
private suspend fun <T> withRetry(maxAttempts: Int = 3, block: suspend () -> T): T {
    var attempt = 0
    while (true) {
        try { return block() }
        catch (e: Exception) {
            attempt++
            if (attempt >= maxAttempts || !isRetryable(e)) throw e
            delay((600L * (1L shl (attempt - 1))).coerceAtMost(4000L))  // 0.6, 1.2, 2.4s
        }
    }
}

private fun isRetryable(e: Throwable): Boolean = when (e) {
    is java.io.IOException -> true                               // OkHttp 网络层（超时/断连）
    is QuickReadHttpException -> e.code >= 500 || e.code == 429 || e.code == 408 || e.code == 400
    is com.squareup.moshi.JsonDataException -> true              // 解析失败（流式截断）
    else -> false
}

// extractBlock 用法（composeBlock 同）：
suspend fun extractBlock(base, key, deviceId, request): QrSection? = withRetry {
    withContext(Dispatchers.IO) {
        okHttpClient.newCall(req).execute().use { resp ->
            checkCode(resp)                                     // ← 先检查 code
            val body = resp.body?.string() ?: return@use null
            moshi.adapter(QrBlockResponse::class.java).fromJson(body)?.section
        }
    }
}
```

- **SSE 的 extractPlan 重试**同样整条包 `withRetry`；注意 SSE 解析里 `onEvent` 回调在重试时会重放，ViewModel 端 block0 用「最后覆盖」处理（Android 已用 `var block0` 覆盖，天然幂等）。
- `QuickReadPaymentRequiredException`（402）不进重试。

### 第 2 层：提交前预校验 —— 不无脑提交

iOS 在 `ExplainViewModel.start()` **最前面、额度检查之前**加内容量审查：

```swift
func start() {
    guard status == .idle || isErrorState else { return }
    // 提交 LLM 前预校验：内容太短，LLM 没东西可讲 → 直接引导朗读，不发请求、不等重试、不消耗额度
    let contentChars = doc.readableParagraphs.reduce(0) { $0 + $1.text.trimmingCharacters(in: .whitespacesAndNewlines).count }
    if contentChars < minExplainChars {
        status = .error(String(localized: "内容太短，无法解读，试试朗读"))
        return
    }
    guard pro.isPro || quota.canStartExplain(...) else { showPaywall = true; return }
    quota.noteExplainStarted(...)   // 额度计数在预校验之后 → 太短的内容连额度都不扣
    ...
}

/// 中文字符密度高、阈值低；其他语言按字符计
private var minExplainChars: Int { doc.language.hasPrefix("zh") ? 20 : 50 }
```

- **放在额度检查之前是关键**：太短内容连一次解读额度都不消耗。
- 长文档（PDF/EPUB）、正常段落内容量远超阈值，正常放行。
- 阈值（中文 20 字 / 英文 50 字符）是「一句话级别」下限，可按实测调。

#### Android 落点：5 个 reader VM 的 `startExplain`

`PhotoReaderViewModel` / `EpubReaderViewModel` / `PdfReaderViewModel` / `QuickReadViewModel` / `WebViewReaderViewModel`。**建议抽一个公共扩展函数避免重复**：

```kotlin
// 放公共处（如 util），各 VM 的 startExplain 开头调用
fun minExplainChars(lang: String): Int = if (lang.startsWith("zh")) 20 else 50

fun List<MarkdownParagraph>.explainContentChars(): Int =
    filter { it.type != ParagraphType.IMAGE && it.type != ParagraphType.CODE }
        .sumOf { it.text.trim().length }

// 每个 VM 的 startExplain 开头（在 consumeExplain 扣额度之前）：
fun startExplain(isReplay: Boolean = false) {
    if (explainActive) return
    val chars = doc?.paragraphs?.explainContentChars() ?: 0   // web 源用提取后的段落
    if (chars < minExplainChars(lang)) {
        _uiState.update { it.copy(mode = EXPLAIN, error = "内容太短，无法解读，试试朗读") }
        return
    }
    // ... 原有 consumeExplain / runPipeline
}
```

> ⚠️ **web 源注意**：网页/DOCX 段落是 WebView 异步提取的，`startExplain` 必须在「段落已提取」之后调用，否则内容量算成 0 会误拦。iOS 是 onRendered 回调后才 start，Android 对应确认时机一致。

### 第 3 层：重试仍 400 → 友好提示（不裸露 HTTP 码）

iOS 在解读 plan 的 catch 里区分 400：

```swift
} else if case QuickReadError.httpError(400) = error {
    // 重试 3 次仍 400：多为内容太短/不适合解读
    status = .error(String(localized: "内容太短或暂不支持解读，请稍后重试"))
}
```

#### Android 落点：各 VM 的 `runPipeline` catch（`catch (e: QuickReadHttpException)` 当 `e.code == 400` 时给可读文案）。

### 第 4 层：中间批失败时 mark 保留（iOS 修过的坑，Android 确认即可）

iOS 之前 bug：切批 `advanceBatch` 里有 `activeMarks = []`，导致进入下一批时**前面批的 mark 全没了**。已改成跨批累积、不清。

- **Android 确认点**：`EpubReaderViewModel.runPipeline` 切批时**不要清 `_uiState.marks`**（Android 当前看起来是累积的，addMark 用 `it.marks + mark`，切批没清 → 已对，确认即可）。
- 这样即使某批最终失败，前面已画的 mark 仍留在原文上，不会全盘消失。

## 四、参数参考（两端对齐）

| 参数 | 值 |
|------|-----|
| 重试次数 | 3 |
| 退避 | 0.6 → 1.2 → 2.4s（上限 4s） |
| 可重试 | 网络层错误、5xx、429、408、瞬时 400、解析失败/SSE 截断 |
| 不重试 | 402（付费墙）、401、URL 错误 |
| 预校验阈值 | 中文 20 字 / 其他 50 字符（一句话级下限，可调） |
| 预校验位置 | startExplain 最前，**额度扣减之前** |

## 五、完整链路（适配后两端一致）

```
点解读
  → 提交前预校验：内容太短 → 秒提示「内容太短，试试朗读」（不发请求、不扣额度）
  → 内容够 → 发请求
      → 网络/网关抖动（瞬时 5xx/400/超时/SSE 断）→ 自动重试 3 次自愈
      → 真持续 400（后端拒绝）→ 友好提示「内容太短或暂不支持解读」
      → 402 额度满 → 付费墙
      → 中间批失败 → 已画 mark 保留、不全盘清空
```
