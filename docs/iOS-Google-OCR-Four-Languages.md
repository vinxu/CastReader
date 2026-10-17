# iOS 新增四种内容语言

本次在 iOS 1.2.52（89）的最新 main 基线上新增孟加拉语 `bn-IN`、马拉地语 `mr-IN`、旁遮普语 `pa-IN`（Gurmukhi）和泰米尔语 `ta-IN`。全球线路的内容语言从 28 种增至 32 种；界面本地化仍为原有 28 种，中国线路仍为原有 9 种。未更改版本号、安装真机或提交 App Store。

拍照、图片和扫描 PDF 可以使用 Google OCR，识别后的文字与词框继续进入现有朗读、高亮和播放管线。Kindle 已知语言页面也按同一语言合同路由到 Google OCR，独立栏裁图使用 `single-flow`；离线 Kindle OCR 明确拒绝这四种需要联网的语言。

导入页与设置页共用原有的 `image_text_language_v1` 设置，避免两个语言选择互相覆盖。导入页提示这四种语言使用云端识别。相机、相册权限说明的 28 份现有翻译同步移除了“照片不会上传”的旧描述，说明部分语言会经 CastReader 发送到 Google 识别。

`CloudOCRService` 只调用当前账号线路的 `/api/mobile/ocr`，发送 `cms_` session 和 `X-Auth-Provider: session`。Google 密钥仅在服务端。一次 401 可以刷新同一账号的 session；退出账号、切换账号和取消请求会丢弃正在返回的识别结果。中国线路与缺少 session 的请求在上传前拒绝。

图片先归正，再缩放至最长边不超过 2500 像素，并限制 JPEG 为 2.5 MB。服务端返回的图片尺寸必须与实际发送图片一致。客户端校验词 ID、语言、有限坐标及图片边界，将 Google 左上原点的词框转换为现有 Vision 左下原点坐标。阅读顺序完全沿用服务端修复结果，保留孤立词归位、目录、双栏和页脚修复。长页只按该顺序分成有界朗读段，不再排序或生成推测词框。

## 已完成验证

- iOS Simulator 编译及 114 项相关单元/集成回归通过，覆盖四语言识别、8 个真实音色的词级高亮映射、登录刷新、退出账号、离线边界、图片导入和原有音色目录。
- 真实 UI 测试通过：用既有图片语言设置选择旁遮普语，导入页显示对应语言与云端说明。最初的未签名 UI 构建在原有 Keychain 配置检查处失败，随后改用带签名的隔离模拟器构建通过，未改动 Keychain 保护。
- 服务端排序对 160 个已有样本与冻结 v3 结果完全一致；新的 Google 返回值解析器也通过全部 160 个真实响应。
- 新增 8 次真实 Google WaveNet 书页片段合成，共 104.424 秒、172 个原生词时间点。测试夹具将四张完整书页的原生词框和这些真实时间点交给 iOS 的 `CloudOCRResponse`、语言检测器及 `OCRWordAligner`，全部对应成功。不是插值时间戳，也不是模拟合成音频。
- 后端 32 项 OCR/TTS 合同测试与独立 PostgreSQL 并发/预算测试通过；原有发布基线、Safari 扩展和 Mac 共享工程检查通过。

这些是代码、几何与联动验收，不代表已经部署的新 OCR 网关端到端验收，也不替代母语者发音审听。

## 配套服务端

后端分支为 `readout-web` 的 `codex/ios-google-four-languages`，入口 `src/app/api/mobile/ocr/route.ts`。激活步骤、数据库迁移、公司 Vision 专用凭据、预算与音色目录配置见该仓库的 `docs/ios-google-four-language-support.md`。

上线顺序是先通过受保护 beta 发布流程验证和部署后端，再发布 iOS。生产环境目前还未配置本次专用 Vision 凭据、应用 OCR 表迁移或启用新音色；本次没有变更生产环境。服务端未就绪时客户端显示不可用信息，不会悄悄改用英语或不适合的本地 OCR。

本地验收产物位于 `/tmp/ios-four-acceptance.xcresult`；可长期保留的摘要和截图另存于本工作树 `reports/ios-google-four-language-support-20261017/`。复核测试可运行 `CloudOCRTests`、`MultilingualContractTests`、`ReadingLanguageTests`、`VoiceCatalogTests`、`CapturePipelineTests` 与 `CastReaderUITests/testCloudOCRLanguageChoiceUsesTheSharedImagePreference`。


真实 OCR / 原生时间点夹具的公开书页来源：

- [book-bn-00d2209578cc](https://bn.wikisource.org/wiki/%E0%A6%AA%E0%A6%BE%E0%A6%A4%E0%A6%BE:%E0%A6%97%E0%A7%80%E0%A6%A4%E0%A6%BE%E0%A6%9E%E0%A7%8D%E0%A6%9C%E0%A6%B2%E0%A6%BF_-_%E0%A6%B0%E0%A6%AC%E0%A7%80%E0%A6%A8%E0%A7%8D%E0%A6%A6%E0%A7%8D%E0%A6%B0%E0%A6%A8%E0%A6%BE%E0%A6%A5_%E0%A6%A0%E0%A6%BE%E0%A6%95%E0%A7%81%E0%A6%B0.djvu/%E0%A7%AF)
- [book-mr-09559f905884](https://mr.wikisource.org/wiki/%E0%A4%AA%E0%A4%BE%E0%A4%A8:%E0%A4%AA%E0%A5%8D%E0%A4%B0%E0%A5%87%E0%A4%B0%E0%A4%95_%E0%A4%9A%E0%A4%B0%E0%A4%BF%E0%A4%A4%E0%A5%8D%E0%A4%B0%E0%A5%87_%28Prerak_Charitre%29.pdf/33)
- [book-pa-02650d15e74f](https://pa.wikisource.org/wiki/%E0%A8%AA%E0%A9%B0%E0%A8%A8%E0%A8%BE:%E0%A8%AE%E0%A8%BE%E0%A8%A3%E0%A8%95_%E0%A8%AA%E0%A8%B0%E0%A8%AC%E0%A8%A4.pdf/10)
- [book-ta-1dce9d49f44a](https://ta.wikisource.org/wiki/%E0%AE%AA%E0%AE%95%E0%AF%8D%E0%AE%95%E0%AE%AE%E0%AF%8D:%E0%AE%85%E0%AE%B1%E0%AE%BF%E0%AE%B5%E0%AE%BF%E0%AE%AF%E0%AE%B2%E0%AF%8D_%E0%AE%95%E0%AE%B3%E0%AE%9E%E0%AF%8D%E0%AE%9A%E0%AE%BF%E0%AE%AF%E0%AE%AE%E0%AF%8D_6.pdf/939)
