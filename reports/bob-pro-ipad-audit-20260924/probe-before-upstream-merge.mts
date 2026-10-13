// Read-only qualification of the exact candidate. Credentials and customer
// identifiers never enter output/artifacts; no purchases or grants are made.
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { parse } from 'dotenv';
import postgres from 'postgres';

const args = process.argv.slice(2);
const value = (flag: string) => args[args.indexOf(flag) + 1];
const deployment = value('--deployment');
const output = value('--out');
assert.ok(args.includes('--deployment') && args.includes('--out'));
assert.match(
  deployment,
  /^https:\/\/readout-[a-z0-9]+-castreader\.vercel\.app$/
);
const env = parse(await readFile('.vercel/.env.production.local'));
assert.equal(env.VERCEL_ENV, 'production');
const project = JSON.parse(await readFile('.vercel/project.json', 'utf8'));
assert.equal(project.projectId, 'prj_wYf9gRnrKR28vEUtOP9hY7ITa7tK');
const sql = postgres(env.DATABASE_URL, {
  max: 1,
  prepare: false,
  connect_timeout: 15,
});
const exec = promisify(execFile);
const directory = await mkdtemp(join(tmpdir(), 'pro-candidate-'));
let publicCases = 0;
let mobileConflictChecked = false;
let passed = false;
let phase = 'database-read';
async function request(path: string, token?: string) {
  const header = join(directory, 'headers');
  await writeFile(
    header,
    'Accept: application/json\nCache-Control: no-cache\n' +
      (token
        ? `Authorization: Bearer ${token}\nX-Auth-Provider: session\n`
        : ''),
    { mode: 0o600 }
  );
  const { stdout } = await exec(
    'vercel',
    [
      'curl',
      path,
      '--deployment',
      deployment,
      '--',
      '--silent',
      '--show-error',
      '--connect-timeout',
      '10',
      '--max-time',
      '30',
      '--retry',
      '2',
      '--retry-all-errors',
      '--retry-delay',
      '1',
      '--header',
      '@' + header,
      '--write-out',
      '\n__STATUS__:%{http_code}',
    ],
    { maxBuffer: 200_000, timeout: 125_000 }
  );
  const marker = stdout.lastIndexOf('\n__STATUS__:');
  assert.ok(marker >= 0);
  const status = Number(stdout.slice(marker + 12));
  if (status !== 200) {
    let parsed: any = {}; try { parsed = JSON.parse(stdout.slice(0, marker)); } catch {}
    const code = parsed.code || parsed.error?.code;
    console.error({ phase, httpStatus: status, responseCode: /^[A-Z0-9_]{1,80}$/.test(code) ? code : 'unclassified' });
  }
  assert.equal(
    status,
    200,
    'Candidate status must return authoritative membership'
  );
  return JSON.parse(stdout.slice(0, marker)).data;
}
try {
  const cases = await sql.begin('read only', async (q) => {
    await q`set local statement_timeout='15s'`;
    // One actual account per billing state, with effective entitlement across
    // all its subscriptions, so a second valid purchase is never revoked.
    const samples = await q`
      select distinct on (s.status) s.user_id, s.status,
        exists(select 1 from subscription live where live.user_id=s.user_id
          and live.product_id='castreader-pro'
          and live.status in ('active','pending_cancel','trialing')
          and live.current_period_end>now()) as expected_pro
      from subscription s where s.product_id='castreader-pro'
        and s.status in ('active','pending_cancel','trialing','past_due','expired')
        and s.payment_provider in ('stripe','apple_app_store','google_play')
      order by s.status,s.updated_at desc`;
    // Reuse an existing live session only for a GET, and only an already
    // recorded conflicting installation. This cannot create/transfer a grant.
    const conflicts = await q`
      select s.user_id,s.token,bad.analytics_anonymous_id,bad.stable_device_id,
        bad.app_version,bad.app_build,bad.storefront_country,
        exists(select 1 from subscription live where live.user_id=s.user_id
          and live.product_id='castreader-pro'
          and live.status in ('active','pending_cancel','trialing')
          and live.current_period_end>now()) as expected_pro
      from session s
      join mobile_growth_identity_links good on good.user_id=s.user_id
      join mobile_growth_identity_links bad on bad.stable_device_id=good.stable_device_id
        and bad.user_id<>s.user_id and bad.conflict_count>0
      where s.token like 'cms_%' and s.expires_at>now()+interval '7 days'
        and s.user_agent like 'CastReader-Mobile/%'
        and s.user_agent not like '%;route=cn%'
        and exists(select 1 from subscription failed where failed.user_id=s.user_id
          and failed.product_id='castreader-pro' and failed.status='past_due')
      order by s.created_at desc limit 1`;
    return { samples, conflicts };
  });
  assert.ok(cases.samples.some((row) => row.expected_pro));
  assert.ok(cases.samples.some((row) => !row.expected_pro));
  for (const row of cases.samples) {
    phase = `public-${row.status}`;
    const data = await request(
      '/api/pro/status?' + new URLSearchParams({ user_id: row.user_id })
    );
    assert.equal(
      data.pro,
      row.expected_pro,
      'Public status differs from effective account entitlement'
    );
    assert.equal(data.resolvedUserId, row.user_id);
    if (!row.expected_pro) assert.equal(data.plan, null);
    publicCases++;
  }
  for (const row of cases.conflicts) {
    phase = 'mobile-conflict';
    const params = new URLSearchParams();
    for (const [key, item] of Object.entries({
      device_id: row.stable_device_id,
      analytics_anonymous_id: row.analytics_anonymous_id,
      app_version: row.app_version,
      app_build: row.app_build,
      storefront_country: row.storefront_country,
    })) {
      if (item != null) params.set(key, String(item));
    }
    const data = await request(
      '/api/mobile/pro/status/v2?' + params,
      row.token
    );
    phase = 'mobile-conflict-pro';
    assert.equal(data.pro, row.expected_pro);
    phase = 'mobile-conflict-identity';
    assert.equal(data.resolvedUserId, row.user_id);
    phase = 'mobile-conflict-growth';
    assert.equal(data.growthConfig, null);
    phase = 'mobile-conflict-quotas';
    assert.equal(data.listenRemaining, 0);
    assert.equal(data.freeRemaining, 0);
    assert.equal(data.grantListenRemaining, 0);
    phase = 'mobile-conflict-unavailable';
    assert.ok(data.unavailableFields.includes('growthConfig'));
    mobileConflictChecked = true;
  }
  // If no conflict remains, keep future releases usable and explicitly record
  // that no live conflict was exercised. Unit coverage still enforces expiry.
  passed = true;
} catch (error) {
  // Fixed transport/SQL codes help diagnose qualification without logging any
  // arguments, response bodies, tokens, or customer identity.
  const errorCode =
    error && typeof error === 'object' && 'code' in error
      ? String(error.code)
      : 'qualification_failed';
  console.error({
    phase,
    errorCode: /^[A-Z0-9_]{1,40}$/.test(errorCode)
      ? errorCode
      : 'qualification_failed',
  });
  console.error(
    'Pro candidate qualification failed; no production aliases changed by this probe.'
  );
  process.exitCode = 1;
} finally {
  await sql.end();
  await rm(directory, { recursive: true, force: true });
  const result = {
    checkedAt: new Date().toISOString(),
    candidateHost: new URL(deployment).host,
    status: passed ? 'passed' : 'failed',
    phase,
    publicCases,
    mobileConflictChecked,
    billingWrites: 0,
    credentialOutput: false,
  };
  await writeFile(output, JSON.stringify(result, null, 2) + '\n', {
    mode: 0o600,
  });
  console.log(JSON.stringify(result));
}
