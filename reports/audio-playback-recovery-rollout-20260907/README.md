# 核心音频错误归因、修复与部署

Global 主网关、旧版 Direct 网关和美国稳定代理已部署。美国模型 R134 已于2026-09-06 18:34:44.148939 UTC切入生产，18:37:52.522573 UTC独立确认通过，开始最终版本24小时观察。CN本次模型补丁未部署。iOS 恢复包已上传并获 Apple VALID，尚未替换商店版本；上传不视为商店生效。

## 错误原因与证据边界

| 现象 | 确证原因与边界 | 处理状态 |
| --- | --- | --- |
| 3条模型/Direct HTTP400 | 三个匿名请求键的 R133 complete_audio_failed 均指向 generate_audio:595：没有生成音频且旧可读内容 guard 为 false 时，该行抛出 no_speakable_content；随后模型和Direct以相同键记录400，生成层已精确确认为模型。历史正文未读取，不能断言具体字符、语言或音色。 | R134已在US生产生效，明确句读/空白可正常完成并推进后文；CN未部署。 |
| 原4条Global504 | 约28秒应用预算到期；Vercel hasFunctionCrashed=false，并非已证实函数崩溃。附近有大量相同文本前缀请求，不能据此认定完整请求全部重复或精确GPU排队。 | 保持旧客户端预算，补逐尝试诊断、同区有界恢复、完全相同的在途请求合成复用；已部署。 |
| 原4条Direct504 | 旧代码将下游断开与上游期限共用Abort，笼统记504；实际297–1006毫秒结束，不能解释为120秒预算耗尽。旧日志不能证明取消来源或504是否送达用户。 | 区分连接断开、本地超时和未知上游失败，关闭的连接不再写504；已部署。 |
| iOS恢复失效 | 可复现缺陷是复用失败播放器，或旧生成回调覆盖终止状态。历史播放器错误没有底层NSError，初始诱因仍未证实。另有Kindle所有权修复。 | 同一音频重建播放器、保留位置和队列、使旧回调失效；build55已上传VALID，尚未商店发布。 |

累计客户端技术失败9增至12的三条，发生于2026-09-06 16:04:04.923、16:04:17.983、16:13:12.965 UTC，均在本轮后端切换之前发生并上报，来自同一匿名Android1.0.45/build52设备。它们与三个Direct400相差15–27毫秒，是强时间关联；客户端没有远端请求键，不能声称已逐条精确贯通客户端到模型。

三个模型请求各以约2毫秒记录400，结合精确请求键、堆栈行号和固定源码可确认失败分支，不能解释为模型超时。普通文本日志仅覆盖第三个时间窗，而且同秒存在多个并发请求；相邻无请求键的 textChars=1、语言或音色都没有归属到这三个请求。旧 guard 为 false 的范围比新恢复白名单更宽，原始输入未知，因此不能宣称已重现或保证修复全部三条历史输入。

中国区现网 r131b 的 tts_service.py 与development router源码SHA与US R133相同，存在同一个静态风险；本次只读检查未证明中国区实际发生同事故。CN仍未部署本次模型补丁，不能将US候选验证写作两区修复生效。

[三条新增故障详细归因](monitoring/new-failures-1705/README.md) · [模型原位脱敏堆栈](monitoring/new-failures-1705/model400-windows.json) · [中国区静态证据](monitoring/new-failures-1705/cn-static-path.json) · [前期调查](../audio-errors-root-cause-20260906/README.md)

## 已核验生产版本

| 组件 | 实际版本 | 独立确认时间（UTC） |
| --- | --- | --- |
| Global主网关 | 1f9a483c7f75c9acee30129c984ea9bc622c5ea1 / dpl_EYb2UAVcLJvk7qaYchgmPhYoHYC5 | 2026-09-06 17:26:40.829 |
| Direct旧入口 | 1213fcd3f9f616e92e9fd3a8f1e817b5095986c5；运行SHA 2ca971e8…282d | 16:52:02.916，永久实例验证及候选排空完成 |
| 美国稳定代理 | us-tts-origin-proxy-20260907-v2；源码21cad1b1823d28b9b7c257744dc0b1704403931a；内部revision6、当前blue | 本次重启及模型路由独立确认18:37:52.522573 |
| 美国Kokoro | R134 / 5dddb1b9f96e431e76e4c3a8305e1a3fe3963c52；blue槽，服务源码SHA d6d1871a…d8682 | 切入18:34:44.148939；独立确认18:37:52.522573 |

Global注册已通过既有CAS从数据库revision1更新至revision2，仍指向同一个美国节点；proxy版本v2、证明文件SHA 493ae5a2309cb6a6fc65142a8756c019e6b4cdd40ad41a9edc972718162051c1。数据库revision与代理内部revision是独立序号。

Global网关源码经PR28、PR29合入现有beta发布链，完整生产维护流程成功，保留固定版本、候选验证、正式检查和回滚机制，没有新增Global发布入口。模型源码提交为5dddb1b9f96e431e76e4c3a8305e1a3fe3963c52，部署工具为e4f6beb；R134完整源码树、安装回执、进程/启动标识、监听、Supervisor、代理状态和回退green实例均经独立核对，20项全部通过。原R133 green实例保留。

[最终生产身份](global-final-identity.json) · [最终工作流](global-final-workflow-result.json) · [路由CAS与探针](global-final-artifacts/global-tts-routing-reconcile-34047976980-1/evidence.json) · [Direct发布回执](../audio-errors-root-cause-20260906/direct-gateway-release-20260907/README.md) · [代理切换回执](us-proxy-apply.json)

[R134生产切换](model-r134/route-blue-apply.json) · [最终模型与代理身份](model-r134/production-final-identity.json) · [20项独立核对](model-r134/production-final-status.json) · [冻结监控身份](model-r134/proxy-monitor-identity.json)

## 修复约束与验证

- 音频优先：时间戳缺失、高亮降级不拦截有效音频；会员和额度仍按业务规则执行。
- 内容完整：有限恢复保留原文、音色和余文；不以静音掩盖正文生成失败。
- 并发复用只限同槽位、完整body与影响响应headers相同的非流式请求；资源上限回到独立转发，一个订阅者取消不影响其他订阅者。
- 本轮请求、恢复和回滚均使用原地区，未增加中国区与国际区之间的回退；这些检查仍不足以证明项目全部链路无跨境。

Global 46项TTS回归、最终20项发布元数据回归通过；完整生产流程的鉴权、区域、音频、克隆与礼物端到端检查通过。Direct 17项回归通过，候选与永久实例均验证stream省略/true/false三种旧协议、完整MP3解码。代理26项测试通过，双请求只产生一次合成，返回54,573字节一致音频，完整解码81,792采样。

R134的43项本地模型测试通过，其中6种编码×3种stream设置×2种无声输入共36种组合能完整解码；正文、可读符号和未知字符不被当作静音。候选模型另通过6个无声/混合输入用例、9语言及1个重复数字用例。完整保留编码器尾部，短Opus最后一页也经验证。

公开入口校正后的验证为12/12通过：Global与Direct各覆盖stream省略/true/false、纯句读及混合文本；6个混合用例均完成3段并到达末词sunflower。首次公开验证失败记录保留，其原因是探针把可选的余文字段缺省当成错误；iOS将nil视为结束，Android可按text/timestamps推导，本次全部消费完成的固定样例允许该字段缺省。修正范围是探针的此项协议判断，不把任意缺省余文都判定为完整，也不抹去首次失败证据。

本次R134注册调整在代理active归零后维护，停止至ready的接入间隙上界为6.295秒，不能称绝对无间断；原green模型实例保留。Direct原发布保留解读与Caddy进程。R134生产恢复增量已在同区私有存储回读校验，`verified=true / public=false`，与已有完整基线恢复链配合使用。

[本地验证](model-r134/model-local-validation.json) · [模型候选验证](model-r134/model-validation.json) · [公开验证12/12](model-r134/public-audio-validation-corrected.json) · [保留的首次公开验证](model-r134/public-audio-validation.json) · [注册维护回执](model-r134/registry-apply.json) · [生产私有备份回读](model-r134/production-private-backup-readback.json)

## 部署后数据

R134独立确认后的首个约119秒窗口（18:37:52.522573–18:39:51.372598 UTC）有96条代理请求完整返回200，failure为0；运行身份和扫描覆盖均通过，窗口内无错误release/slot/revision事件。这只是短窗HTTP阶段证据，不是24小时验收或用户完整播放保证。

[R134代理首窗](monitoring/proxy-model-r134-first-window.json)

截至18:45:53.895 UTC，最终版本已观察481秒：汇总采集来源完整，technicalFailures与数据/覆盖缺口均为空，判定为observing。Direct有93条HTTP200，无4xx/5xx或no_response；Global核心5xx为0，另1条非音频503单列。iOS有1组朗读启动与首音频配对，首音频1,168毫秒，暂无技术失败；没有新的Android客户端启动队列，不能把旧Android持续请求替代启动样本。美国探针1轮、中国探针2轮均健康，地区不匹配0。仍缺24小时、解读/克隆及Web/扩展完整播放证据。

第一轮18:39汇总的只读SSH命令曾丢失JSON参数中的引号，导致模型/代理身份采集失败；原快照保留。只修改本地采集器的shell参数引用，真实shell字面值测试与单项生产只读验证通过，18:45全量重采恢复。独立代理采集始终正常，该采集错误不列为生产音频故障。

[最终版本首份完整汇总](monitoring/final-model-first-summary.json) · [18:45原始快照](monitoring/observations/20260906T1845Z/latest-acceptance.json) · [采集传参修复验证](model-r134/collector-remote-args-validation.json) · [观察自动化回读](monitoring/automation-final-readback.json)


此前18:16:39.996 UTC中间版本快照覆盖16:52:02之后约85分钟，包含两个Global版本区间，不包含R134修复：

- 原生端100条生产标记事件、9个匿名设备；21次朗读启动（iOS9、Android12）均有同会话首音频，技术失败0。生产标记不能排除人工测试，首音频不能证明整本读完。
- Direct 1,254条HTTP200，HTTP4xx/5xx为0；另3次连接在等待上游响应头时关闭，单列no_response/downstream_closed。其中Android1.0.45为1,253条200加1次351毫秒断开，另外2次断开来自1.0.46。未返回HTTP响应的记录不算HTTP成功、HTTP失败、模型超时或用户主动取消，断开原因及用户实际结果仍未知。
- Global核心5xx为0，3条其他项目503另列。两区既有供给探针各16轮健康，所覆盖请求余文完整、地区不匹配0。
- 两次解读被额度限制，归业务阻断。本窗没有解读首输出、克隆原生首输出或Web/扩展完整播放证据，仍需继续观察。

原18:16快照曾因Android1.0.45专项将1条no_response计作非2xx而自动fail，原文件保留不修改。监控已将实际HTTP非2xx与无HTTP响应分开：断开保留独立提示，未知结果不补写为成功；若只有断开，则不满足HTTP样本要求。按修正口径对原证据内存重评为observing，技术失败项为0。新增3项回归在内的31项监控测试通过，真实400/504与断开并存时仍为fail，未放宽真实HTTP错误。

早期Global阶段窗口另有812条完整响应，通过匿名请求键和attempt全部精确关联美国代理；该数字不是812个用户或812次完整播放。

[18:16原始快照（保留旧判定）](monitoring/observations/20260906T1816Z/acceptance.json) · [监控口径说明](../backend-audio-iteration-20260906/monitoring/README.md) · [阶段关联摘要](monitoring/vercel-proxy-first-summary.json) · [最新验收](monitoring/latest-acceptance.json)

18:49 UTC例行回读另发现一条此前未报告的Direct502，发生于18:33:29代理维护停止/重启间隙，最终R134观察起点之前。旧窗口Direct5xx从4增至5，不能被新窗口零失败抵消。已单独归因并通知；新窗口截至18:49仍为observing。[本轮502调查与证据边界](monitoring/observations/20260906T1849Z/README.md)

19:49 UTC观察在最终R134窗口内发现两条新的 Android 1.0.46/build53 PDF朗读失败，累计播放115秒后失败，下一次恢复19毫秒即失败，随后恢复并累计播放1,894秒。同期后端HTTP阶段未捕获对应失败，但缺少客户端底层异常及请求关联，不能确定根因或声称已修好。本轮仅定位，没有新增修复部署；原窗口历史错误继续保留，最终窗口验收为fail。[本轮详细证据](monitoring/observations/20260906T1949Z/README.md)

21:51 UTC观察新增一条Android1.0.46 PDF解读失败：首块39.719秒，另启朗读后旧解读会话晚报failed，随后朗读仍有600秒里程碑。冻结源码确认切回Read未取消旧Explain Job/session且晚到错误缺少状态门控，但尚无该事件底层异常或请求关联，不能改判为取消或已修好。另22条504精确归属博客页面300秒函数超时，与音频API错误分开。本轮只读，未新增修复部署；最终窗客户端累计3条失败、旧窗15条。[本轮详细归因](monitoring/observations/20260906T2151Z/README.md)

22:52 UTC观察新增iOS1.2.33 Kindle翻页失败，累计播放2,377秒后报告navigation/page_turn_failed；同内容后续重新开始并达到1,800秒里程碑，不能证明原失败页自动恢复。现场导航异常和派发证据仍缺失，本轮未修改或部署。最终窗客户端累计4条失败、旧窗16条；后端核心HTTP错误无新增，另31条代理attempt1完成记录未匹配固定Global返回集合，反向归属不完整。[本轮证据](monitoring/observations/20260906T2252Z/README.md)

## 观察与iOS发布边界

自动化24每小时只读采集。最终版本正式观察窗口为 **2026-09-06T18:37:52.522573Z → 2026-09-07T18:37:52.522573Z**，起点采用独立生产确认时间。旧05:01:25窗口以及原16:52:02.916356窗口均保留，历史错误不清零；中间版本原state/latest/通知状态已归档至 `monitoring/observations/interim-before-r134/`。首窗正常不代表已完成24小时观察。

[中间窗口归档记录](monitoring/observations/interim-before-r134/archive-metadata.json) · [中间窗口原状态](monitoring/observations/interim-before-r134/acceptance-state.json) · [中间窗口最后快照](monitoring/observations/interim-before-r134/latest-acceptance.json)

iOS1.2.35/build55，build ID e275d303-958c-430d-8fc8-39a6b4c35c10，已上传VALID/APP_STORE_ELIGIBLE。基于完整build54整合，40项受影响单测和1项UI测试通过，归档签名与源码审核完成。当前1.2.34仍等待审核；发布技能要求撤回已有审核需用户明确授权，该确认已发出，收到前保持原审核。后端修复不等待Apple审核。

[iOS上传报告](/Users/xuxuheng/Documents/.worktrees/CastReader-ios-audio-recovery-release-1.2.35/docs/iOS-1.2.35-Upload-Report.md) · [早期执行历史](execution-history-through-global-release.md)
