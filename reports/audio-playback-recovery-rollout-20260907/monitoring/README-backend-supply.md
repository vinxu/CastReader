# 仅后端补充观察

`collect_backend_supply.py` 从现有中国/美国控制主机和美国 GPU 读取 QuickRead 日志、持久化任务状态、固定健康端点、中国 TTS access log 及美国克隆结构化日志。不做合成、不重启、不改生产文件、不查客户端事件。它补充已有验收采集，不替代原始验收文件或固定 24 小时窗口。

调用时显式传入原最终窗口起点、本轮固定截止和上一轮固定截止；输出到未使用的目录：

```sh
python3 -B reports/audio-playback-recovery-rollout-20260907/monitoring/collect_backend_supply.py \
  --start-utc '<原最终窗口起点>' \
  --end-utc '<本轮截止>' \
  --incremental-start-utc '<上一轮截止>' \
  --output-dir '<本轮新目录>/backend-supply'
```

远端脚本经 SSH stdin 执行；仅带固定路径、时间、白名单标签，不在生产写脚本。脚本不输出日志消息、正文、job/voice 身份、音频或凭据。美国 GPU 的操作指南必须先按实例要求读取。三个来源独立，单一来源采集失败会独立保留，不填零或视为成功。

判读约束：

- QuickRead 持久化任务没有可靠的显式创建时间，按文件修改时间形成记录集合；不能将它称为新任务量或 HTTP 请求分母。
- `request_disconnected` 必须按静态错误消息 SHA 和运行源码判断，既不能当作模型报错，也不能假定是用户主动取消。
- 当前 health 的累计计数只覆盖当前进程启动以来；必须与上次及进程身份对比。不能用 0 个窗口样本宣称 100% 成功。
- 全部讲解块 ready 不证明后续 TTS 已交付；音频 200 也不证明用户完整播放。
- US clone 无窗口结构化事件、CN clone 只有健康累计计数时，标证据不足。
- 整体 backendVerdict 与原 automaticVerdict 分开，保留旧故障，不将客户端、博客及支付记录重新混入后端告警。

20260906T2353Z 的辅助采集初版因 journal 时间格式及任务 created_at 缺失而修正；该轮以 `*-backend-supply-v2.json` 为准。两区 QuickRead server hash 与发布预检回执一致；request lifecycle hash 与已审阅源码一致。后续如变更，报告差异，不自动更新预期版本。

20260907T0053Z 代理详细记录回读多次超过本地 SSH 截止。独立分阶段读取显示，身份验证与原窗口 64 MiB 扫描约 2.5 秒即可完成；开启 SSH 压缩后，原窗口全量匿名请求在 36.346 秒回读完成。现有 `collect_proxy_events.py` 只增加 `ssh -C`，保留原 60 秒截止、身份预期、扫描预算、脱敏和关联规则。该调整仅影响本地观察数据传输，没有变更生产音频服务或路由；未将采集超时计作 TTS 超时。
