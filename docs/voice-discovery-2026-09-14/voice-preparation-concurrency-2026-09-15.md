# 音色准备并发与真机验收

## 本次修复

此前「李云龙」切换停播是跨客户端和服务端的准备竞态：Kindle 下一页请求比当前段早 1 ms，先取得准备租约；当前段因租约有效被立即返回 503，四次请求都在音色激活前耗尽。音色在创建后 6.999 秒激活，下一页随后成功，但当前段已失败。GPU 没有重启，成功任务的 GPU 排队仅 0.07 ms。历史错误代码由时序、原代码分支和隔离复现共同确认，旧日志没有保存响应体。

- `VoiceSwitchStatusCenter` 将音色准备与短暂的界面完成提示分开。切换事务先于预读通知建立；当前段音频就绪后即释放等待，不等提示动画结束。快速改选只允许最新事务释放等待者，取消会清除对应 continuation。
- `APIService` 的后台克隆请求在取得调度许可前等待切换准备。等待不占网络许可，并保留账号边界检查。`VOICE_PREPARING` 遵守服务端 `Retry-After`，重试和鉴权刷新共用单调时钟的 90 秒期限；普通瞬时错误保留较小的重试次数。
- `ReadAloudViewModel` / `ExplainViewModel` 先建立切换事务，再通知其他模块失效缓存。解读当前块的重生成使用前台优先级，不会等待自身的后台屏障。
- `KindleBookView` 取消旧的音频预读任务，保留已获取的页面内容；新预读等当前段恢复后继续。用户主动暂停、旧请求的迟到音频、页尾等待取消后的播放意图仍由原有会话校验保护。
- 后端按「地区 + 音色」共享准备结果。进程内 Promise 合并之外，PostgreSQL 租约负责跨实例协调；等待不会占用数据库连接。一个调用取消不会取消其他人的准备，不同文本仍各自合成和结算。准备、重试与失败清理都有期限，避免永久等待和重复抢占。

首次使用一个尚未准备的社区音色仍需真实准备时间；本次修复消除正常准备被并发请求误判为终止性错误的问题，不宣称首次生成即时完成。

## 源码、构建与测试

- 应用源码：`24b28e3db6952b2b9597be131bfc83064e8b1c56`，1.2.40（61），分支 `codex/mobile-voice-explore-20260914`。
- 保留 `64c2dbd` 发布祖先、`633f6bb` 音色发现、`ad4b885` EPUB TOC、`a4a3ee0` 页尾与切换恢复修复。通过 `build-voice-toc-integration.sh --device` 基线检查和真机构建；没有使用主目录旧工作树。
- 独立 DerivedData：`/tmp/CastReaderCloneLatencyDevice20260915`。真机 debug dylib UUID：`FF840347-F072-32CB-B7CF-C7344FF5DC49`。
- 模拟器通过 11 项针对性测试以及另一组 224 项朗读、Kindle、音色回归。重试策略测试在两组中有重复，不能把两组数字相加当作不同测试数量。
- 真机 8 个不同用例通过：社区/个人/常规音色往返、克隆转常规拆词续读、快速改选与主动暂停、失败后重试、页尾等待后的继续/主动暂停，以及新并发屏障和重试期限。
- 初次真机运行有一个用例失败：系统先报告音频路由移除和音频中断，导致「自然播到页尾」前置条件未满足。该用例未修改代码、单独复测通过。其他 7 项首次通过，因此不是一次完整无失败运行。
- 2026-09-15 17:18:35 安装，17:19:14 正常启动（北京时间），保留原 App 数据。未提交 App Store。

## 服务端验收

中国区源码 `530fca6cb1578e3517bc20c15815d8c46daf296e` 已部署于 `/opt/castreader/release-20260915170844`。通过正常中国区 `cms_` 会话，同时向首次使用的「李云龙」发送两段不同文本，预读和当前段均返回 200，分别耗时 16.896 / 16.907 秒；两份音频不同，结算总计 6,432 ms，没有残留预留。测试账号已清理。目录仍有 1,606 个音色（1,323 个社区音色）。

后端 234 项回归和 TypeScript 通过；最后一个清理分支调整后又通过全部 9 项协调器测试。覆盖跨协调器实例等待、100 个同音色等待者、取消首个调用、地区隔离、租约到期接管、失败后重试以及清理失败不能覆盖已成功准备。

证据文件：`/tmp/castreader-preparation-device-build.log`、`/tmp/castreader-preparation-device-tests.log`、`/tmp/castreader-preparation-device-gate-retest.log`、`/tmp/castreader-preparation-device-install.log`、`/tmp/castreader-preparation-device-launch.log`、`/tmp/castreader-preparation-ios-tests.log`、`/tmp/castreader-preparation-ios-regression.log`、`/tmp/castreader-preparation-cn-e2e.json`。

国际区源码 `a97b0ea161c5b8b408a32c818a2d4d6c760776c8` 已部署到 `api.castreader.ai`，部署 `dpl_Df3t4UccxmoydN9qJyUU9coqFajZ`。候选与旧现网的完整音色、两区专题和推荐内容逐项相同（每区当前 7 个专题）；14 个定时任务保持一致。正式域名与正常移动会话的首次音色并发合成均返回 200（8.802 / 8.888 秒），且返回不同文本对应的不同 MP3。原问题「李云龙」英文合成返回 200（3.512 秒）。3 条成功生成合计结算 8,976 ms，无残留预留，测试账号已清理。能力与鉴权边界探针通过。以上是真实 API 测试，手机的播放会话测试使用可控 TTS 音频，两者验收边界不同。

国际区证据：`/tmp/castreader-preparation-global-production-e2e.log`、`/tmp/castreader-preparation-global-capability-probe.log`；持久报告位于后端工作树 `docs/voice-discovery/concurrent-preparation-acceptance-2026-09-15.json`。
