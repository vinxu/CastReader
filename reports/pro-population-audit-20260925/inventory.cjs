const fs=require('node:fs');const {createRequire}=require('node:module');
const rq=createRequire('/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-pro-growth-conflict-20260921/package.json');
const env=rq('dotenv').parse(fs.readFileSync('/Users/xuxuheng/Documents/MyProject/readout-web/.env.local'));
const watchdog=setTimeout(()=>{console.error('AUDIT_TIMEOUT');process.exit(2)},90000);
const sql=rq('postgres')(env.DATABASE_URL,{max:1,prepare:false,connect_timeout:15,idle_timeout:5});
const safeSnapshot=p=>{let j={};try{j=JSON.parse(p||'{}')}catch{};return {status:j.status,trialStart:j.trial_start,trialEnd:j.trial_end,cancelAtPeriodEnd:j.cancel_at_period_end,subscriptionState:j.subscriptionState,expiryTime:j.expiryTime,environment:j.environment,notificationType:j.castreaderNotificationType,renewalStatus:j.autoRenewStatus,invoiceStatus:typeof j.latest_invoice==='object'?j.latest_invoice?.status:undefined,invoicePaid:typeof j.latest_invoice==='object'?j.latest_invoice?.paid:undefined,keys:Object.keys(j)};};
(async()=>{try{const snapshot=await sql.begin('read only',async q=>{
 await q`set local statement_timeout='15s'`;
 console.error('stage: clock');
 const clock=(await q`select now()::text as now`)[0].now;
 console.error('stage: subscriptions');
 const subs=await q`select s.id,s.user_id,u.email,u.blocked_at::text,s.payment_provider,s.status,s.interval,s.amount,s.currency,s.plan_name,s.product_name,s.subscription_id,s.subscription_result,s.current_period_start::text,s.current_period_end::text,s.created_at::text,s.updated_at::text,s.deleted_at::text from subscription s left join public."user" u on u.id=s.user_id where s.product_id='castreader-pro' order by s.user_id,s.created_at`;
 console.error('subscriptions fetched:',subs.length);
 const users=[...new Set(subs.map(s=>s.user_id))];
 console.error('stage: orders');
 const orders=await q`select user_id,payment_provider,status,payment_interval,amount,currency,payment_amount,payment_currency,paid_at::text,created_at::text from public."order" where product_id='castreader-pro' and user_id in ${q(users)} order by user_id,created_at`;
 console.error('orders fetched:',orders.length);
 const sizes=await q`select c.relname,c.reltuples::bigint as estimated_rows from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname in ('subscription','analytics_events','mobile_funnel_events','sessions','pro_daily_usage','pro_listen_usage','apple_subscription_periods','apple_subscription_shadow','mobile_listen_usage_event','mobile_quickread_job','tts_usage_ledger')`;
 console.error('stage: metadata');
 const tables=await q`select table_name from information_schema.tables where table_schema='public' and (table_name like '%usage%' or table_name like '%subscription%' or table_name like '%entitlement%' or table_name like '%request%' or table_name like '%billing%') order by table_name`;
 return {checkedAt:clock,subscriptions:subs.map(({subscription_result,...s})=>({...s,snapshot:safeSnapshot(subscription_result)})),orders,sizes,tables};
});
const at=new Date(snapshot.checkedAt);const groups=new Map();for(const s of snapshot.subscriptions){if(!groups.has(s.user_id))groups.set(s.user_id,{id:s.user_id,email:s.email,blocked:!!s.blocked_at,subscriptions:[]});groups.get(s.user_id).subscriptions.push(s)}
for(const g of groups.values()){
 g.valid=g.subscriptions.filter(s=>!g.blocked&&['active','pending_cancel','trialing'].includes(s.status)&&s.current_period_end&&new Date(s.current_period_end+'Z')>at);
 g.expectedPro=g.valid.length>0;
 g.failed=g.subscriptions.some(s=>['past_due','unpaid','incomplete','incomplete_expired'].includes(s.status));
 g.expired=g.subscriptions.some(s=>s.current_period_end&&new Date(s.current_period_end+'Z')<=at);
 g.expiredTrial=g.subscriptions.some(s=>(s.status==='trialing'&&s.current_period_end&&new Date(s.current_period_end+'Z')<=at)||(s.snapshot.trialEnd&&s.snapshot.trialEnd*1000<=at.getTime()));
 g.paidOrders=snapshot.orders.filter(o=>o.user_id===g.id&&o.status==='paid'&&(o.payment_amount??o.amount)>0).length;
}
snapshot.accounts=[...groups.values()];fs.writeFileSync(__dirname+'/inventory.private.json',JSON.stringify(snapshot,null,2)+'\n',{mode:0o600});
const counts={};for(const s of snapshot.subscriptions){const k=s.payment_provider+'/'+s.status;counts[k]=(counts[k]||0)+1}
const summary={checkedAt:snapshot.checkedAt,subscriptionRecords:snapshot.subscriptions.length,accounts:groups.size,expectedPro:snapshot.accounts.filter(g=>g.expectedPro).length,expectedFree:snapshot.accounts.filter(g=>!g.expectedPro).length,failedWithoutOtherValid:snapshot.accounts.filter(g=>g.failed&&!g.expectedPro).length,failedWithOtherValid:snapshot.accounts.filter(g=>g.failed&&g.expectedPro).length,expiredWithoutOtherValid:snapshot.accounts.filter(g=>g.expired&&!g.expectedPro).length,trialEndedWithoutOtherValid:snapshot.accounts.filter(g=>g.expiredTrial&&!g.expectedPro).length,counts,sizes:snapshot.sizes,tables:snapshot.tables};
fs.writeFileSync(__dirname+'/inventory-summary.json',JSON.stringify(summary,null,2)+'\n',{mode:0o600});console.log(JSON.stringify(summary,null,2));
}catch(e){console.error(JSON.stringify({error:e.name,code:e.code}));process.exitCode=1;}finally{clearTimeout(watchdog);await sql.end({timeout:5})}})();
