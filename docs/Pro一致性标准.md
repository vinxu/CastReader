# Pro 一致性标准

适用范围：iOS、Android、Web、浏览器扩展，以及扩展/网页上的上传文件朗读页。所有端必须使用同一套 Pro 判定口径，不允许出现某一端是 Pro、另一端是 Free 的状态不一致。

## 目标

- 一个用户只要在任一端拥有有效 Pro 订阅，登录同一账号后所有端都应识别为 Pro。
- Web/Stripe、iOS StoreKit、Android Play Billing、扩展登录态都必须汇总到统一的服务端权益状态。
- 权益异常优先检查身份字段和服务端状态，不把“让用户退出重登”或“等待发包”作为默认解决方案。

## 统一身份模型

- `user_id` 的标准含义是 readout-web/better-auth 的后端 `user.id`。
- Google `sub`、Apple user id、OAuth `account_id` 都是 provider account id，不是订阅主键；服务端必须把它们归一化到后端 `user.id` 后再查订阅。
- `email` 是跨端识别 Web/Stripe Pro 的重要兜底字段；客户端登录后只要能拿到 email，就必须传给 Pro 状态接口。
- `device_id` 只用于匿名额度、设备绑定和缓存兜底，不能作为登录用户 Pro 判定的唯一依据。

## 统一接口

所有客户端和上传文件朗读页必须调用同一个公开状态接口。`webBaseURL` 使用该端现有生产配置，不要在没有迁移计划时擅自把 `castreader.com` / `castreader.ai` 互相替换；统一的是路径、参数、响应与判权口径。

```text
GET {webBaseURL}/api/pro/status?device_id=&user_id=&email=&local_date=
POST {webBaseURL}/api/pro/listen-track
```

请求规则：

- `device_id`：必须传，用于匿名额度、设备绑定、诊断。
- `user_id`：登录后必须传；优先传后端 `user.id`，兼容期可传 Google/Apple provider id，但服务端必须归一化。
- `email`：登录后只要可得就必须传，尤其是 Google 登录和 Web/Stripe 购买用户。
- `local_date`：必须传客户端本地日期，用于免费额度日切。

响应规则：

- 所有端只读取统一响应里的 `pro`、`plan`、`account`、`listenRemaining`、`explainRemaining/freeRemaining` 等字段。
- 不允许某个端或某个页面绕过 `/api/pro/status` 自己查询订阅表或复写 Pro 判定。

## 服务端判权标准

服务端返回 `pro: true` 的条件至少包括：

- normalized `user_id` 对应的用户有 active/trialing Pro subscription。
- `email` 对应用户有 active/trialing Pro subscription。
- `device_id` 已绑定到拥有 active/trialing Pro subscription 的用户。
- 后续如果接入 Apple/Google Play 服务端收据校验，也必须写入同一套 entitlement 结果，不新增平行逻辑。

服务端必须做到：

- 同时接受后端 `user.id` 和 provider `account_id`，并统一解析到后端 `user.id`。
- 通过 `email` 找到有效订阅时，应 best-effort 绑定或修正当前 `device_id/user_id` 的关联。
- 订阅状态以服务端为跨端权威；本地商店权益只作为对应平台的即时本地权益。

## 客户端判权标准

- iOS：`isPro = storeKitPro || serverPro`。
- Android：`isPro = googlePlayPro || serverPro`。
- Web/扩展/上传文件朗读页：以 `/api/pro/status` 的 `serverPro` 为统一权威。
- 客户端启动、前台恢复、登录成功、退出登录、购买成功、恢复购买、账号信息变化后，都必须刷新 `/api/pro/status`。
- 已登录用户调用额度消耗或播放上报时，也必须传 `device_id + user_id + email`。

## 禁止项

- 禁止把 Google sub、Apple user id 直接当作订阅表 `user_id` 查询且不做归一化。
- 禁止登录用户只传 `device_id` 查 Pro。
- 禁止扩展上传文件朗读页使用与扩展主入口不同的 Pro 逻辑。
- 禁止一个端只认本地订阅、另一个端只认服务端订阅，导致权益不一致。
- 禁止在未验证 `/api/pro/status` 前要求用户反复退出登录。

## 必测矩阵

每次改 Pro、登录、订阅、额度、上传文件朗读页时，至少验证：

| 场景 | 期望 |
| --- | --- |
| Web/Stripe Pro 用户用 `email` 查询 | `pro: true` |
| 同一用户用后端 `user.id` 查询 | `pro: true` |
| 同一用户用 Google/Apple provider `account_id` 查询 | `pro: true` |
| 同一用户登录 iOS/Android 后查询 | `serverPro: true`，客户端显示 Pro |
| 同一用户打开 Web、扩展主入口、扩展上传文件朗读页 | 都显示 Pro |
| 随机 `user_id/device_id/email` 查询 | `pro: false`，仍返回免费额度 |
| 登录后朗读/解读上报 | 上报请求包含 `device_id + user_id + email` |

## 诊断流程

遇到“某端不是 Pro”时，按顺序检查：

1. 客户端实际发出的 `device_id/user_id/email/local_date`。
2. `/api/pro/status` 对同一组参数的线上返回。
3. `user_id` 是否是后端 `user.id`，如果是 provider id，服务端是否归一化成功。
4. email 是否能命中 active/trialing subscription。
5. 客户端是否刷新了状态、是否错误缓存了 free 状态。

只有确认服务端已经返回 `pro: true`、客户端仍显示 Free 时，才进入客户端缓存/UI 刷新排查。
