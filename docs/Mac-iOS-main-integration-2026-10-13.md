# Mac / iOS 主线整合（2026-10-13）

本次从远端 main `a95540d4b74e1c62cc9afcc8683752a97f0e2172` 开始，先快进到 iOS 分支 `6d42fa01368b448df494db26fdd3be7102048305`（新增验证脚本），再三方合并 Mac 分支 `b0fbc1570841960786435c270f9ecebe959deea8`。原始发布分支保留，不从主目录旧开发分支复制源码。

## 保留与整合

- iOS 1.2.49（84）：Duo 系统纵向导航、普通设备底部导航、折叠重排、用户暂停所有权、锁屏自动翻页、Kindle 跨页整句及恢复。
- Mac 1.2.48（76）：原生侧栏、窗口与文件路由、摄像头/文件导入、Share/Widget、28 语、书库恢复及额度购买状态。
- 导航、阅读器布局、Google Books 来源定位及回归夹具逐段整合，保留双方测试。额外修复自动合并后的 Mac 窗口缩放判断：Catalyst 始终保留播放恢复能力，不依赖 iPad idiom 或 Duo 系统导航区。
- 首轮回归发现 Kindle 准备状态遗漏及 Mac TTS 策略侵入 iOS：合并首次播放与高亮恢复状态，保留取消能力；Mac 使用逐句请求策略，iOS 保留原有普通/克隆音色分段、Kindle 完整跨页单元及短开场预缓冲。恢复 iOS 原有分段测试，并分别验证平台行为。
- Mac 工程由当前 iOS 共享源码图生成。校验脚本冻结 iOS 1.2.49 main 基线，保护 iOS 原有 target 设置和扩展；Mac 版本继续由 `scripts/mac-release-version.json` 管理。
- OCR 按需下载 WIP `a016626d` 未纳入发布主线；此次仅合并代码，没有打包安装真机或提交应用商店。

## 静态与网页验证

- `scripts/verify-mac-project.rb`：PASS，244 个共享源码、15 个共享资源，iOS 原设置及扩展未变。
- `scripts/build-voice-toc-integration.sh --check`：发布祖先保护通过。
- `scripts/verify_safari_extension.rb`：PASS，iOS 1.2.49（84）、Safari 28 语，资源摘要 `646101eb388680da1fdcb80dd56c124c8217a3f2bcaf8bd575335ae8cf08093f`。
- 三份字符串目录保留双方全部条目和 iOS 已有翻译：主目录 1581 条、云存储 111 条、Share 19 条。
- 1024×1024 应用图标已在 main 跟踪，本次保持字节不变：`CastReader/Assets.xcassets/AppIcon.appiconset/icon-1024.png`，SHA-256 `147e5b9532b28e353f5cb13ff8c6fc7ce4d03d84a2e42d72c71c2377b4cc5aa0`；Asset Catalog 引用的 18 张图标均随 Git 提供。
- `WebReader/play-books-reflow-test.mjs`：6 个重排来源定位场景通过。
- `WebReader/kobo-fixture-test.mjs`：真实 Chrome 夹具通过，包含双方新增的折叠/锁屏恢复与桌面双页章节边界；合并后扩展虚拟时间预算以运行完整场景。
- 使用扩展仓库 `d1a5eca8` 的 `src` 作为 `READOUT_DESKTOP_SOURCE` 重新构建，生产 `bundle.js` 和 XCTest bundle 与三方合并产物逐字节一致。不要直接使用其他开发分支的扩展依赖重建并覆盖发布资源。

## 双平台隔离测试

测试使用独立 bundle、Keychain 和 app-group 命名空间，不操作用户已登录的正式应用数据。

- 初测：iOS 492 项（479 通过、10 失败、3 跳过）；Mac 504 项（500 通过、1 失败、3 跳过）。失败均对应上文的合并整合问题。
- 修复后两端重新编译成功，受影响的 Kindle 启动/恢复、WebView、跨页、朗读衔接、语音管线及分段契约复测：iOS **251/251**、Mac **250/250**，零失败、零跳过。初测全部失败用例均在复测中通过；最终源码与测试快照逐一匹配。
- 初测跳过项为两端各一个在线 Google Books shell 和捷克语、芬兰语外部 PDF 夹具，没有把跳过项记为通过；本次不宣称完成线上账号/支付或真机发布验收。
- 可复核摘要：[validation.json](../reports/main-integration-20261013/validation.json)。
