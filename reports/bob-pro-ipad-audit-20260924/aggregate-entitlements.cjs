const fs=require('node:fs');
const req=require('node:module').createRequire('/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-pro-consistency-20260924/package.json');
const env=req('dotenv').parse(fs.readFileSync('/Users/xuxuheng/Documents/MyProject/readout-web/.env.local'));
const sql=req('postgres')(env.DATABASE_URL,{max:1,prepare:false,connect_timeout:15,idle_timeout:5});
(async()=>{
 const result=await sql.begin('read only',async q=>{
  await q`set local statement_timeout='15s'`;
  const states=await q`select payment_provider, status, count(*)::int as records, count(*) filter(where current_period_end > now())::int as future_period, count(*) filter(where current_period_end is null)::int as missing_period from subscription where product_id='castreader-pro' group by 1,2 order by 1,2`;
  const stores=await q`select payment_provider,status,subscription_result::jsonb->>'subscriptionState' as play_state,subscription_result::jsonb->>'castreaderNotificationType' as apple_notification,count(*)::int as records from subscription where product_id='castreader-pro' and payment_provider in ('apple_app_store','google_play') and status in ('active','trialing','pending_cancel') and current_period_end>now() group by 1,2,3,4 order by 1,2,3,4`;
  const graceImpact=await q`select count(*)::int as stripe_past_due, count(*) filter(where current_period_start<=now() and current_period_end>now() and current_period_start+interval '3 days'>=now())::int as formerly_granted_by_website from subscription where product_id='castreader-pro' and payment_provider='stripe' and status='past_due'`;
  const manual=await q`select payment_provider,plan_name,product_name,amount,currency,status,current_period_end::text,subscription_result from subscription where product_id='castreader-pro' and payment_provider in ('manual','manual_review') and status='active' and current_period_end>now()`;
  return {states,stores,graceImpact,manual:manual.map(({subscription_result,...row})=>({...row,resultKeys:(()=>{try{return Object.keys(JSON.parse(subscription_result||'{}'))}catch{return []}})()}))};
 });
 const report={checkedAt:new Date().toISOString(),...result};
 fs.writeFileSync(__dirname+'/entitlement-provider-aggregate.json',JSON.stringify(report,null,2)+'\n',{mode:0o600});
 console.log(JSON.stringify(report,null,2));
})().catch(e=>{console.log(JSON.stringify({error:e.name,code:e.code}));process.exitCode=1}).finally(()=>sql.end());
