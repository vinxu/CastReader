// Case-scoped, read-only support audit. Existing session credentials remain in memory.
const fs = require('node:fs');
const { createRequire } = require('node:module');
const requireBackend = createRequire('/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-pro-growth-conflict-20260921/package.json');
const env = requireBackend('dotenv').parse(fs.readFileSync('/Users/xuxuheng/Documents/MyProject/readout-web/.env.local'));
const sql = requireBackend('postgres')(env.DATABASE_URL, { max: 1, prepare: false, connect_timeout: 15, idle_timeout: 5 });
const { fetch, ProxyAgent } = requireBackend('undici');
const proxy = process.env.https_proxy || process.env.HTTPS_PROXY;
const dispatcher = proxy ? new ProxyAgent(proxy) : undefined;
const userId = '78f67399-9d7e-489e-a367-8ccd7aef99e5';
const oldUserId = 'b2ca0005-ebc3-4a3b-8b37-2e47c155e53f';
const output = __dirname + '/current-api-verification.json';
async function snapshot() {
  return sql.begin('read only', async q => {
    await q`set local statement_timeout='15s'`;
    return {
      subscriptions: await q`select id,user_id,status,current_period_start,current_period_end,updated_at from subscription where user_id in (${userId},${oldUserId}) order by id`,
      links: await q`select analytics_anonymous_id,stable_device_id,user_id,app_version,app_build,storefront_country,conflict_count,last_conflict_at from mobile_growth_identity_links where user_id in (${userId},${oldUserId}) order by analytics_anonymous_id`,
      grants: await q`select analytics_anonymous_id,user_id,config_id,grant_listen_max,grant_listen_used,grant_explain_max,grant_explain_used from growth_config_assignments where user_id in (${userId},${oldUserId}) order by analytics_anonymous_id`,
    };
  });
}
async function get(path, token) {
  const response = await fetch('https://api.castreader.ai' + path, {
    dispatcher, redirect: 'error', signal: AbortSignal.timeout(25000),
    headers: { Accept: 'application/json', ...(token ? { Authorization: 'Bearer ' + token, 'X-Auth-Provider': 'session' } : {}) },
  });
  const body = await response.json();
  const d = body.data || {};
  return { httpStatus: response.status, pro: d.pro, plan: d.plan, resolvedUserId: d.resolvedUserId, quotaPolicy: d.quotaPolicy, listenRemaining: d.listenRemaining, freeRemaining: d.freeRemaining, growthConfig: d.growthConfig, cloneCanApply: d.cloneCanApply, error: body.error, code: body.code };
}
(async () => {
  try {
    const before = await snapshot();
    const sessions = await sql.begin('read only', q => q`select distinct on (user_agent) user_agent,created_at,token from session where user_id=${userId} and token like 'cms_%' and expires_at>now() order by user_agent,created_at desc`);
    const results = [];
    for (const session of sessions) {
      for (const installId of [null, '9018c3a3-ab6e-4871-8387-2517d5450c5a', 'c99e9b0b-1eab-4347-a719-7e37b8b9a5d2', 'b5790700-2a2b-402e-9944-1bf5a31100c8']) {
        const link = before.links.find(x => x.analytics_anonymous_id === installId);
        const params = new URLSearchParams({ local_date: new Date().toISOString().slice(0, 10) });
        if (link) for (const [k,v] of Object.entries({ device_id:link.stable_device_id, analytics_anonymous_id:installId, app_version:link.app_version, app_build:link.app_build, storefront_country:link.storefront_country })) if (v) params.set(k,v);
        results.push({ kind: 'mobile-status', provider: session.user_agent, sessionCreatedAt: session.created_at, installId, ...(await get('/api/mobile/pro/status/v2?' + params, session.token)) });
      }
    }
    // Current deployed source confirms this public display route never binds devices.
    results.push({ kind: 'web-extension-display-status', ...(await get('/api/pro/status?' + new URLSearchParams({ user_id:userId, fresh:'1' }))) });
    const after = await snapshot();
    const report = { checkedAt: new Date().toISOString(), results, subscriptionAndGrowthRecordsUnchanged: JSON.stringify(before) === JSON.stringify(after) };
    fs.writeFileSync(output, JSON.stringify(report,null,2)+'\n',{mode:0o600});
    console.log(JSON.stringify(report,null,2));
  } catch (error) { console.error(JSON.stringify({ error:error.name, code:error.code })); process.exitCode=1; }
  finally { await sql.end(); await dispatcher?.close(); }
})();
