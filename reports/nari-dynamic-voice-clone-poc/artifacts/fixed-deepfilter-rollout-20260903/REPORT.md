# 固定 DeepFilter 生产发布记录

完成时间：2026-09-03 13:13:52 CST（05:13:52 UTC）。

## 最终结果

中国区和国际区已实际部署同一份 worker。每个成功新建的音色固定执行一次 DeepFilter atten24，再构建一个 x-vector prompt；不再按噪音分类绕过、不选择 atten100、不生成对比探针，也不回退原音。

两区各 5 组真实 HTTP「创建 → 校验返回和落盘 metadata → 试听 → 清理」均通过，共 **10/10 次**。这表示 5 个输入样本在两区测试，不是 10 个不同声音，也不是主观音质胜率。最后回读均为 healthy、voice_creation_enabled=true、queue_depth=0、busy=false、active_voice_tasks=0。

两次国际区发布尝试曾因发布器错误短暂停止 worker，已恢复并修正，见下文；不能将本次过程描述为零停机或无事故。

## 唯一管线

录音输入校验及单说话人检查 → DeepFilter atten24 → 降噪后质量/说话人窗口一致性校验 → 单个 x-vector prompt → 创建成功。

- 无效原音/降噪后质量不合格：422，提示重录，不发布 prompt。
- DeepFilter 或依赖运行故障：可重试 503 `VOICE_DENOISE_UNAVAILABLE`，不回退原音。
- CampPlus 保护比较的是同一录音分窗的一致性下降，不是身份正确性的绝对保证；短录音缺乏可比窗口时记录为不可比，不因此一律拒绝。
- 降噪创建依赖异常不关闭既有音色播放健康状态。
- 历史字段名 `adaptive_denoise` 仅为 API/审计兼容保留。mode/canary 设置已不参与策略；旧 mode 文件设为 off 不能回滚。
- 已有音色 prompt、已有试听缓存没有重算。用户需要重新录制并创建音色，才能评价新管线。

## 版本与边界

- Worker SHA-256：`9be8893828c8f559f94c9548c9b479108bd71b8760fd2db081463b13037d40e3`。
- adaptive_denoise.py SHA-256：`1ddacd73ddcd3c9a175d302795f6f50da318fba13d1c63faadd64ff3f742695a`。
- 策略版本：`fixed-deepfilter-atten24-v1`。
- DeepFilter 0.5.6 SHA-256：`70775e251eee44c0f2451a1e833326cf8bcbbe304d3e7cd12851e6fce72ef7da`。
- 中国区源码提交：`08a34a4d1cad42ac1c8dceb52fc9dbb65c96104f`。
- 国际区源码提交：`7fcc6e1bb5692761a9ecd8271a6bb05cdf9669fe`。与中国区相比只修正发布工具，两份实际 worker 字节完全相同。
- 只替换 clone_worker.py、adaptive_denoise.py 并重新绑定 writer marker；未部署 Web、客户端、Nari、普通 TTS、runner 或凭据。
- Nari/TTS 源码、保护文件哈希和进程核验通过。CN：Nari PID 959622、TTS PID 129484；US：Nari PID 4136837、TTS PID 3746912，均未重启。
- 当前 worker PID：CN 8744；US 71990。
- 现有 Web 422/503 转发、成功响应、iOS 错误映射经只读兼容检查；未更改控制面。公开建声入口无凭据请求两区均返回 401。没有用用户登录态重放手机/Web 全链路，不能将 loopback 测试说成账号层端到端测试。

## 创建与试听实测

以下时间单位均为秒，创建耗时包含降噪。固定使用生产中文试听文案及 seed 20260825；输出均验证为 24 kHz、单声道、PCM16、非空非近静音 WAV。

| 样本 | 中国创建 | 中国 DF | 国际创建 | 国际 DF | 创建 / 试听状态 |
|---|---:|---:|---:|---:|---|
| 干净录音 | 5.216 | 2.140 | 3.264 | 1.256 | 两区均 200 / 200 |
| 厨房 | 3.038 | 2.341 | 1.913 | 1.331 | 两区均 200 / 200 |
| 洗衣机 | 2.842 | 2.067 | 1.903 | 1.331 | 两区均 200 / 200 |
| 会议室 | 2.325 | 1.788 | 1.402 | 1.030 | 两区均 200 / 200 |
| 4 秒短录音 | 1.429 | 1.059 | 1.037 | 0.753 | 两区均 200 / 200 |

每次均从返回值、落盘 metadata 和 `voice_denoise_selected` 日志交叉核实：selected=atten24、deepfilter_applied=true、deepfilter_passes=1、prompt_builds=1、probe_count=0、raw_fallback=false。每区 created_atten24=5，其余新管线失败/质量拒绝计数为 0；这是新进程计数，包含测试且删除后不递减，不是历史用户数。

## 回归测试

- 真实 Linux 依赖环境 worker 回归：97/97 通过（含 smoke 工具 6 项测试）。
- 发布工具最终单测：38/38 通过。
- DeepFilter/说话人参考音频预检：干净、厨房、洗衣机、会议室、食堂、4 秒短录音共 6/6 通过；不创建生产音色。
- 发布前两区实际运行 DeepFilter，并验证 diarizer 与 xvector_v1 writer 绑定。
- 国际服务器隔离的真实 Supervisor 生命周期测试：通过，52.079 秒；真实停止、自动拉起竞争抑制、STOPPED/PID 0 读取、显式重新启动均通过。独立 daemon 和测试 child 已退出；未操作生产 daemon。
- 两区发布后回滚预检均返回 rollback_ready=true。未为了测试回滚而再次停止生产服务。

## 国际发布过程中的两次中断

根因是发布器对 Supervisor 返回码的处理及测试不足，不是 DeepFilter 算法或客户端协议。首次把所有非零退出码当失败；第一次修正又把 `status` 和 `pid` 两条命令的不同常量混同。服务器实际结果：

- `supervisorctl status castreader-clone` 在 STOPPED 时返回 3。
- `supervisorctl pid castreader-clone` 在 STOPPED 时输出 0，返回 7。

这导致 worker 已安全停止但文件尚未替换时工具中断，自动恢复也被同一 PID 读取错误阻断。两次都先验证原 source 和原 writer marker 哈希仍完整，再显式启动原 worker 恢复。

| 尝试 | worker 停止（CST） | 原 worker 重新启动 | Supervisor 确认 RUNNING |
|---|---|---|---|
| 第一次 | 13:01:26.694 | 13:02:09.318 | 13:02:35.031 |
| 第二次 | 13:05:21.943 | 13:05:48.087 | 13:06:13.351 |

RUNNING 确认包含 Supervisor 的 25 秒 startsecs，不是精确 HTTP 中断时长；上述窗口约 69 秒及 51 秒。未逐条核对窗口内真实用户请求，不能断言没有用户受影响。Nari 和普通 TTS 在两个窗口均保持原进程。

最终修正直接核对实际 CLI 输出和已安装 Supervisor 源码常量，只接受 PID 0 / rc 7；新增真实值单测、保留不泄露凭据的错误链，再经隔离真实停启演练后，第三次发布成功。该真实生命周期演练应作为后续国际 worker 发布前的回归步骤。

## 发布记录、备份与恢复

中国区：

- release：`/root/autodl-tmp/nari-staging/releases/fast-hotpath-fixed-deepfilter-20260903T045956Z-8485.json`
- backup：`/root/autodl-tmp/nari-staging/backups/fixed-deepfilter-worker-20260903T045956Z-8485`
- bundle：`/root/autodl-tmp/nari-staging/fixed-df-verification.vG9B1S/bundle`

国际区：

- release：`/workspace/castreader-clone/releases/fast-hotpath-fixed-deepfilter-20260903T051120Z-71772.json`
- backup：`/workspace/castreader-clone/backups/fixed-deepfilter-worker-20260903T051120Z-71772`
- bundle：`/workspace/castreader-clone/fixed-df-verification.Mu4MV5/bundle-v3`

回滚使用对应 bundle 的 `release-tool.py rollback --region cn|us --backup <上述精确路径>`，默认只验证；确认回滚需要再加 `--execute`。保留所有不可变发布记录和精确备份。旧版 mode 文件不能撤销固定 DeepFilter 策略。

## 清理与已知边界

- 10 个本次生成的测试音色及 staging 目录已删除，无 vc_smokedf_* / vc_tmpdn_* 残留；用户已有音色未动。
- 服务器上的 11 个 canary 输入副本已删除；仓库原始测试输入保留，可重新上传复现。
- 本任务的临时 prod.env、试听复现音频和两张分析图已删除；这些临时副本不可恢复。生产用户音频、音色和发布备份未删除。
- 删除测试音色不会强制重启 Nari；其不可通过 worker 访问的测试 embedding 可暂留有界 LRU，随正常缓存淘汰。
- 这次功能验收不等于主观噪音改善已被盲听证实；旧自适应管线的 11/12 结果不适用于固定 atten24。
- 未修改 Nari 解码或额外加入开头噪音补丁。开头 1–2 秒的感知问题需用新建音色再听；不能保证所有环境音、背景说话声均被消除。

机器可读证据见 [ROLLOUT.json](ROLLOUT.json)。操作说明见 [固定管线发布说明](../../deploy/FIXED-DEEPFILTER-RELEASE.md)。
