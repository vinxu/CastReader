# 相对说话人一致性改为仅告警：两区发布记录

完成时间：2026-09-03 15:12:14 CST（07:12:14 UTC）。

## 结果与范围

中国区、国际区均已部署。仅替换 `clone_worker.py`，两区 source commit 相同：

`3c7a1cea4ac1bd1b65d74c98bfa52e2edaf6ee0f`

两区 worker SHA-256 相同：

`68646719e50829286c8ce132a147f2376082a56ef5e496e87d0c0c6e0c6e55b7`

保持 `fixed-deepfilter-atten24-v1`：每个成功新建音色仍执行一次 DeepFilter atten24、构建一个 x-vector prompt，零探针、不绕过、不回退原音。新增 `reference_speaker_policy=warn-only-v1`，仅改变相对一致性下降时的处置，不改变降噪算法或试听生成算法。

原音质量、多说话人检查、降噪后基础质量检查仍然强制执行；真实不合格录音仍返回 422，DeepFilter 运行故障仍返回可重试 503。

## 本次修正的错误

14:51:26 中国区请求的原音和降噪后基础校验均通过，但分窗一致性从 0.7565 降至 0.6696，超过初始允许下降量 0.05，原逻辑因此返回 `VOICE_REFERENCE_DENOISE_REJECTED`。

这两个分数是各自音频内部、独立 VAD 选窗的最小相似度，并非对齐的前后身份相似度，不能单凭下降确认音色损坏。现在：

- 不再由这一相对条件抛出 422。
- 发出 `voice_denoise_reference_warning`，增加 `speaker_consistency_warnings`。
- 顶层 `reference_quality_warnings` 保存 `speaker_consistency_relative_drop`。
- `reference_speaker_guard` 保留真实统计及 `passed=false`，同时明确 `policy=warn-only-v1 / action=warn_only / blocking=false`。
- 继续用 DeepFilter 结果构建并发布 prompt，不改用原音。

原失败录音已经按现有隐私策略清理，无法原音重放。本次以日志中的准确分数组合做分支回归，确认警告记录和成功发布；不把该测试说成用户原音复听验证。

## 验证

- Linux 真实依赖环境：142/142 单测通过，包含 worker、基础音频质量、Nari/x-vector 契约、调度/取消、发布器和 smoke 验证工具。
- 分数 0.7565 → 0.6696 的回归：一次 DF、一次 prompt、成功落盘，告警计数 1、质量拒绝计数 0；返回和持久化警告一致。
- 无有效语音/真正的多说话人质量失败仍为 422，不发布 prompt；原音 diarization 拒绝仍发生在 DeepFilter 前。
- 隔离真实 Supervisor 停启演练通过，52.405 秒；确认 PID 停止返回码 7、status 返回码 3，独立测试 daemon 已退出。
- 两区发布前真实 DF/diarizer/xvector schema 预检通过。
- 发布后两区各 5 组创建与试听，共 10/10 次 HTTP 流程通过；使用生产中文试听文案和固定 seed。
- 每次核对返回、落盘 metadata、真实日志均为 DF applied=true / passes=1 / prompt_builds=1 / probe_count=0 / raw_fallback=false，告警策略及非阻断标记正确。
- 两区回滚预检均通过。本轮实际发布均成功，没有触发恢复或回滚；不将单 worker 切换描述为零停机。
- 未重放登录账号/手机界面；本轮验证边界是生产 worker HTTP 创建、文件发布、试听 WAV 与清理。

以下创建耗时单位为秒，包含 DeepFilter：

| 样本 | 中国区 | 国际区 | 状态 |
|---|---:|---:|---|
| 干净录音 | 5.103 | 3.332 | 两区创建/试听均 200 |
| 厨房 | 2.759 | 1.984 | 两区创建/试听均 200 |
| 洗衣机 | 3.116 | 1.878 | 两区创建/试听均 200 |
| 会议室 | 2.035 | 1.471 | 两区创建/试听均 200 |
| 4 秒短录音 | 1.621 | 1.046 | 两区创建/试听均 200 |

这是五个输入样本在两个区域的验证，不是十个不同录音，也不是主观音质胜率。五个固定样本均未触发下降警告，因此线上 warning 计数为 0；实际下降分支由上述针对性回归覆盖，未在生产伪造分数。

## 最终运行状态

两区均 healthy、voice_creation_enabled=true、queue_depth=0、active_voice_tasks=0、busy=false。运行文件和受保护文件哈希核验通过。

| 区域 | 新 worker PID | Nari PID（未变） | 普通 TTS PID（未变） |
|---|---:|---:|---:|
| 中国 | 60040 | 959622 | 129484 |
| 国际 | 126475 | 4136837 | 3746912 |

未更改 Web 控制面、客户端、Nari、普通 TTS、runner、凭据或已有用户音色；不需要更新 App。本次不重算旧 prompt/试听缓存。

## 发布与恢复

中国区 release：`/root/autodl-tmp/nari-staging/releases/fast-hotpath-fixed-deepfilter-20260903T070804Z-59782.json`

中国区 backup：`/root/autodl-tmp/nari-staging/backups/fixed-deepfilter-worker-20260903T070804Z-59782`

国际区 release：`/workspace/castreader-clone/releases/fast-hotpath-fixed-deepfilter-20260903T070933Z-126236.json`

国际区 backup：`/workspace/castreader-clone/backups/fixed-deepfilter-worker-20260903T070933Z-126236`

发布包：

- 中国：`/root/autodl-tmp/nari-staging/df-warning-verification.zTFFA2/bundle`
- 国际：`/workspace/castreader-clone/df-warning-verification.lUTj3u/bundle`

使用对应包内 `release-tool.py rollback --region cn|us --backup <上述精确备份>` 先验证，需执行时再加 `--execute`。这些新备份恢复到本次修正前的固定 DeepFilter v1，不是旧自适应管线。旧 mode 文件仍不能回滚。

## 清理

10 个测试音色及 staging 已删除，两区测试目录残留为 0；服务器上的 10 个输入副本及本机生成的短录音副本已删除。仓库原始样本和所有发布包、回滚备份保留，可重新生成测试输入；线上用户音色未删除。

完整证据见 [ROLLOUT.json](ROLLOUT.json)，操作说明见 [FIXED-DEEPFILTER-RELEASE.md](../../deploy/FIXED-DEEPFILTER-RELEASE.md)。
