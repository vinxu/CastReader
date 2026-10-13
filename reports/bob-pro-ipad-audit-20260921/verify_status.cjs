// Case-specific support verification. Read-only SQL; existing credentials stay
// in memory or curl stdin. Output deliberately excludes tokens and profiles.
const fs = require('node:fs');
const { createRequire } = require('node:module');
const requireBackend = createRequire('/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-pro-growth-conflict-20260921/package.json');
const env = requireBackend('dotenv').parse(fs.readFileSync('/Users/xuxuheng/Documents/MyProject/readout-web/.env.local'));
const sql = requireBackend('postgres')(env.DATABASE_URL, { max: 1, prepare: false, connect_timeout: 15, idle_timeout: 5 });
const [base, output, expectation = 'fixed'] = process.argv.slice(2);
if (!base || !output || !['fixed', 'broken'].includes(expectation)) throw new Error('base URL, output file and fixed/broken required');
const url = new URL(base);
if (url.protocol !== 'https:' || !(url.hostname === 'api.castreader.ai' || url.hostname.endsWith('-castreader.vercel.app'))) throw new Error('Unapproved verification host');
const candidate = url.hostname.endsWith('.vercel.app');
const userId = '78f67399-9d7e-489e-a367-8ccd7aef99e5';
const oldUserId = 'b2ca0005-ebc3-4a3b-8b37-2e47c155e53f';
const installIds = ['35802b47-a4bc-4819-bbd1-2aef1f7b907c', 'b5790700-2a2b-402e-9944-1bf5a31100c8', 'c99e9b0b-1eab-4347-a719-7e37b8b9a5d2'];
const { fetch: httpFetch, ProxyAgent } = requireBackend('undici');
const proxy = process.env.https_proxy || process.env.HTTPS_PROXY;
const dispatcher = proxy ? new ProxyAgent(proxy) : undefined;
let protectionToken;
async function request(path, token) {
  if (candidate) {
    if (!protectionToken) {
      // Same existing automation credential used by vercel curl. The CLI's
      // local child transport loses proxy/stdin, so use in-memory HTTP here.
      const project = await httpFetch('https://api.vercel.com/v9/projects/prj_wYf9gRnrKR28vEUtOP9hY7ITa7tK?teamId=team_T12jAJWADzok4cQ5gWZPVjw2', { dispatcher, headers: { Authorization: 'Bearer ' + fs.readFileSync(process.env.HOME + '/.config/castreader/vercel-token', 'utf8').trim() }, signal: AbortSignal.timeout(25000) });
      if (!project.ok) throw new Error('Project authentication failed');
      const settings = await project.json();
      protectionToken = Object.keys(settings.protectionBypass || {}).find(k => settings.protectionBypass[k].scope === 'automation-bypass');
      if (!protectionToken) throw new Error('Existing deployment credential unavailable');
    }
  }
  const response = await httpFetch(base + path, { dispatcher, headers: { Accept: 'application/json', 'X-Auth-Provider': 'session', ...(token ? { Authorization: 'Bearer ' + token } : {}), ...(protectionToken ? { 'x-vercel-protection-bypass': protectionToken } : {}) }, signal: AbortSignal.timeout(25000) });
  return { status: response.status, body: await response.json() };
}
async function snapshot() {
  return sql.begin('read only', async q => {
    await q`set local statement_timeout='15s'`;
    return {
      subscriptions: await q`select id,user_id,status,payment_provider,product_id,amount,currency,interval,current_period_start,current_period_end,updated_at from subscription where user_id in (${userId},${oldUserId}) order by id`,
      links: await q`select analytics_anonymous_id,stable_device_id,user_id,app_version,app_build,storefront_country,conflict_count,last_conflict_at from mobile_growth_identity_links where analytics_anonymous_id in ${q(installIds)} order by analytics_anonymous_id`,
      grants: await q`select analytics_anonymous_id,user_id,config_id,grant_listen_max,grant_listen_used,grant_explain_max,grant_explain_used from growth_config_assignments where analytics_anonymous_id in ${q(installIds)} order by analytics_anonymous_id`,
    };
  });
}
(async () => {
  const results = [];
  try {
    const before = await snapshot();
    const sessions = await sql.begin('read only', q => q`select distinct on (user_id,user_agent) user_id,user_agent,token from session where user_id in (${userId},${oldUserId}) and token like 'cms_%' and expires_at>now() order by user_id,user_agent,created_at desc`);
    const targets = sessions.filter(s => s.user_id === userId);
    if (targets.length < 2 || before.links.length !== 3) throw new Error('Case evidence changed');
    const capabilities = await request('/api/capabilities');
    for (const session of targets) {
      for (const link of before.links) {
        const params = new URLSearchParams({ device_id: link.stable_device_id, analytics_anonymous_id: link.analytics_anonymous_id, app_version: link.app_version, app_build: link.app_build, storefront_country: link.storefront_country, local_date: new Date().toISOString().slice(0, 10) });
        const r = await request('/api/mobile/pro/status/v2?' + params, session.token);
        const d = r.body.data || {};
        const expectedPro = expectation === 'fixed' || link.user_id === userId;
        let iosDecoderPassed;
        if (r.status === 200 && process.env.BOB_PRO_IOS_DECODER) {
          const decoded = require('node:child_process').spawnSync(process.env.BOB_PRO_IOS_DECODER, [], { input: JSON.stringify(r.body), encoding: 'utf8', timeout: 10000 });
          iosDecoderPassed = decoded.status === 0 && decoded.stdout.trim() === 'passed';
        }
        const passed = expectedPro ? r.status === 200 && d.pro === true && d.plan === 'yearly' && d.resolvedUserId === userId && d.cloneCanApply === true && (link.user_id === userId || (d.growthConfig === null && d.grantListenRemaining === undefined)) && iosDecoderPassed !== false : r.status === 409 && r.body.error === 'GROWTH_IDENTITY_CONFLICT';
        results.push({ kind: 'account-status', provider: session.user_agent, installId: link.analytics_anonymous_id, httpStatus: r.status, pro: d.pro, plan: d.plan, resolvedUserId: d.resolvedUserId, cloneCanApply: d.cloneCanApply, growthConfig: d.growthConfig, error: r.body.error, iosDecoderPassed, passed });
      }
    }
    const oldSession = sessions.find(s => s.user_id === oldUserId);
    if (oldSession && !before.subscriptions.some(s => s.user_id === oldUserId && ['active', 'trialing', 'pending_cancel'].includes(s.status) && new Date(s.current_period_end) > new Date())) {
      const params = new URLSearchParams({ analytics_anonymous_id: installIds[2], storefront_country: 'US', app_version: '1.2.41', app_build: '63' });
      const r = await request('/api/mobile/pro/status/v2?' + params, oldSession.token);
      results.push({ kind: 'free-conflict-remains-blocked', httpStatus: r.status, error: r.body.error, passed: r.status === 409 && r.body.error === 'GROWTH_IDENTITY_CONFLICT' });
    }
    const anonymous = await request('/api/mobile/pro/status/v2');
    results.push({ kind: 'anonymous-remains-rejected', httpStatus: anonymous.status, passed: anonymous.status === 401 });
    const after = await snapshot();
    const unchanged = JSON.stringify(before) === JSON.stringify(after);
    const evidence = { checkedAt: new Date().toISOString(), base, expectation, releaseId: capabilities.body.releaseId, commitSha: capabilities.body.commitSha, results, subscriptionAndGrowthRecordsUnchanged: unchanged, before, after, passed: results.every(r => r.passed) && unchanged };
    fs.writeFileSync(output, JSON.stringify(evidence, null, 2) + '\n');
    console.log(JSON.stringify({ output, base, commitSha: evidence.commitSha, checks: results.length, unchanged, passed: evidence.passed, results }, null, 2));
    if (!evidence.passed) process.exitCode = 1;
  } catch (error) {
    console.error(JSON.stringify({ error: error.name, code: error.code, completedChecks: results.length }));
    process.exitCode = 1;
  } finally { await sql.end(); await dispatcher?.close(); }
})();
