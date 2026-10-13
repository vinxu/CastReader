# 克隆时间戳 V3：中美部署完成

## 最终状态

- 国际克隆入口于 **2026-09-08 17:13:02 UTC** 切至 `qwen-pcm-measured-groups-v3`。
- **17:18:54 UTC** 完成启动配置修正，最终 release 为
  `/workspace/castreader-alignment/releases/20260909-qwen-pcm-v3-r2`。
  `r2` 是部署包装编号，时间戳管线仍为 V3，没有更换算法或模型。
- 中国既有生产服务仍为 `qwen-pcm-measured-groups-v3`，本轮没有再次修改中国服务。
- 按用户最新要求，停止后没有继续手机播放、合成、付费 API、扩展或精度/延迟回归。
  仅进行了部署必需的备份、依赖导入、启动预热、健康与只读路由检查。

## 一致性与接入

国际直接复用中国 V3 的 `caption_pipeline.py`、`alignment_contract.py`、
`request_coalescer.py`，三份文件逐字节一致。`alignment_gateway.py` 仅增加美国原 Worker
loopback `8890` 的固定 allowlist 配置；原中国 `18890` 仍被允许。

因此标点规范化、实测词组、零时长词声学保护、异常保留音频但不给不可信时间戳、
MP3 编码与对齐重叠、请求去重逻辑全部同版。不恢复旧的按文字长度估算。
中/日/韩原有段级模式与调用方关闭 timestamps 的行为也保持一致，
不能将这次部署解释为新增中文逐词对齐证明。

Qwen revision 为 `c7cbfc2048c462b0d63a45797104fc9db3ad62b7`，
权重 SHA-256 为 `47831d0e82f96b20e9034dba01a075ee06436654719f6a68289e49f1b65ce0e7`。
美国已经存在该模型，未向 Mac 下载模型；仅复制独立依赖 overlay 并适配本机基础 venv 路径。
原 Worker 的依赖环境、模型、用户声音和源码没有修改。

国际后端原 TLS 入口 `https://71.175.237.103:41221` 不变：

- `/v1/captioned-speech` → GPU loopback `18891` → 新 V3 对齐服务。
- 新服务合成仍调用原 Worker `127.0.0.1:8890/v1/speech`。
- 其余路径继续原 Worker，包括音色创建、删除、prompt 和 WAV。
- 没有重新发布 Vercel/Next、修改计费、改变账户或再安装 iOS。

## 上线核验

独立服务 health 返回 `status=ready`、`pipeline_revision=qwen-pcm-measured-groups-v3`。
公网 TLS caption 路径的只读 HEAD 返回预期的 `405 / Allow: POST`，并带 V3 revision 头；
这只证明方法与路径路由，不冒充真实合成成功或声学精度测试。
原 Worker health 为 healthy，Nari ready，最终 Supervisor 配置与 release 逐字节一致。

最终进程：alignment `2403911`，clone `568834`，Nari `4136837`，Kokoro green `507638`，
clone TLS `2396493`。本轮没有重启 clone、Nari 或 Kokoro，也没有修改普通 TTS 蓝绿配置。
最终快照空闲显存 **7,717 MiB**；启动前 6 GiB 与上线后 4 GiB 安全线没有放宽。

Supervisor 排在原 Worker 后启动，脚本等待原 Worker/Nari ready；这避免整机启动时
对齐服务抢先运行并因依赖未就绪进入 FATAL。没有为验证重启机器或原 GPU 模型。

## 备份与证据

共享完整模型/质量/降噪资产沿用已经完整回读验证的私有 COS 恢复集。
美国质量/降噪 41 个文件与共享集全部同 SHA，新的区域完整恢复差量仅约 1.5 MB。
美国自己的声音、token、TLS、源码及配置独立备份，绝不使用中国账号或音色替换。

修改前、完整候选 r1/r2、上线后归档及回执自身均执行私有上传与完整下载 SHA-256 核验。
恢复步骤、对象键、原服务回滚见 `../deploy/RESTORE-US-ALIGNMENT-20260909.md`。
本地证据：`build/alignment-pipeline-20260909/us-v3-release/`。

本轮不新增精度/性能数字。既有中国 GPU 与真实手机音频证据仍见
`RESULTS-CN-LIVE-20260908.md`；不能把只读上线检查称为新的完整端到端验收。
