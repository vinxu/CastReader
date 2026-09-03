# 自适应降噪生产发布记录

初次完成时间：2026-09-03 11:38 CST（2026-09-03T03:38:26Z）
国际控制面修正完成时间：2026-09-03 12:04 CST（2026-09-03T04:04:31Z）

## 结论

自适应服务端降噪已经在中国区和全球区全量开启，热开关均为 `on`。两区部署的是同一份 worker，SHA-256 均为：

`552063ec9a1e5e2765e68ab69b60789c3a034ab9d991b7fcaf55b16bfa112b3f`

12 条盲听中，新管线获得 11/12（91.7%）选择。生产策略据此保留：

- 干净录音直接使用原音；
- 03 类稳定机械噪声保守使用原音；
- 其余噪声默认使用 DeepFilter 24 dB；
- 只有三组同文同 seed 探针中至少两组重复证明电流声继续改善，且身份保护全部通过，才升级到 100 dB；
- 降噪身份保护失败、候选重复劣化或自适应子系统异常时回退原音；
- 全量模式下，说话人分离不可用会暂时拒绝建声，检测到明确第二说话人会拒绝录音。

## 生产拓扑和版本

| 区域 | 状态 | 模式 | Worker release | 回滚备份 | 基础服务 |
|---|---|---|---|---|---|
| 中国区 | healthy | on | `fast-hotpath-20260903T033140Z.json` | `fast-hotpath-20260903T033140Z` | TTS 200；Nari 200 |
| 全球区 | healthy | on | `fast-hotpath-20260903T032149Z.json` | `fast-hotpath-20260903T032149Z` | TTS 200；Nari 200；TLS origin 200 |

中国区路径：

- release：`/root/autodl-tmp/nari-staging/releases/fast-hotpath-20260903T033140Z.json`
- backup：`/root/autodl-tmp/nari-staging/backups/fast-hotpath-20260903T033140Z`
- mode：`/root/autodl-tmp/nari-staging/clone/.adaptive-denoise-mode`

全球区路径：

- release：`/workspace/castreader-clone/releases/fast-hotpath-20260903T032149Z.json`
- backup：`/workspace/castreader-clone/backups/fast-hotpath-20260903T032149Z`
- mode：`/workspace/castreader-clone/.adaptive-denoise-mode`
- 异机发布前备份：`us-predeploy-backup/castreader-us-pre-adaptive-20260903.tgz`
- 备份 SHA-256：`9c3d182ff05b8f21c0949b0be7ba82565773ca2c6c8178e234f0c9a92a11704f`

全球 Web 控制面：

- Vercel deployment：`dpl_Bdf2iMYWgwgxrhpVXQbT8ncxrjqX`
- Git source：`0a55c96a7583a9c776529064d74ac13d986ebe27`，基于上一版生产提交 `36281e791cbc2c5381940d5353e81c27fda2af5c`，工作树干净。
- 状态：READY / production
- 正式域名 `api.castreader.ai` 已回读到该 deployment；根路径 200；未登录建声接口 401。
- worker 建声预算 75 秒，Web 到 worker 为 90 秒，Vercel route 为 120 秒。
- iOS 源码中的建声请求预算为 150 秒；服务端管线无需等待客户端发版即可对现有三端请求生效，该客户端余量会随下一版 iOS 带出。

## 国际控制面回退事故与修复

11:25 的初次 Web 发布错误地从旧 detached artifact `fd383f5ff0dad64860fbcf1365962ba5f4aa7cc0` 构建了 `dpl_Vay5GDpSso1NPSRQqQ1gs6efiLHq`。该提交比上一版生产源码少 46 个提交，仍包含“存在任意 active voice 即返回 `409 VOICE_SLOT_FULL`”的旧建声槽位门。

11:49 的真实国际版建声请求在 `reserve-entitlement` 阶段触发该错误；请求尚未进入音频解析、GPU worker 或自适应降噪。iOS 按新契约将这个遗留服务端错误显示为“声音服务暂时不可用”。

处理过程：

1. 立即将 `api.castreader.ai` 回滚到上一版生产 deployment `dpl_53Jm6hhhhKYHdHkJ2H4WnSryTvdV`；
2. 从其源码提交 `36281e791cbc2c5381940d5353e81c27fda2af5c` 建立干净分支，只移植 50 秒到 90 秒的 worker 调用预算；
3. 171/171 voice-clone 测试、TypeScript 检查和 Vercel 生产构建通过；
4. 将干净候选 `dpl_Bdf2iMYWgwgxrhpVXQbT8ncxrjqX` 提升为正式生产，并回读正式域名、根路径 200 与未登录建声接口 401。

后续 Web 发布必须验证候选源码是当前生产源码的后代，或明确记录允许回退的版本差异；不得再从陈旧 detached artifact 直接覆盖生产。

## 固定样本生产 canary

最终代码在两区的主动建声结果：

| 样本 | 预期 | 中国区 | 全球区 | 说明 |
|---|---|---|---|---|
| 01 室内厨房 | atten100 | atten100 | atten100 | 3/3 探针重复证明强降噪改善 |
| 03 室内洗衣机 | online | online | online | 周期性机械噪声保守绕过 |
| 04 室内会议室 | atten24 | atten24 | atten24 | 证据不足时采用标准降噪 |

额外影子验证：

- 干净样本：`online`，`clean-spectral-backstop`；
- 06 公共食堂：`atten24`，但现有短音频说话人分离没有检出第二说话人；见“已知边界”。

最终检查时，两区队列均为 0、`busy=false`、`voice_creation_enabled=true`，测试音色与 `vc_tmpdn_*` 临时 prompt 残留均为 0。上传到服务器的 canary 音频副本已删除。

## 验证结果

- 服务端真实依赖环境：94/94 测试通过；覆盖 selector、模式热切换、哈希锁定、身份保护、说话人分离 fail-closed、临时 prompt 清理、并发/取消和 Nari x-vector 布局。
- 中国区最终修补后的相关回归：32/32 通过。
- 全球 Web：修正后的生产基线 TypeScript 检查通过；voice-clone 171/171 通过；`git diff --check` 通过；Vercel 生产构建完成。
- iOS `VoiceCloneTests`：65/65 通过，0 失败、0 跳过。
- Vercel 修正部署发布后的即时错误扫描未发现本次 voice-clone 5xx；现有多语言 `MISSING_MESSAGE` 日志与本次发布无关。
- DeepFilter 0.5.6 SHA-256：`70775e251eee44c0f2451a1e833326cf8bcbbe304d3e7cd12851e6fce72ef7da`。
- sherpa-onnx pyannote segmentation SHA-256：`220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079`。
- CampPlus SHA-256：`f682b514c05d947ee3fa91cd6ec6c5c7543479a128373fa29b1faedccd21fd11`。

## 发布中修正的问题

全球影子 canary 首次将 01 错误地保守回退到原音。根因是临时诊断探针误用了最终播放音频的电流声拒绝门：本应交给 selector 比较的电流声，被提前视为系统异常。

最终实现只对临时探针检查容器、采样率、时长、静音、削波和直流偏移；电流声作为 E 指标证据继续参与三组配对比较。临时探针永不发布，最终 prompt 仍必须通过 Qwen/CampPlus 身份保护。修补后两区 01 均稳定选择 `atten100`，且 `adaptive_fallback_online=0`。

## 安全处理

全球 TLS origin 的旧进程曾把 `X-Clone-Token` 请求头写入访问日志。本次已：

1. 重启 TLS origin，使无访问日志配置实际生效，并用 canary 验证不再新增认证头日志；
2. 轮换 Vercel 与 GPU worker 的生产凭据；
3. 清空 2 个含旧认证头的 TLS 日志文件；
4. 删除短期回退 token 副本和本机生成 token 文件。

旧敏感日志内容和旧 token 副本已永久删除、不可恢复；当前日志扫描中认证头行数为 0。

## 已知边界

06 公共食堂包含背景人声，但这组不到 10 秒的素材在 sherpa-onnx 分段中仍表现为单说话人。AudioSet 标签、短窗预滚和分离实验也没有找到一个能拒绝 06、同时不误拒 04/10/11/12 的可靠阈值。因此：

- 当前门可以拦截清晰、可分离的第二说话人；
- 不能宣称已可靠识别同声、远场或与主体高度重叠的背景讲话；
- 06 在本次盲听中用户仍选择了新管线，但它只证明降噪偏好，不构成说话人安全保证。

下一阶段应采集真实手机录制的竞争人声校准集，按机型、距离、重叠比例和室内/室外分层，再决定是否上线更强的拒录模型。不要针对当前 12 条素材拟合硬阈值。

## 回滚

首选即时回滚是将对应区域的 mode 文件原子写为 `off`；无需重启，后续新建音色立刻回到原音管线。代码级回滚使用上面记录的区域备份恢复 worker、Nari 和 runner，再按现有 supervisor/进程管理脚本重启并重新绑定 x-vector writer marker。

回滚不影响已生成的历史 prompt。恢复全量前必须重新跑 01/03/04 canary，并确认队列、临时目录和两类模型哈希正常。
