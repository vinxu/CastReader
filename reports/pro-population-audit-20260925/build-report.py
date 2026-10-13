import json,pathlib,datetime,collections,csv,os
p=pathlib.Path(__file__).parent
get=lambda n:json.loads((p/n).read_text())
inv=get('inventory.private.json');cn=get('cn-inventory.private.json');ledger=get('ledger.private.json');usage=get('usage-after-expiry.private.json');base=get('usage.private.json');gate=get('gate.private.json');cngate=get('cn-gate.private.json')
live=[json.loads(s)for f in ['live-status.private.jsonl','focused-status.private.jsonl']for s in(p/f).read_text().splitlines()]
now=datetime.datetime.now(datetime.timezone.utc);tz=datetime.timezone(datetime.timedelta(hours=8))
def dt(s):
 if not s:return None
 d=datetime.datetime.fromisoformat(str(s).replace('Z','+00:00'))
 return d.replace(tzinfo=datetime.timezone.utc)if d.tzinfo is None else d
def bj(s):return dt(s).astimezone(tz).strftime('%m-%d %H:%M')if s else '—'
ac={a['id']:a for a in inv['accounts']};ap={r['subscription_row_id']:r for r in ledger['apple']};gp={r['subscription_row_id']:r for r in ledger['google']}
def istrial(s):return s['status']=='trialing' or (s['payment_provider']=='apple_app_store'and(ap.get(s['id'],{}).get('zero_price_trial')or ap.get(s['id'],{}).get('receipt_price')=='0'))or(s['payment_provider']=='google_play'and'freeTrial'in str(gp.get(s['id'],{}).get('offer_phase')))
validtrial=[a for a in inv['accounts']if any(istrial(s)for s in a['valid'])]
manual=[a for a in inv['accounts']if any(s['payment_provider'].startswith('manual')for s in a['valid'])]
failed=[a for a in inv['accounts']if a['failed']and not a['expectedPro']]
stale=[a for a in inv['accounts']if not a['expectedPro']and any(s['status']in ['active','trialing','pending_cancel']for s in a['subscriptions'])]
cnids=set(s['user_id']for s in cn['subscriptions']);cnvalid={i:any(not s['blocked_at']and s['status']in['active','trialing','pending_cancel']and dt(s['current_period_end'])>now for s in cn['subscriptions']if s['user_id']==i)for i in cnids}
positive=usage['extensionPositiveAfterExpiry'];positiveids=set(r['user_id']for r in positive);latest={r['user_id']:r for r in usage['extensionLatestState']}
assert all(not a['expectedPro']for a in failed)
assert len(gate)==21 and all(r['passed']and r['pro']is False for r in gate)
assert len(cngate)==7 and all(r.get('http')==200 and r.get('pro')==cnvalid[r['userId']]for r in cngate)
assert all(r['pro']==r['expected']for r in live if r.get('http')==200)
assert all(latest[i]['reported_pro']=='false'for i in positiveids)
for a in failed+stale:
 for host in ['https://castreader.com','https://api.castreader.ai']:
  assert any(r.get('http')==200 and r['userId']==a['id']and r['host']==host and r.get('pro')is False and r.get('canonicalMatches')is True for r in live)
summary={'completedAt':now.isoformat(),'global':{'snapshotAt':inv['checkedAt'],'subscriptionRecords':len(inv['subscriptions']),'accounts':len(ac),'effectivePro':sum(a['expectedPro']for a in inv['accounts']),'paid':257,'validTrials':len(validtrial),'manualExceptions':len(manual),'effectiveFree':sum(not a['expectedPro']for a in inv['accounts']),'failedAccounts':len(failed),'expiredActiveLabelAccounts':len(stale)},'cn':{'snapshotAt':cn['checkedAt'],'subscriptionRecords':len(cn['subscriptions']),'accounts':len(cnids),'effectivePro':sum(cnvalid.values()),'effectiveFree':sum(not v for v in cnvalid.values())},'onlineChecks':{'globalAccounts':len({r['userId']for r in live if r.get('region')!='cn'and r.get('http')==200}),'globalSuccessfulResponses':sum(r.get('region')!='cn'and r.get('http')==200 for r in live),'cnAccounts':len(cnids),'proValueMismatches':0,'rateLimitedResponses':sum(r.get('http')==429 for r in live),'globalReadOnlyGateChecks':len(gate),'cnReadOnlyGateChecks':len(cngate)},'telemetry':{'since':'2026-09-18T00:00:00Z','historicalPositiveAfterExpiryAccounts':len(positiveids),'historicalPositiveAfterExpiryEvents':len(positive),'latestReportedProForThoseAccounts':False,'devicesReportingAfterExpiry':len(usage['extensionLatestState']),'allLatestAfterExpiryReportsFree':all(r['reported_pro']=='false'for r in usage['extensionLatestState'])},'limitations':['Billing truth is latest production mirror/verified stored store records, not a fresh independent provider API sweep.','No universal current-state telemetry for every old client installation.','Historical extension pro_status_after_login is entitlement/UI evidence, not proof of unlimited audio consumption.','CN compatibility status does not include resolvedUserId; pro values and trusted worker entitlement were compared.']}
(p/'validation-summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
lines=['# CastReader Pro 用户全量账本与线上权限核查','',f'完成时间：{now.astimezone(tz).strftime("%Y-%m-%d %H:%M:%S")}（北京时间）。本次全部为只读操作，没有改订阅、扣款、账号授权、设备关联或免费额度，没有发布代码。','',
'## 结论','',
'当前账本与重点账号线上权限核验，未发现“已无有效订阅/试用，却仍由后端授予 Pro”的账号。14 个扣款失败账号及 7 个过期但状态标签仍为 active/trialing 的账号，官网、全球 API 与内部解读权限接口均返回非 Pro。',
'历史日志发现 2 个账号在试用结束、当前账本显示扣款失败的情况下，旧版扩展曾上报 Pro；它们后续最新上报均为非 Pro，本次线上验证也均为非 Pro。这是历史状态异常证据，不能据此断言它们现在仍在使用 Pro。',
'不能保证所有未联网或未上报的旧设备本地界面均已刷新。后台正确撤销和远端每台客户端完成刷新，是两个不同的验证范围。','',
'## 全量范围','',
'| 范围 | 订阅记录 | 账号 | 当前有效 Pro | 非 Pro |','|---|---:|---:|---:|---:|',
'| 全球库 | 550 | 532 | 300 | 232 |','| 国内库 | 12 | 7 | 1 | 6 |','',
'两库存在账号重复，不能把 532 + 7 当作不重复的自然人数。全量扫描包括 Stripe、Apple、Google Play、支付宝和人工授权。每个账号合并所有来源，另一渠道有效、有效试用、已取消续费但尚未到期，都不误判为失效。',
'全球 300 个有效 Pro 中：257 个为有效付费权益，40 个为仍在期限内的免费试用（包括取消续费但尚未结束的试用），3 个为人工授权。国内 1 个有效 Pro 为 igaory@gmail.com 的 support_adjustment；全球库同邮箱有有效 Stripe 年卡付费记录，国内这条是权益补记，不应当作扣款失败漏撤销。',
'数据时间：全球账本 09-25 15:39；国内账本 09-25 15:44；之后完成交易明细和线上复核。该报告是这些时间点的快照。','',
'## 14 个扣款失败账号','',
'14 个账号共 15 条 past_due 记录；均没有另一条有效权益。以下“非 Pro”同时经官网和 api.castreader.ai 验证，内部解读权限接口也均返回 pro=false。','',
'| 账号 | 失败来源 | 当前线上 | 最新可见扩展非 Pro 上报（北京时间） |','|---|---|---|---|']
for a in sorted(failed,key=lambda a:a['email']):
 r=latest.get(a['id']);state=f"{bj(r['created_at'])}，{r['extension_version']}"if r and r['reported_pro']=='false'else '没有本轮可用的最新扩展状态上报'
 lines.append(f"| {a['email']} | {', '.join(sorted({s['payment_provider']for s in a['subscriptions']if s['status']=='past_due'}))} | 非 Pro | {state} |")
lines+=['','Bob（bobfabienzinga@gmail.com）也在上述 14 人中。目前后台及实际服务权限均为非 Pro；不能由此推断他的每台 iPhone、iPad、扩展界面当下显示什么。','',
'## 两条历史异常线索','',
'时间均为北京时间；扩展事件来自 pro_status_after_login，且 has_account=true。按设备当前绑定关系与绑定时间关联到账号，并与试用到期、订阅快照及成功订单记录交叉核对。','',
'| 账号 | 试用结束 | 到期后最后一次上报 Pro | 之后最新非 Pro 上报 | 本次线上 |','|---|---|---|---|---|']
for id in sorted(positiveids,key=lambda i:ac[i]['email']):
 a=ac[id];rs=[r for r in positive if r['user_id']==id];last=rs[0];end=next(s['snapshot']['trialEnd']for s in a['subscriptions']if s['snapshot'].get('trialEnd'));r=latest[id]
 lines.append(f"| {a['email']} | {datetime.datetime.fromtimestamp(end,tz).strftime('%m-%d %H:%M')} | {bj(last['created_at'])}，{last['extension_version']} | {bj(r['created_at'])}，{r['extension_version']} | 非 Pro |")
lines+=['',
'这两人当前 Stripe 快照均为 past_due，账本中未找到成功付费订单。共发现 218 条到期后的 Pro 状态上报，随后有明确非 Pro 上报。记录不能单独证明具体听了多久、是否绕过实际免费额度，也不能单凭事件把根因全部归为客户端缓存。',
'最近七天，能匹配到到期后权益事件的 12 台扩展设备，其各自最新状态全部为非 Pro。手机侧可用的 11 次权益状态上报均为 free，但此类事件主要来自付费页，不能代表全部安装设备。','',
'## 状态字段残留与主动授权','',
'全球 7 条记录仍标 active/trialing，但期限已经结束；期限校验已生效，线上没有继续授予 Pro。国内也有过期 trialing、pending_cancel 或 active 的历史记录，国内 6 个无有效权益账号的公开状态及内部权限均为非 Pro。不能仅按数据库 status 字段统计当前会员。','',
'| 全球过期状态记录账号 | 来源 | 状态标签 | 实际到期（北京时间） |','|---|---|---|---|']
for a in stale:
 for s in a['subscriptions']:
  if s['status']in['active','trialing','pending_cancel']:
   lines.append(f"| {a['email']} | {s['payment_provider']} | {s['status']} | {bj(s['current_period_end'])} |")
lines+=['','以下 3 个账号通过明确人工授权获得 Pro，不属于试用/扣款失败的缓存残留。本轮未更改授权。若业务要求完全取消赠送，需要另行决定这些已发出的授权。','','| 账号 | 授权说明 | 到期（北京时间） |','|---|---|---|']
for a in manual:
 for s in a['valid']:
  if s['payment_provider'].startswith('manual'):lines.append(f"| {a['email']} | {s['plan_name']} | {bj(s['current_period_end'])}（{dt(s['current_period_end']).astimezone(tz).year} 年） |")
lines+=['','## 验证方法与边界','',
'- 全量读取两库订阅及付款记录；当前 Pro 按所有来源合并，并检查状态、到期时间及账号封禁。有效试用保留 Pro。',
'- 补核 148 条 Apple 订阅的交易/通知账本、68 条 Google Play 订阅及 63 条最新周期观察、207 条 Stripe 有效或扣款失败订阅快照。Apple 和 Google Play 的数据库到期时间与已存支付方到期时间一致；有效权益中未发现过期/撤销矛盾。Apple 有 2 个老账号没有新周期表记录，但原始生产交易及通知影子表均支持有效期，未当作未付款。',
'- 没有逐一重新请求 Stripe、Apple、Google 支付平台的实时 API。本报告以当前生产支付镜像、已存验证交易和线上权限为依据；无法排除支付方已有变化但尚未通知入库的情况。',
'- 公开接口验证全球 84 个账号（154 个 HTTP 200 回应）、国内 7 个账号，Pro 值均符合账本。不是宣称对全部 532 个账号各调用了一遍接口。',
'- 全部 14 个扣款失败账号与 7 个过期状态账号均覆盖官网和全球 API 双入口。另以 consume=false 检查全球 21 个账号与国内 7 个账号的内部权限接口，结果全部符合账本，没有消耗免费次数、没有生成音频。非 Pro 仍可在免费额度内 allowed=true，这不等于 Pro。',
'- 初次批量请求官网出现 15 个 HTTP 429，已停止连续扫描并降低请求频率，关键账号随后完成复核。429 未计为 Pro/Free 判定，也没有通过换 IP 或身份绕过限流。',
'- 国内公开兼容接口不含 resolvedUserId；最初通用检查器的 passed=false 来自这个缺失字段，并非 Pro 值不一致。随后国内内部权限接口全部核对通过。',
'- 近期遥测窗口从 2026-09-18 00:00 UTC 开始。全部使用记录不等于 Pro 使用：免费额度、读完本篇宽限及断网容错均可能允许播放。没有充分证据的情况不判为违规。',
'- 不建议为清理少量过期身份而给每段朗读增加同步扣款查询。本轮没有改变播放中的查询频率与容错行为。','',
'## 本地证据文件','',
'- validation-summary.json：汇总及验证边界。',
'- account-entitlement-audit.private.csv：两库逐账号核查表，含邮箱，供内部使用。',
'- inventory.private.json / cn-inventory.private.json：完整账号订阅快照，包含隐私信息，不宜直接转发给客户。',
'- ledger.private.json：支付方已存交易与周期核对。',
'- live-status.private.jsonl / focused-status.private.jsonl：公开状态请求记录。',
'- gate.private.json / cn-gate.private.json：内部权限只读复核。',
'- usage-after-expiry.private.json：到期后扩展状态与最新状态。','']
(p/'Pro用户核查报告.md').write_text('\n'.join(lines))
with (p/'account-entitlement-audit.private.csv').open('w',newline='')as f:
 w=csv.writer(f);w.writerow(['region','email','user_id','expected_pro','category','providers','statuses','max_effective_expiry_utc','online_status_checked','latest_extension_pro','latest_extension_report_utc'])
 for a in inv['accounts']:
  kind='free_failed_payment'if a['failed']and not a['expectedPro']else'free_expired_or_canceled'
  if a['expectedPro']:kind='manual_grant'if a in manual else'valid_trial'if a in validtrial else'valid_paid'
  r=latest.get(a['id'],{});w.writerow(['global',a['email'],a['id'],a['expectedPro'],kind,','.join(sorted({s['payment_provider']for s in a['subscriptions']})),','.join(sorted({s['status']for s in a['subscriptions']})),max((s['current_period_end']for s in a['valid']),default=''),any(x.get('http')==200 and x['userId']==a['id']and x.get('region')!='cn'for x in live),r.get('reported_pro','unknown'),r.get('created_at','')])
 for id in sorted(cnids):
  ss=[s for s in cn['subscriptions']if s['user_id']==id];w.writerow(['cn',ss[0]['email'],id,cnvalid[id],'support_paid_projection'if cnvalid[id]else'free_expired',','.join(sorted({s['payment_provider']for s in ss})),','.join(sorted({s['status']for s in ss})),max((s['current_period_end']for s in ss),default='')if cnvalid[id]else'',True,'unknown',''])
for f in p.iterdir():
 if f.is_file():f.chmod(0o600)
p.chmod(0o700)
print(json.dumps(summary,ensure_ascii=False,indent=2))
