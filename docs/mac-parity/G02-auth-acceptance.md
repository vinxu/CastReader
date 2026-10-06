# G02：国际账号与会话验收

前置：G01 已在本机通过。状态：当前真实账号登录、进程重开恢复已通过，自动合同测试已通过。用户已接管四个书架的同步接入，要求助手继续所有适配和测试；未覆盖的其他供应商/账号场景保留到联合验收。

## 对齐来源

直接复用 `LoginView`、`AuthService`、`AuthService+Apple`、`MobileSessionStore`、`KeychainStore`、`RootAuthGate` 和账号内容作用域。Google/Apple/邮箱是国际版入口；没有 Mac 手机号入口。

Mac 的 Apple ID entitlement、Bundle ID 与本次已签名运行包一致。Google 和 Apple 的真实授权回调、服务端 canonical user ID、后端 session 及断网错误仍需实际验证，不能以配置存在认定成功。

## 验收清单

| 编号 | 操作与标准 | 当前状态 |
| --- | --- | --- |
| A01 | 初次启动显示同 iOS 的 Apple/Google/邮箱入口、条款与隐私；窄窗都可达 | PASS（G01 实测） |
| A02 | Google 使用现有账号完成授权、回到发起窗口，建立服务端会话；取消可重试 | 等待真实账号 |
| A03 | Apple 使用现有账号完成授权和后端交换；取消及隐藏邮箱行为对齐 iOS | 等待真实账号 |
| A04 | 邮箱输入、发送/重发倒计时、错误/过期码及成功登录对齐 iOS | 等待真实账号；不向未知邮箱发验证码 |
| A05 | 完成登录后显示正确账号及国际首次书库引导/首页，不停留在登录墙 | PASS：真实 Release 账号、Pro 月订阅、首页 |
| A06 | 正常退出进程并重开，Keychain 会话和账号恢复一致，不要求重复登录 | PASS：⌘Q 后 PID 60195 → 62820；重开同一账号/Pro，无登录墙 |
| A07 | 用户主动退出立即回到登录墙；旧刷新/退出回调不能覆盖后来账号 | 自动合同 PASS；真实路径待测 |
| A08 | A/B 两个测试账号切换，书架、历史、私人声音、额度及待处理任务不串号 | 自动会话边界 PASS；真实数据对照待测 |
| A09 | session 被拒绝/过期或网络中断，按 iOS 合同关闭失效账号或保留可恢复会话 | 自动合同 PASS；实际网络场景待测 |
| A10 | Apple 的一次性 code 仅送到正确交换入口，Google 交换不夹带 Apple code | 复用 iOS 合同 PASS |
| A11 | 删除账号流程的展示、错误和取消可达；真实删除只用明确的可销毁账号 | 未执行；当前账号不做删除 |

## 自动测试

`CastReaderMacTests` 引用现有 `CastReaderTests/ServiceRoutingTests.swift` 与测试根目录帮助文件，没有复制维护第二套会话测试。`scripts/mac-unit-test-selection.txt` 明确列出适用的测试；工程生成脚本把清单写入 scheme。

本阶段选择 10 个既有会话/凭据/重定向合同，加上 G01 的 8 个国际版约束测试；均在测试专用容器中执行并通过，共 18 PASS / 0 FAIL / 0 SKIP。证据：`reports/mac-parity-20261004/g02-auth-contracts/summary.json`。Apple 网关交换测试沿用 iOS 原用例内部的路由参数，网络由 URLProtocol 截获；这不代表增加 Mac 中国版入口或发行要求。

真实账号 A05/A06 已完成；18 项自动测试不替代其他未执行的真实账号场景。不得为推进文件功能而开启跳过登录、伪造权益、复用其他产品私有 token 或用测试 session 冒充真实登录。
