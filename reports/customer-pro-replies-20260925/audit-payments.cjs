// Read-only, case-scoped billing audit. No sessions, billing changes or quota consumption.
const fs = require('node:fs');
const {createRequire} = require('node:module');
const rq=createRequire('/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-pro-growth-conflict-20260921/package.json');
const env=rq('dotenv').parse(fs.readFileSync('/Users/xuxuheng/Documents/MyProject/readout-web/.env.local'));
const sql=rq('postgres')(env.DATABASE_URL,{max:1,prepare:false,connect_timeout:15,idle_timeout:5});
const {fetch,ProxyAgent}=rq('undici');
const proxy=process.env.https_proxy||process.env.HTTPS_PROXY;
const dispatcher=proxy?new ProxyAgent(proxy):undefined;
const emails=['bobfabienzinga@gmail.com','dengxinyun5@gmail.com','eileenmcfrln@gmail.com'];
async function status(host,user){
 try{const r=await fetch(host+'/api/pro/status?'+new URLSearchParams({user_id:user.id,fresh:'1'}),{dispatcher,redirect:'error',signal:AbortSignal.timeout(20000),headers:{Accept:'application/json'}});const b=await r.json();return {host,email:user.email,http:r.status,pro:b.data?.pro,plan:b.data?.plan,canonicalMatches:b.data?.resolvedUserId===user.id};}
 catch(e){return {host,email:user.email,error:e.name,code:e.code};}
}
(async()=>{try{
const data=await sql.begin('read only',async q=>{
 await q`set local statement_timeout='15s'`;
 const users=await q`select id,email,blocked_at::text from public."user" where lower(email) in ${q(emails)} order by email`;
 const ids=users.map(u=>u.id);
 if(!ids.length)throw Error('NO_CASE_USERS');
 const subscriptions=await q`select u.email,s.status,s.payment_provider,s.interval,s.amount,s.currency,s.current_period_start::text,s.current_period_end::text,s.updated_at::text,s.deleted_at::text,s.subscription_result from subscription s join public."user" u on u.id=s.user_id where s.user_id in ${q(ids)} and s.product_id='castreader-pro' order by u.email,s.created_at desc`;
 const orders=await q`select u.email,o.status,o.payment_provider,o.payment_interval,o.amount,o.currency,o.payment_amount,o.payment_currency,o.paid_at::text,o.created_at::text,o.updated_at::text from public."order" o join public."user" u on u.id=o.user_id where o.user_id in ${q(ids)} and o.product_id='castreader-pro' order by u.email,o.created_at desc limit 30`;
 return {users,subscriptions:subscriptions.map(s=>{let p={};try{p=JSON.parse(s.subscription_result||'{}')}catch{};const invoice=typeof p.latest_invoice==='object'?p.latest_invoice:null;const {subscription_result,...rest}=s;return {...rest,providerSnapshot:{status:p.status,trialStart:p.trial_start,trialEnd:p.trial_end,cancelAtPeriodEnd:p.cancel_at_period_end,latestInvoiceStatus:invoice?.status,latestInvoicePaid:invoice?.paid,latestInvoiceAmountPaid:invoice?.amount_paid}}}),orders};
});
const probes=await Promise.all(data.users.flatMap(user=>['https://castreader.com','https://api.castreader.ai'].map(host=>status(host,user))));
const result={checkedAt:new Date().toISOString(),readOnly:true,...data,probes};
fs.writeFileSync(__dirname+'/payment-review.private.json',JSON.stringify(result,null,2)+'\n',{mode:0o600});
console.log(JSON.stringify({...result,users:result.users.map(({email,blocked_at})=>({email,blocked:!!blocked_at}))},null,2));
} catch(e){console.error(JSON.stringify({error:e.name,code:e.code}));process.exitCode=1;} finally{await sql.end();await dispatcher?.close()}})();
