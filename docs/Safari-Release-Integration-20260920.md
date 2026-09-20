# Safari 恢复发布：集成准备记录

状态：**仅完成原生代码集成准备，未构建、未验收、未上传或替换审核包。**

用户要求从本次提交恢复 Safari 扩展，并特别提到笔记本上的 Safari。Mac 扩展和 iPhone/iPad 扩展是不同的平台产物；这里准备的是 iOS 宿主集成，不能用它宣称 Mac Safari 已恢复。

## 保留完整发布基线

- 当前已提交 iOS：1.2.42（64），发布记录提交 `1d35f89e68331c49c24a289da758490321a6d28c`，审核单 `c1501e0f-69a3-4238-b58f-2bac9818b971`。2026-09-20 本轮只读查询仍为 `WAITING_FOR_REVIEW`。
- 集成分支：`codex/ios-safari-release-1.2.42`，工作树 `/Users/xuxuheng/.codex/worktrees/castreader-safari-release-integration/CastReader`。
- 从 `1d35f89` 正式合并 Safari 已提交的原生实现 `6c01a8f24869f024d94cf53092bac385bb4cd375`。没有复制另一任务的未提交代码或生成资源。
- 工程冲突保留双方新增项，经 `xcodeproj` 解析保存。逐个比较原有五个 target 的 Sources、Resources、Debug/Release 配置，确认没有删除原发布文件或改变原发布构建设置。
- Safari target 的版本/Build 对齐宿主当前 1.2.42（64）。**64 仅为当前源码版本；已上传的 64 不得复用，真正替换时必须重新读取商店最大 Build 并递增。**
- `bash scripts/build-voice-toc-integration.sh --check` 通过；原 EPUB 目录、插图/PDF 原页及本批播放修复的祖先和源文件仍保留。

## 尚未具备发布条件

Safari 专项任务「Safari 全功能对齐 Chrome 与 iOS 联合发布」（`01a0bcfa-6d0a-7cc3-ad2f-7ba0468febe1`）仍在进行中。其 2026-09-20 进度记录表明：

- Mac build 11 的长时验收失败，不能算通过；build 12 正在重新采样。
- iOS 原生消息、真实 Safari 登录回传、账号确认后刷新以及核心播放仍需真机验收。合同单测和编译不代表真实 Safari 可用。
- 另一个任务的账号回传修复仍有未提交改动；本分支没有将其当作冻结候选。
- Safari WebExtension Resources 尚未导入本分支；必须使用专项任务最终冻结的扩展提交，生成并记录资源摘要。当前分支不是可安装的 Safari 候选。

## 恢复时的顺序

1. 明确发布平台；Mac 包单独绑定 Mac 源码和实际 Safari 证据，不能以 iOS 包替代。
2. 将最终 Safari 原生提交增量 merge 到本分支，冻结配套 JS 源码及资源摘要，运行同步脚本的只读一致性校验。
3. 通过实际平台的启用、登录/退出取消/切账号、会员与音色同步，以及朗读和解读验收。原生鉴权改动按 `iOS-Core-Service-Release-Gate.md` 补验受影响的 App 管线。
4. 验证完成后再更新发布预检中原先“禁止 Safari target”的规则，改成纳入第四组件并验证 Safari 证据，不能先关闭门禁再补验证。
5. 功能正式合并主线，使用更高 Build 新归档；若替换当前 iOS 审核，只操作上述本次审核单，重新绑定验证过的新包并提交、回读。

本轮未撤回审核、未更改当前商店 Build、未修改专项任务工作树，也未覆盖用户 iPhone 安装。Build 64 的原测试结果只适用于原发布源码，不能直接用于带新增 Safari 鉴权代码的候选。
