> **本轮后端已部署完成**：国际区主网关 `33e49a94 / dpl_E3vhShktBut8yrPjXLViPqhp1zRt`，US入口 `us-tts-origin-proxy-20260907-v2`，旧版Direct入口 `1213fcd3`。最后组件于 2026-09-06 16:52:02.916 UTC 完成验证/排空；新24小时观察已开始。下方“发布前”“发布中”是执行过程的历史记录。iOS恢复仍需新App版本，不等同后端生效。

# 核心音频错误归因、恢复修复与发布

用户授权：继续归因错误，完成迭代和部署，并观察部署后的错误。本目录接续 9 月 6 日的原因调查与固定窗口监控，实施中；候选提交和构建不视为线上生效。

## 发布前事实

- Global 主网关仍为 `e8a755d4ea9602397cad138e6b3bbd3d91f7fa54` / `dpl_9fnjABFoGBgj2ni2KAgf59Pa2jRc`；US 稳定入口 rev2 / green，模型仍 R133。本轮尚未更新这些组件。
- 16:03:32 UTC 基线快照：客户端技术失败 9；Global 核心 504 为原 4 条；Direct 日志 504 由 3 增至 4。新 Direct 记录发生在 15:56:07.783 UTC，314 毫秒 AbortError，无法解释为 120 秒预算耗尽，具体取消来源和 HTTP 是否送达仍未证实。
- App Store 已发布现场错误来自 1.2.33 / build53。另一个发布任务的 **1.2.34 / build54 已包含 `09dcb64`、`814030a`，处于 WAITING_FOR_REVIEW**；不应继续笼统写成所有旧补丁都未进入送审包。
- b54 不包含 `47f9541` 的 Kindle 所有权修复，也不包含本轮播放器恢复。新 iOS 整合基于完整 b54 源码 `578bd91`，保留已送审 Kobo / Google Books 等改动，不能从脏的主工作树打包覆盖。
- Android `0663a5b` / `d6ab63b` 仍在独立修复工作树；其发行状态需要单独确认，不能用服务端上线代替手机升级。

## 本轮实施范围

1. Global 普通 TTS：保留已发布客户端 30 秒首响应约束内的 28 秒预算，补齐逐请求/尝试/阶段诊断及关联 ID，区分取消和超时；对确认无可用音频的成功响应增加同区有界恢复。现有 JSON/读体重试不能重复宣传为新功能。
2. US 稳定代理：仅在同槽位、完整 body 和影响响应的 headers 全部一致时合并正在进行的非流式合成；不缓存无人等待的结果，不合并不同音色/内容。资源上限退出合并而不是拒绝朗读。一个订阅者取消不能影响其他订阅者；最后一个取消释放上游。
3. iOS：从内存中的同一段音频重写文件和重建播放器，保留播放位置/队列/所有权；最终失败后阻止旧生成回调覆盖错误状态；使用允许的匿名机器错误码，并以实际播放时钟推进记录首音频。

各变更在干净独立工作树中实现，生产由主任务统一进行版本核验、候选验证、切换和回执。现有地区、音色、原文、会员/额度语义保留，时间戳与高亮不作为音频播放硬门槛。

当前 iOS 1.2.34 尚在审核，Apple 不允许创建下一 App Store 版本。发布技能规定不能未经授权撤回已有审核；先完成可审阅新产物与上传验证，再处理实际提交边界。后端上线不等待 Apple 审核。

## 证据

- [发布前累计快照](baseline-acceptance.json)
- [新增 Direct 错误原位脱敏详情](direct-recent-failures.json)
- [上一轮具体原因与缺口](../audio-errors-root-cause-20260906/README.md)

发布完成后将在此补齐实际部署 ID、提交、测试、切换时间及监控分段结果。原 24 小时窗口和历史失败保持可追溯，不把候选测试或旧版本数据算成新版本效果。

## 美国稳定入口已上线

- 生产版本 `us-tts-origin-proxy-20260907-v2`，源码提交 `21cad1b1823d28b9b7c257744dc0b1704403931a`，运行文件 SHA256 `0502fc2d9b3793be6309ae6f13ea544380404721857e55162b3eae060daa7eba`。
- 候选验证：两条并发请求、一次合成、返回字节一致；54,573 字节 MP3 完整解码，81,792 个采样，固定测试句尾覆盖。时间戳用于该固定探针尾部验证，不是生产播放闸门。
- 生产切换前两次 active=0；仅重启入口代理，旧请求排空，Kokoro blue/green 与两个克隆模型进程的 PID/startTicks 全部不变。停止到 ready 上界 0.748 秒；存在短暂新连接接受间隙，不能称为绝对零间断。
- 独立生产身份确认 `2026-09-06T16:36:52.292087Z`，公网健康回读为 v2 / revision2 / green / R133。旧版本身份已留在 releaseHistory，观察窗口保持原起止。
- [候选验证](us-proxy-validation.json)、[切换回执](us-proxy-apply.json)、[生产身份](us-proxy-status.json)、[公网健康回读](us-proxy-public-health.json)。

## 国际区主网关发布中

PR [28](https://github.com/scmyyan/readout-web/pull/28) 已合并为 `33e49a945e36940618457d5c33f8277652e7b92d`，完整保留已合并 PR27 的 Google Play 诊断及门禁。46 项 TTS 回归通过；执行既有生产发布流程 [34045884046](https://github.com/scmyyan/readout-web/actions/runs/34045884046)，上线前旧生产仍为 e8a755。不能将合并或候选构建标记为生产完成。

先前 workflow 34043509566 卡在过期 VERCEL_TOKEN、未部署。此次用现有已授权 CLI 登录经 stdin 更新已有 production secret，未转移 refreshToken 或扩大权限；仅留[脱敏回执](vercel-credential-handoff.json)。

## Direct 候选已验证

最小错误来源修复提交 `1213fcd3f9f616e92e9fd3a8f1e817b5095986c5`，17 个测试通过，包括真实 socket 在首响应前/读体中关闭、真实计时器到期、未知上游 Abort、上传中断。连接断开只记事实与匿名请求键，不再尝试向已关闭连接返回 504；没有本地期限证据的上游 Abort 按上游失败处理，不伪装成功，也不认定是用户主动取消。

旧入口 fresh baseline / candidate 已验证，stream 省略、true、false 三种旧契约都返回完整可解码音频且采样数一致。原配置与回滚产物已在既有同区私有存储完成写入及下载校验。生产切换与最终回执见[Direct 发布目录](../audio-errors-root-cause-20260906/direct-gateway-release-20260907/README.md)。

采集器已兼容匿名 requestKey / no_response / abortSource，继续保留旧日志中的 timeout_or_abort 和历史四条504，不通过改口径删除历史失败。

## 本轮完成与后续观察

- Global：完整生产流程成功，候选和生产均做完整音频、克隆/礼物端到端及区域/鉴权检查；实际生产版本已[独立回读](global-identity-readback.json)。[工作流步骤结果](global-workflow-result.json)。
- Direct：同区备份、候选三种契约完整解码、旧请求排空、永久实例验证、原路由精确恢复、候选排空退出、上线产物私有备份均完成。解读与Caddy进程保持原PID；模型未修改。
- 新观察窗口为 **北京时间9月7日00:52:02至9月8日00:52:02**，自动化24每小时只读采集。旧窗口保持到原北京时间9月7日13:01:25并单独归档。旧失败不清零；新版本单独统计。
- 首份新窗口样本只有196秒：Direct 9条请求全部记为200，无断开记录；两区已有供给采集未见失败，Global核心5xx为0。该短窗未收到原生客户端start事件，因此只可写继续观察，不能写持续播放验收通过。
- 美国代理从独立确认至16:55:17 UTC的18分钟窗口：1,182个请求，其中1,181个已完整响应200、1个窗口末仍未结束，未记失败/取消；完成耗时p95 2,807ms。没有并发相同请求合并样本（joined=0），来源未逐条归因，不能称全部是真实用户或据此证明端到端播放。
- 最新数据与边界见 [监控快照](monitoring/latest-acceptance.json)、[US阶段证据](monitoring/proxy-first-window.json)。

## iOS 修复包已经上传，尚未替换当前商店版本

完整发布分支基于1.2.34全部改动，恢复修复 `a8954ca`（原 `b0b9dc1`），Kindle所有权 `20bc640`（原 `47f9541`），归档源码 `b234463`，证据提交 `fe2c3f7`。

1.2.35/build55 已上传并经 Apple 确认为 VALID / APP_STORE_ELIGIBLE，build ID `e275d303-958c-430d-8fc8-39a6b4c35c10`。40个受影响单元测试与1个阅读模式切换UI测试通过，Release归档/签名/无测试书架和源文件哈希审计通过。

目前1.2.34/build54仍在WAITING_FOR_REVIEW，阻挡下一版本送审。主任务已向用户请求撤回旧审核、改送修复版的明确授权；在收到前保持原审核。上传VALID并非商店用户已升级。更丰富的48条本地播放器诊断也不是完整远端遥测；远端只有固定安全NSError分类，首音频口径需按build区分。

[上传与证据报告](/Users/xuxuheng/Documents/.worktrees/CastReader-ios-audio-recovery-release-1.2.35/docs/iOS-1.2.35-Upload-Report.md)。

## 17:05 UTC 累计新增三条的时间归因

原窗口客户端累计由9增至12。新增三条都在本轮全部部署之前发生并上报：16:04:04.923、16:04:17.983、16:13:12.965 UTC。均为同一匿名设备的 Android1.0.45/build52，Global网页朗读，固定分类 tts_failed / generation_failed。英文、西语及继续播放会话此前有首音频事件；终止时累计播放44、0、48秒。

当前旧日志未携带请求/trace关联和底层HTTP错误，不能把这些客户端事件直接等同模型超时、或与同窗Direct400强行合并。它们属于刚查到的部署前故障，不是新部署产生的三条回归。[事件与会话证据](monitoring/new-failures-1705/client-delta.json)。历史Global4条和Direct4条504没有增加。

## 发布证据一致性闭合

旧Global路由登记引用的是v1二进制的证明文件，不应当作永久入口版本沿用。已冻结v2完整回执 `493ae5a2…2051c1`，更正发布常量和production workflow的两项非密钥环境配置；只允许精确旧v1/revision1经既有CAS更新。代理URL/node/模型不变，不添加发布入口。

PR [29](https://github.com/scmyyan/readout-web/pull/29) 已把这些修正和线上Direct源码合并至 `1f9a483c7f75c9acee30129c984ea9bc622c5ea1`，执行既有维护流程 [34047976980](https://github.com/scmyyan/readout-web/actions/runs/34047976980)；完成后还会回读最终版本和路由证据。此前已上线的音频修复保持工作。
