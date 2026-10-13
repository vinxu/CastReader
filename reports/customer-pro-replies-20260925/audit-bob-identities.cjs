const fs=require('node:fs');const {createRequire}=require('node:module');
const rq=createRequire('/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-pro-growth-conflict-20260921/package.json');
const env=rq('dotenv').parse(fs.readFileSync('/Users/xuxuheng/Documents/MyProject/readout-web/.env.local'));
const sql=rq('postgres')(env.DATABASE_URL,{max:1,prepare:false,connect_timeout:15,idle_timeout:5});
(async()=>{try{
const r=await sql.begin('read only',async q=>{
 await q`set local statement_timeout='15s'`;
 const bob='bobfabienzinga@gmail.com';
 const users=await q`select id,email,name,created_at::text from public."user" where lower(email)=${bob} or id in ('78f67399-9d7e-489e-a367-8ccd7aef99e5','b2ca0005-ebc3-4a3b-8b37-2e47c155e53f') or lower(name) like '%fabien%zinga%' or lower(email) like '%bobfabien%' order by created_at`;
 const ids=users.map(x=>x.id);
 const accounts=await q`select user_id,provider_id,created_at::text from account where user_id in ${q(ids)}`;
 const subscriptions=await q`select user_id,user_email,status,payment_provider,product_id,interval,amount,currency,current_period_start::text,current_period_end::text,updated_at::text from subscription where user_id in ${q(ids)} or lower(user_email)=${bob} order by created_at desc limit 30`;
 const orders=await q`select user_id,user_email,payment_email,payment_user_name,status,payment_provider,product_id,payment_interval,amount,currency,payment_amount,payment_currency,paid_at::text,created_at::text,updated_at::text from public."order" where user_id in ${q(ids)} or lower(user_email)=${bob} or lower(payment_email)=${bob} or lower(payment_user_name) like '%fabien%zinga%' order by created_at desc limit 30`;
 return {users,accounts,subscriptions,orders};
});
const out={checkedAt:new Date().toISOString(),readOnly:true,scope:'Exact Bob email, previously resolved canonical and legacy account IDs, full-name/email variants, linked subscriptions and checkout/payment email',...r};fs.writeFileSync(__dirname+'/bob-identities.private.json',JSON.stringify(out,null,2)+'\n',{mode:0o600});console.log(JSON.stringify(out,null,2));
}catch(e){console.error(JSON.stringify({error:e.name,code:e.code}));process.exitCode=1;}finally{await sql.end();}})();
