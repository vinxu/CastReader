# O’Reilly Learning 接入：产品与技术实现规范

## 1. 定位与范围

O’Reilly 接入沿用 CastReader 的“商业网页阅读平台”能力，不复制正文、不代替
O’Reilly 的账号、版权、排版和阅读进度系统。CastReader 负责：

- 在共享、持久的 WebKit 会话中完成 O’Reilly 官方个人或机构认证。
- 将用户的 **Reading History** 映射为 CastReader 内的 O’Reilly 书架。
- 打开 O’Reilly 官方长章节阅读页。
- 只提取当前无遮挡可见区域，提供朗读、词级高亮和解读标注。
- 在长章节内按视觉页滚动，并在章节边界进入前/后章节。
- 自动或手动换页后，按换页前的朗读/解读意图继续。

O’Reilly 与 Kindle、Google Play Books、Kobo 的关键差异是：它没有离散页，
一个章节通常是一张很长的连续网页。因此产品中的“上一页/下一页”定义为：

> 当前原生阅读区域内完整可见的文本切片；翻页是滚动一个无遮挡 viewport，
> 只有到章节首尾时才使用 O’Reilly 官方章节链接。

## 2. 账号与书架产品定义

### 2.1 支持的登录方式

- O’Reilly 个人订阅账户。
- 学校、公司或图书馆提供的机构访问，包括 EZproxy、SAML、OAuth 等跳转。

机构入口分为三层：

1. O’Reilly 官方机构目录搜索。
2. 已验证机构的一键直达入口。Peninsula Library System 使用
   `login.ezproxy.plsinfo.org`，登录后进入
   `learning-oreilly-com.ezproxy.plsinfo.org`；它没有出现在 O’Reilly 的公开
   机构目录中，因此不能依赖名称搜索。
3. 用户粘贴图书馆提供的 O’Reilly/EZproxy 访问链接。Native 只接受 HTTPS、
   无 userinfo、默认端口的 O’Reilly 官方入口和代码中已审核的机构入口。
   新 EZproxy 供应方必须加入显式 allowlist；不能仅凭 host 含 `ezproxy`
   或 query 指向 O’Reilly 就信任，以免伪造登录页。

机构 IdP 无法穷举，因此绑定 WebView 的可见主页面允许严格 HTTPS 认证跳转；
但只有可信 O’Reilly Learning History/Profile 页面可以提交书架数据。

CastReader：

- 不读取、记录或保存用户名、密码、Cookie、token。
- 不把 App 自身 Google OAuth token 注入 O’Reilly。
- 绑定、登录弹窗、History 和 Reader 共用 `CommercialWebSession` 的持久
  `WKWebsiteDataStore`。
- 解除 O’Reilly 绑定只删除本地 O’Reilly 书架、历史和锚点，不清共享 WebKit
  Cookie，避免影响 Google Play Books、Kobo 或其他使用 Google 登录的平台。

### 2.2 为什么用 Reading History

机构账户通常没有传统“Owned Books”书架，但已打开的书会稳定出现在
`/history/`，包含：

- 明确的 `urn:orm:book:<contentID>` 类型。
- 书名、作者、封面。
- 阅读进度。
- 官方书籍/继续阅读链接。

因此产品文案应明确为“同步 O’Reilly 阅读历史”，而不是承诺拥有全部收藏或
机构目录。History 中的课程、视频、活动不能进入书架。

EZproxy 的 `temporary-access` 只证明用户拥有机构访问权限，不一定映射到一个
跨浏览器持久的 O’Reilly 个人身份。新的 WebKit profile 首次登录时，History
可能为空，即使同一张图书馆卡曾在 Chrome 中打开过书。此时不能把空列表表现为
同步失败，也不能要求购买个人账户：

- 显示“暂无阅读历史”并解释原因。
- 提供“打开一本书”，进入同一个持久 WebKit profile 的 O’Reilly Home/Search。
- 用户打开任意真实 book reader 后，先确认 `#sbo-rt-content` 正文已经加载，
  再保留 4 秒给 History 埋点落库，然后自动返回 `/history/` 重扫；不能只看
  SPA URL 改变就回跳。
- 浏览过程中顶部始终提供“同步 O’Reilly 阅读历史”的人工返回入口。
- 只有页面明确呈现 empty state 时，0 本才是完整快照；只有新本地书架遇到可信
  空 History 时才引导 seed。已有书架仅可接受同账号可信空快照，以支持删除
  全部历史项。
- 账号 identity 改变时必须按新账号处理，不能让旧账号书架跳过 seed。

### 2.3 账号证据

书架删除和账号切换必须有稳定账号证据。不能用 host 代替账号，因为：

- 所有个人账号共享 `learning.oreilly.com`。
- 多个图书馆用户可能共享同一个 EZproxy host。

可信 O’Reilly 页面会在渲染的分析 bootstrap 中提供匿名 learner/account
标识。Native 收到后立即 SHA-256，只持久化 hash；组织名或安全的匿名标签仅用于
UI。没有稳定账号证据时：

- 可以继续等待页面加载。
- 不得提交 0 本书。
- 不得删除旧书架。
- 不得判定发生账号切换。

### 2.4 同步状态机

```text
未绑定
→ 选择个人账户 / 官方机构目录 / 已验证机构 / 机构访问链接
→ 官方认证页（绑定底卡隐藏）
→ 返回可信 O’Reilly host
→ 自动进入 Reading History
→ 立即显示“正在同步”
→ 等待异步 hydration + 扫描到页尾 + 稳定确认
→ 显示“找到 N 本书，可以同步”
→ 提交到 CastReader O’Reilly 书架
```

规则：

- 第一次空 DOM 不是空书架。
- 部分快照只能新增或更新，不能删除。
- 只有同一账号的完整稳定快照可以删除已消失的书及其锚点。
- 空书架需要比非空书架更长的稳定确认。
- 网络失败保留旧书架和登录态。

## 3. 数据合同

### 3.1 图书

```text
id                 oreilly:<canonical contentID>
contentID          O’Reilly 内容 ID（合同不假设一定是 ISBN）
title              清除 Continue/Read Now 等动作前缀
author             清除 By/Author 前缀
coverURL            仅可信 HTTPS 图片
readerURL           History DOM 实际给出的 URL
readerHost          书架证明 readerURL 时的 host
lastReaderURL       最近成功提交的真实章节 URL
progressLabel       O’Reilly 展示的进度文案
```

禁止根据 ISBN 猜测或合成 URL。`readerURL`、`readerHost`、`contentID` 和稳定 ID
必须互相一致。

### 3.2 阅读锚点

```text
bookID
readerURL           同 host、同 contentID 的真实章节 URL
pageFingerprint     当前视觉页的 opaque signature
progressLabel
scrollOffset        保存时的章节内滚动像素
scrollMaximum       保存时的最大滚动范围
scrollRatio         章节内归一化进度
sourceParagraphIndex
sourceUTF16Start
sourceUTF16End
updatedAt
```

视觉页 signature 用于判断页面身份、诊断和防止错误预加载命中，不得 trim 或从
UI 文案重建。恢复时优先使用 `sourceParagraphIndex + sourceUTF16Start` 将原始行
对齐到当前无障碍视觉区；DOM 重排后找不到 source block 时才使用 `scrollRatio`，
最后以 `scrollOffset / scrollMaximum` 兜底。锚点必须仍属于同一可信 host、
同一本书和同一章节 path；query/hash 的规范化变化不应导致恢复失败。

## 4. 阅读页安全边界

### 4.1 可信 URL

只接受：

- `https://learning.oreilly.com/library/view/<slug>/<contentID>/...`
- 合法机构代理改写：
  `https://learning-oreilly-com.<proxy-labelled-institution-domain>/library/view/...`

代理 host 必须满足：

- 精确 `learning-oreilly-com.` 前缀。
- 后缀至少三个安全 DNS label。
- 可注册域名前至少一个 label 明确包含 `proxy`。

Native 打开一本书后，整个 Reader 生命周期进一步固定到：

```text
expected host + expected contentID
```

章节路径、slug、query 和 hash 可以变化；跨 host 或跨书导航、响应及桥消息全部
拒绝。这避免用户点击正文中的另一本书后，Native 仍把 TTS/历史归到原书。

### 4.2 桥消息

O’Reilly 复用已验证的 `googleBooks*` Native wire 协议，但每条 payload 标记
`source=oreilly`。只接受：

- HTTPS。
- 主 frame。
- 绑定书的准确 host/contentID。
- 明确白名单 message type。
- 当前 frame session / turn identity。

## 5. 当前视觉页提取

正文唯一来源是 `#sbo-rt-content`，候选元素包括标题、段落、列表、引用、代码块、
图注和表格文本。必须排除：

- header、footer、nav、aside。
- O’Reilly 状态栏和控制按钮。
- 隐藏、透明、`aria-hidden`、`inert` 节点。
- CastReader/O’Reilly Listen 控件。
- viewport 顶部或底部只露出一部分的行。

可见页 clip 由以下共同决定：

- WebView 的真实视觉 viewport。
- O’Reilly 固定顶部导航实际占用。
- Native 播放条及安全区传入的 bottom occlusion。
- 正文根与 viewport 的真实交集。

提取以字符 `Range` 为单位，记录源段索引及 UTF-16 start/end。signature 只使用稳定
源坐标和文本 fingerprint，不使用动画中的像素坐标。

## 6. 朗读、解读与高亮

### 6.1 朗读

- 只把当前视觉页完整可见文本交给现有 `ReadAloudViewModel`。
- 段内 TTS 继续流式生成和入队。
- Native TTS 时间戳驱动 DOM 词级高亮。
- 页面最后一个音频 item 真正结束后，才发起物理翻页。
- 请求翻页时清理旧页视觉；新页稳定提交后安装新 DOM mapping。

长章节视觉页不使用“一行重叠”，否则下一页会把重复的完整行再次朗读。若未来需要
视觉连续性，应引入显式 source cursor，而不是重复正文。

### 6.2 解读

- 解读输入是当前已提交视觉页的完整可见文本。
- 讲解 TTS 与原文 marks 复用现有 Explain 管线。
- 解读完成后走与朗读相同的视觉翻页事务。
- 手动滚动后，若手势前正在解读，则稳定新页重新解读；若原来暂停则保持暂停。

### 6.3 高亮/marks 生命周期

- 自动或手动视觉页改变前清理旧 highlight/marks。
- 字体/图片 reflow 但源页等价时，只重建几何映射，不重复朗读。
- 旧 frame、旧 turn、旧预加载的迟到结果不得重新绘制。

## 7. 翻页协议

### 7.1 章节内

`next`/`prev` 滚动一个完整可读 viewport，等待：

- 非空新 signature。
- 连续稳定样本。
- 稳定时间窗。
- turn/frame identity 仍匹配。

成功后才提交、抽取、恢复朗读或解读。

### 7.2 章节边界

- 下一章：点击可信 status-bar next link，新章节从顶部开始。
- 上一章：点击可信 previous link，新章节定位到最后一个完整视觉 viewport。
- 点击可能被站点 SPA 拦截，也可能触发 full navigation；两种路径都必须进入
  settlement。
- full navigation 用 `sessionStorage` 只保存一次性的 opaque turn transaction；
  不保存正文或账号数据。

### 7.3 手动滚动

真实 touch、wheel、scroll 或 native 上/下页按钮产生 manual intent：

- 立即暂停旧页播放意图。
- 合并连续滚动，只提交最后稳定视觉页。
- 新页提交后按原模式恢复。
- 回弹到 baseline 时取消事务，不误重启。

## 8. 预加载

O’Reilly 的连续 DOM 允许只读计算下一个 viewport，因此比 Google Play Books 更有
预加载空间：

- 预取下一个视觉页的段落和 TTS。
- 若下一视觉页暂时无法形成完整段落，最多预取源顺序中的下一句。
- 预加载绑定当前 signature、预测 fingerprint、voice、language、speed、mode 和
  generation。
- 新页提交后只有全部身份一致才能消费；滚动、旋转、换模式、换音色或 reflow 会使
  不匹配缓存失效。

预加载只减少生成等待，不能成为提前翻页的理由。

## 9. 布局与旋转

- `preferredContentMode = .mobile`。
- Mobile Safari UA。
- `pageZoom = 1`，不通过整体缩放修字号。
- Native 先创建最终尺寸 WebView，再开始 navigation。
- 旋转或底栏遮挡变化时显示稳定 loading cover，重新计算视觉 clip，稳定后一次性
  揭开。
- 旋转属于 relayout；源页等价时不得停止播放或重复 TTS。

## 10. 异常恢复

| 异常 | 行为 |
|---|---|
| 登录过期 | 保留旧书架，提示重新绑定 |
| History hydration 超时 | 不提交 0，本地旧书架不变 |
| Reader 15 秒无正文 | 显示“内容暂时无法打开”，提供重试 |
| Reader 跳离绑定书/host | 阻止导航；首屏阶段提示会话失效 |
| 网络失败 | 重试当前可信 URL，不清 Cookie |
| Web content process 终止 | 用同一本书恢复，不要求重新登录 |
| 非 book History 项 | 同步阶段过滤 |
| 无稳定账号证据 | 不允许提交或删除书架 |

## 11. 验收矩阵

### 绑定与书架

1. 个人账户入口能进入 O’Reilly 官方登录。
2. 官方机构目录入口能完成图书馆/IdP 跳转。
3. Peninsula Library System 一键入口能进入
   `login.ezproxy.plsinfo.org`，并在成功后进入其 O’Reilly 代理 host。
4. 官方或已审核的 O’Reilly/EZproxy 访问链接可以粘贴打开；未知 EZproxy、
   HTTP、userinfo、异常端口、非 O’Reilly 目标全部拒绝。
5. 新 temporary-access 会话 History 为空时显示可操作引导，而不是错误或死路。
6. 从空 History 打开 Home/Search，选择一本书后自动返回 History 并重新扫描。
7. 登录页不被 CastReader 底卡遮挡。
8. 进入 History 后 100ms 级别出现同步状态。
9. 页面未 hydrate 时不显示“0 本”。
10. 只同步 `urn:orm:book:`，课程/视频不进入书架。
11. 标题、作者、封面、进度正确。
12. 部分快照不删除旧书；完整同账号快照才删除。
13. 账号切换只清 O’Reilly 本地数据。
14. 解绑后其他商业平台的共享 Web 登录仍保留。

### 阅读

1. 只读当前无遮挡视觉页，不读顶部导航、状态栏、Listen 控件。
2. 底部半行不进入 TTS。
3. 当前页词级高亮与 TTS 对齐。
4. 页尾最后一句完整播放。
5. 下一视觉页不重复上一页的完整行。
6. 连续至少三次自动滚动翻页并续播。
7. native 上/下页按钮可手动翻视觉页。
8. 手动滚动后按原 Read/Explain 状态恢复。
9. 解读完成后自动进入下一视觉页并继续解读。
10. 到章节尾进入下一章；上一章从末尾视觉页开始。
11. 旋转后可见文本与 TTS 保持一致，不重复朗读。
12. 预加载命中时衔接更快；不匹配时宁可重生成，不能播错页。

### 安全

1. 伪造 O’Reilly host、非 HTTPS、userinfo、异常端口全部拒绝。
2. 合法代理规则与 Native/JS 一致。
3. Reader 跨 host 或跨 contentID 导航/消息拒绝。
4. 日志无密码、Cookie、token、原始 learner ID 和整页正文。

## 12. 测试账号策略

机构账户已经能覆盖接入的核心风险：

- 多跳认证。
- History 书架。
- 真实图书元数据。
- 长章节 DOM。
- 章节边界。
- 朗读、解读、高亮、滚动和旋转。

开发阶段无需为此购买高价个人月度账户。只有准备公开承诺“支持 O’Reilly 个人账户”
时，才需要补一次个人账户直接登录、续费/过期和账号切换验收；优先使用官方试用，
验证结束后取消即可。
