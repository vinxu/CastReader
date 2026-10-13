const fs = require('node:fs');
const { createRequire } = require('node:module');
const rq = createRequire('/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-pro-consistency-20260924/package.json');
const env = rq('dotenv').parse(fs.readFileSync('/Users/xuxuheng/Documents/MyProject/readout-web/.env.local'));
const sql = rq('postgres')(env.DATABASE_URL, { max: 1, prepare: false, connect_timeout: 15, idle_timeout: 5 });
const { fetch, ProxyAgent } = rq('undici');
const dispatcher = new ProxyAgent('http://127.0.0.1:17890');
const emails = ['bobfabienzinga@gmail.com'];
const secret = fs.readFileSync(process.env.HOME + '/.config/castreader/pro-internal-secret.txt', 'utf8').trim();
const write = (name, value) => fs.writeFileSync(__dirname + '/' + name, JSON.stringify(value, null, 2), { mode: 0o600 });
async function snapshot() {
  return sql.begin('read only', async q => {
    await q`set local statement_timeout='15s'`;
    const users = await q`select id,email,blocked_at::text from public."user" where lower(email) in ${q(emails)} order by email`;
    const ids = users.map(x => x.id);
    const subscriptions = await q`select id,user_id,status,payment_provider,subscription_id,payment_user_id,product_id,interval,amount,currency,current_period_start::text,current_period_end::text,updated_at::text,exists(select 1 from subscription live where live.user_id=s.user_id and live.product_id='castreader-pro' and live.status in ('active','trialing','pending_cancel') and live.current_period_end>now()) as effective_pro from subscription s where user_id in ${q(ids)} order by user_id,created_at`;
    const orders = await q`select user_id,status,payment_provider,product_id,amount,currency,payment_amount,payment_currency,paid_at::text,created_at::text,subscription_id,invoice_id from public."order" where user_id in ${q(ids)} order by created_at desc limit 40`;
    const accounts = await q`select user_id,provider_id,account_id from account where user_id in ${q(ids)} order by user_id,provider_id`;
    const devices = await q`select user_id,device_id from pro_device_link where user_id in ${q(ids)} order by user_id,device_id`;
    return { users, subscriptions, orders, accounts, devices };
  });
}
async function request(url, init = {}) {
  const start = Date.now();
  try {
    const response = await fetch(url, { dispatcher, redirect: 'error', signal: AbortSignal.timeout(25000), ...init });
    const body = await response.json(), d = body.data || {};
    return { http: response.status, pro: d.pro, allowed: d.allowed, plan: d.plan, resolvedUserId: d.resolvedUserId, freeRemaining: d.freeRemaining, error: body.code || body.error, elapsedMs: Date.now() - start };
  } catch (e) { return { transportError: e.name, elapsedMs: Date.now() - start }; }
}
(async () => {
  try {
    const before = await snapshot(); write('account-snapshot.private.json', before);
    const checks = [];
    for (const user of before.users) {
      const identities = [['canonical', 'user_id', user.id], ['email', 'email', user.email]];
      for (const a of before.accounts.filter(x => x.user_id === user.id && x.provider_id === 'google')) identities.push(['google-sub', 'user_id', a.account_id]);
      for (const host of ['https://castreader.com', 'https://api.castreader.ai']) {
        for (const [identity, key, value] of identities) checks.push({ email: user.email, host, identity, ...(await request(host + '/api/pro/status?' + new URLSearchParams({ [key]: value, fresh: '1' }))) });
        checks.push({ email: user.email, host, identity: 'worker-consume-false', ...(await request(host + '/api/pro/entitlement', { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + secret }, body: JSON.stringify({ user_id: user.id, consume: false }) })) });
      }
    }
    const after = await snapshot();
    const report = { checkedAt: new Date().toISOString(), checks, billingAndDeviceRecordsUnchanged: JSON.stringify(before) === JSON.stringify(after) };
    write('live-account-results.private.json', report);
    console.log(JSON.stringify({ checkedAt: report.checkedAt, unchanged: report.billingAndDeviceRecordsUnchanged, cases: before.users.map(u => ({ email: u.email, subscriptions: before.subscriptions.filter(s => s.user_id === u.id).map(s => ({ state: s.status, interval: s.interval, provider: s.payment_provider, end: s.current_period_end, effectivePro: s.effective_pro })), checks: checks.filter(c => c.email === u.email).map(c => ({ host: c.host, identity: c.identity, http: c.http, pro: c.pro, allowed: c.allowed, error: c.error, transportError: c.transportError })) })) }, null, 2));
  } finally { await sql.end(); await dispatcher.close(); }
})().catch(e => { console.log({ error: e.name, code: e.code }); process.exitCode = 1; });
