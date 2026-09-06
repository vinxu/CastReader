# 21:51 UTC：22 条非核心分类 HTTP504 的路由复核

**22 条全部是博客页面的 GET 渲染请求，均由 Vercel Node 函数运行到 300 秒上限后返回 HTTP504。** 此集合没有 TTS、克隆或 QuickRead API 的 HTTP504。这个结论来自规范化请求路径、固定平台错误码和冻结生产源码；不是由 collector 的 `other` 标签直接推断。

| 项目 | 已确认结果 |
| --- | --- |
| 项目 / 环境 | `prj_wYf9gRnrKR28vEUtOP9hY7ITa7tK` / production |
| 生产部署 | 22/22 为 `dpl_EYb2UAVcLJvk7qaYchgmPhYoHYC5`，源码 `1f9a483c` |
| 请求路径 | `/blog/[slug]` 6 条；`/en/blog/[slug]` 10 条；`/zh/blog/[slug]` 6 条。只保存模板和固定语言，不保存原始 slug/query。 |
| 方法 / 状态 / 错误码 | 22 GET / 22 HTTP504 / 22 `FUNCTION_INVOCATION_TIMEOUT` |
| 函数 | iad1，Node.js 22；函数耗时 300000–300002ms，`functionMaxDuration=300` |
| 请求总耗时 | 300043–300191ms |
| 崩溃字段 | 22/22 `hasFunctionCrashed=false`；这是返回字段，不能扩展成所有底层资源都健康。 |
| 请求开始 UTC | 21:05:47.158–21:10:27.195 |
| 最晚估算请求结束 UTC | 21:15:27.258；由 provider request timestamp + requestDurationMs 计算，不是直接观测到的完成时间字段。 |

[完整脱敏证据](/Users/xuxuheng/Documents/CastReader/reports/audio-playback-recovery-rollout-20260907/monitoring/observations/20260906T2151Z/noncore-504-review.json) 保存 22 个匿名请求键、规范化路径、时间、状态、时长、错误码、部署和固定函数元数据，以及生产 Git blob/SHA 和源码行摘录。

源码定位：`src/app/[locale]/(landing)/blog/[slug]/page.tsx` 的 `generateMetadata:33` 和 `BlogDetailPage:123` 调用 `getPost`；`src/shared/models/post.tsx:154–193` 先等待数据库 `findPost`，之后才取本地内容；`findPost:66–76` 是数据库查询。`src/middleware.ts:138–155` 支持默认语言的无前缀改写，故 `/blog/[slug]` 也归博客组件，不能误当通用 `locale/slug` 页面。该源码提供了可能阻塞的依赖路径，但**本次没有内部异常栈、DB 计时或任意 message 证据，不能断言是数据库连接、查询或 MDX 渲染哪一步阻塞**。已能确定的失败层是博客 Node 函数的 300 秒执行期限。

本轮使用既有 acceptance 汇总和两次同一窗口的只读 request-metadata 查询：`20:51:42.476216Z–21:52:41.458505Z`，仅 HTTP504。两次返回均为 22 条，匿名请求集合相同，`hasMoreRows=false`；第一次仅匹配 API 清单而保留 unmapped 的回执单独保存，随后结合页面路由和安全路径结构完善归类。全最终版本窗口 acceptance 也是 22 条 HTTP504，数量一致；未取得其缓存逐行键用于精确比较。分页完整只说明当前可返回的记录已取完，不保证 provider 保留/入库完全。

与新增 Android PDF Explain 失败的边界：该客户端 `explain_start` 为 21:24:16.505、失败为 21:27:07.828；本集合的博客请求开始更早，即使按完整请求时长估算，也都在约 21:15:27 前结束。没有相同 API 路由或匿名 request/trace 关联可把两者绑定。客户端发生时间可能与服务器时钟有差异；这份报告也不排除不同业务曾共享某种底层资源问题。因此，**客户端 Explain 失败继续单列未定因，不能用“博客504已归类”将它消除，也不能把其并行朗读正常算作 Explain 恢复**。

未读取或输出请求/响应正文、音频、任意日志消息、原始 request ID、账号/设备 ID、查询参数或凭据。TLS 证书与主机名验证开启，HTTPS 重定向被拒绝。没有合成、部署、重启或修改生产路由/代码；已有其他 503 也未在本次重新分类。
