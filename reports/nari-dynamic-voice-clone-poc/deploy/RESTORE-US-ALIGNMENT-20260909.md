# 国际区克隆时间戳 V3 部署与恢复

## 范围

按用户最新指令，停止手机、合成、扩展回归，仅部署与中国区同版的
`qwen-pcm-measured-groups-v3`。上线检查仅限源码/模型完整性、依赖导入、启动预热、
健康状态、只读路由和备份回读；不把这些检查描述为新的端到端精度或性能评测。

- GPU：`castreader-us4090` / `4d2605786b7c`。
- Release：`/workspace/castreader-alignment/releases/20260909-qwen-pcm-v3-r2`。
- 独立 Supervisor：`castreader-clone-alignment`，loopback `18891`。
- 国际原 Worker 保持 `127.0.0.1:8890`，原 Nari、clone、Kokoro 均不重启。
- 原 TLS 入口 `https://71.175.237.103:41221` 映射 GPU `8888`；只切换
  `/v1/captioned-speech` 到 `18891`，其他路径继续 `8890`。
- 原 Vercel/国际后端地址、鉴权、用户音色、计费与客户端不修改。

`r2` 只是启动配置修正，管线仍为 V3：Supervisor 排在原 Worker 后启动，启动脚本等待
原 Worker 与 Nari ready，避免整机重启时独立对齐进程抢先启动而进入 FATAL。
原 r1 release 和备份保留；不改变任何时间戳算法或模型参数。

中国 V3 release 的 `caption_pipeline.py`、`alignment_contract.py`、
`request_coalescer.py` 逐字节复用。`alignment_gateway.py` 唯一区别是将美国原 Worker
的 loopback `8890` 加入固定 allowlist；这是区域连接配置，不改变对齐、编码、
异常处理、任务合并或调度参数。仍要求启动前至少 6 GiB 空闲显存，启动后至少 4 GiB。

Qwen 模型 revision：`c7cbfc2048c462b0d63a45797104fc9db3ad62b7`。
权重 SHA-256：`47831d0e82f96b20e9034dba01a075ee06436654719f6a68289e49f1b65ce0e7`。
直接复用美国节点已存在的同 revision 权重，没有向 Mac 下载模型。
对齐依赖 overlay 从中国节点复制到美国独立 venv；只将 `base-runtime.pth` 改为
`/workspace/nari-qwen3-tts-clean/venv/lib/python3.12/site-packages`，不修改原 Worker venv。

## 私有恢复集

COS bucket `castreader-voice-1323065328`，region `ap-shanghai`，前缀
`runtime-backups/20260904/alignment-20260908/`。

1. 共享 `clone-and-alignment-runtime.tar.gz`，SHA-256
   `23c3372892d3eafdbfe0fe1b3cb814437171804bc1aa7782254341f3d15b02d9`，包含
   Qwen/Nari 模型、原运行时资产及对齐 overlay；不重复上传相同大模型。
2. `us-v3-pre-compact-20260909.tar.gz`：修改前美国 clone 源码、完整声音/TLS 资产、
   私有 token、精确启动/Supervisor/TLS 路由、原 Nari 源码、依赖锁定与模型 SHA 清单。
   SHA-256：`3b5b658b8f11f1ec18ee4a0a1fdad13249167fa9027050750acbf92151316263`。
   美国质量/降噪 41 个文件与共享中国恢复集逐文件 SHA 相同，全部复用共享资产，
   对照清单为 `shared-regional-assets.sha256`。不重复跨区传输相同的 113 MiB 资产。
3. `us-v3-candidate-20260909.tar.gz`：完整 V3 release、区域配置、依赖清单、
   部署脚本、模型/overlay 清单及共享/修改前回执。
4. `us-v3-post-20260909.tar.gz`：切换时间、健康/路由证据、进程/源码/模型状态及前置回执。
5. `us-v3-candidate-r2-20260909.tar.gz`：包含完整 r2 release 与 r1/pre/shared 回执，
   是当前恢复目标；不需要在新机器手动重放代码补丁。

每个对象使用上传后的完整下载 SHA-256 验证，回执自身也上传并完整回读。
精确大小、哈希、对象键以对应 `.receipt.json` 为准，所有对象必须保持私有。
只在修改前与 candidate 回执通过后启动/切换；旧配置和声音不删除。

## 恢复顺序

在新空目录验证所有归档，不覆盖活跃 release。共享模型归档中中国路径
`nari-staging/model-0.6b-base` 映射美国 `/workspace/qwen3-tts-base/model-0.6b-base`，
对齐模型映射 `/workspace/castreader-alignment/model`，逐文件核对美国 pre 的模型清单。
美国 pre 中 `nari-source.tar.gz`、启动文件和 `requirements-clone-base.txt` 用于重建
`/workspace/nari-qwen3-tts-clean`；将共享中国 `nari-staging/quality` 与 `denoise` 恢复到
美国 clone 根目录，再逐项校验 `shared-regional-assets.sha256`。
`clone-regional-runtime.tar.gz` 恢复美国自己的 `/workspace/castreader-clone`，
不得用中国音色或 token 覆盖美国资产。

恢复原 Nari/clone 后，重建 Python 3.12 对齐 venv、恢复共享 overlay 和上述美国 `.pth`，
核对 candidate 的 `requirements-runtime.txt`、模型与源码 SHA，再安装独立 Supervisor。
对齐 health ready 后，验证 Caddy 配置，只重启 `castreader-clone-tls` 切路径；
`/health` 仍返回原 Worker 健康，caption 路由返回 V3 revision 头。

## 回滚

先将 pre 的 `Caddyfile.clone-tls` 原子恢复至
`/workspace/castreader-clone/deploy/Caddyfile.clone-tls`，验证配置后仅重启
`castreader-clone-tls`。确认原 Worker 健康与原路径恢复后停止独立
`castreader-clone-alignment`。不要重启 Nari/Kokoro/clone，不要改变普通 TTS 蓝绿配置。
保留 V3 release、备份与回执，便于定位；不要在故障恢复中删除声音或模型。
