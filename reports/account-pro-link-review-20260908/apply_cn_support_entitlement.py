"""Run on the CN host with sudo python3; credentials stay in host memory.

Modes: preview (read only), dry-run (transaction rolls back), apply, verify.
This script is specific to the reviewed and authorized customer case.
"""
import datetime
import json
import pathlib
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid

USER_ID = '72c42188-2e45-4a62-b7f9-4816594ffd24'
SOURCE_USER_ID = '4c3d911e-3a54-42c0-96c0-43f7a6f81801'
SOURCE_SUB_ID = '26ad75b5-3293-4af3-b93c-50313f8d22af'
SOURCE_ORDER_ID = 'e9b8dafc-579b-4fae-b7fe-db0c620a18bf'
EMAIL = 'igaory@gmail.com'
CASE = 'support-cross-region-20260908-' + SOURCE_SUB_ID
ROW_ID = str(uuid.uuid5(uuid.NAMESPACE_URL, CASE + ':' + USER_ID))
SUB_NO = CASE
SUB_ID = 'support:global:' + SOURCE_SUB_ID + ':cn:' + USER_ID
START = '2026-09-07 16:46:31.406'
END = '2027-09-07 16:46:31.406'
PROVIDER = 'support_adjustment'
MODE = sys.argv[1] if len(sys.argv) == 2 else ''
if MODE not in ('preview', 'dry-run', 'apply', 'verify'):
    raise SystemExit('Specify preview, dry-run, apply, or verify')


def quote(value):
    return "'" + value.replace("'", "''") + "'"


pid = subprocess.check_output(
    ['systemctl', 'show', '--property', 'MainPID', '--value', 'castreader'],
    text=True,
).strip()
environment = dict(
    item.split(b'=', 1)
    for item in pathlib.Path('/proc/' + pid + '/environ').read_bytes().split(b'\0')
    if b'=' in item
)
database_url = urllib.parse.urlparse(environment[b'DATABASE_URL'].decode())
assert database_url.hostname in ('localhost', '127.0.0.1', '::1')
database = urllib.parse.unquote(database_url.path.lstrip('/'))
assert database == 'castreader_cn_region_20260826', 'CN database changed'
del environment, database_url


def query(sql):
    result = subprocess.run(
        ['runuser', '-u', 'postgres', '--', 'psql', '-XqAt',
         '-v', 'ON_ERROR_STOP=1', '-d', database],
        input=sql, text=True, capture_output=True, cwd='/tmp',
    )
    if result.returncode:
        # None of our SQL contains credentials. Avoid displaying SQL/output
        # from session-token reads even in an unexpected database error.
        raise RuntimeError('Database operation failed; transaction not committed')
    return [json.loads(line) for line in result.stdout.splitlines() if line.strip()]


def snapshot():
    return query(f"""
BEGIN READ ONLY;
SET LOCAL statement_timeout='15s'; SET LOCAL TIME ZONE 'UTC';
SELECT json_build_object('kind','user','rows',coalesce(json_agg(t),'[]'::json))
FROM (SELECT id,email,email_verified FROM "user" WHERE id={quote(USER_ID)})t;
SELECT json_build_object('kind','accounts','rows',coalesce(json_agg(t),'[]'::json))
FROM (SELECT user_id,provider_id FROM account WHERE user_id={quote(USER_ID)})t;
SELECT json_build_object('kind','subscriptions','rows',coalesce(json_agg(t),'[]'::json))
FROM (SELECT id,subscription_no,subscription_id,user_id,user_email,status,
payment_provider,product_id,amount,currency,interval,interval_count,
current_period_start,current_period_end,created_at,updated_at,description,
subscription_result FROM subscription WHERE user_id={quote(USER_ID)} ORDER BY id)t;
SELECT json_build_object('kind','order_count','count',count(*)) FROM "order"
WHERE user_id={quote(USER_ID)};
SELECT json_build_object('kind','pending_deletion_count','count',count(*))
FROM account_deletion_request WHERE user_id={quote(USER_ID)} AND status='pending';
ROLLBACK;
""")


def mobile_status():
    # Read only this customer's existing Apple sessions; never print or save
    # their token, issue a replacement session, or change their device binding.
    sessions = query(f"""
BEGIN READ ONLY; SET LOCAL statement_timeout='10s'; SET LOCAL TIME ZONE 'UTC';
SELECT json_build_object('token',token,'created_at',created_at)
FROM session WHERE user_id={quote(USER_ID)}
AND user_agent='CastReader-Mobile/apple;route=cn'
AND token LIKE 'cms_%' AND expires_at > now() AT TIME ZONE 'UTC'
ORDER BY created_at DESC LIMIT 2;
ROLLBACK;
""")
    assert sessions, 'No existing active Apple mobile session available'
    results = []
    day = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).date()
    url = 'https://api.castreader.cn/api/mobile/pro/status/v2?local_date=' + str(day)
    for session in sessions:
        request = urllib.request.Request(url, headers={
            'Authorization': 'Bearer ' + session['token'],
            'X-Auth-Provider': 'session',
            'Accept': 'application/json',
        })
        try:
            with urllib.request.urlopen(request, timeout=25) as response:
                body = json.load(response)
                status = response.status
        except urllib.error.HTTPError as error:
            raise RuntimeError('Mobile status returned HTTP ' + str(error.code)) from None
        data = body.get('data') or {}
        account = data.get('account') or {}
        account_id = account.get('id') or account.get('userId')
        if account_id is not None:
            assert account_id == USER_ID, 'Mobile status account mismatch'
        if account.get('email') is not None:
            assert account['email'].lower() == EMAIL, 'Mobile status email mismatch'
        results.append({
            'httpStatus': status, 'responseCode': body.get('code'),
            'sessionCreatedAt': session['created_at'],
            'pro': data.get('pro'), 'plan': data.get('plan'),
            'accountId': account_id, 'accountEmail': account.get('email'),
        })
    return results


audit = {
    'case': CASE, 'type': 'customer_support_cross_region_entitlement',
    'source_region': 'global', 'source_user_id': SOURCE_USER_ID,
    'source_subscription_id': SOURCE_SUB_ID, 'source_order_id': SOURCE_ORDER_ID,
    'target_region': 'cn', 'target_user_id': USER_ID,
    'reason': 'Existing paid yearly Pro unavailable on CN Apple account; same verified email in both regions.',
    'new_charge_amount': 0, 'source_period_start_utc': START + 'Z',
    'source_period_end_utc': END + 'Z',
    'authorization': 'Workspace owner approved case-specific backend entitlement adjustment on 2026-09-08.',
}

print(json.dumps({'mode': MODE, 'case': CASE, 'entitlementId': ROW_ID,
                  'checkedAt': datetime.datetime.now(datetime.timezone.utc).isoformat()}))
if MODE == 'preview':
    print(json.dumps({'database': snapshot(), 'mobileStatus': mobile_status()}))
elif MODE in ('dry-run', 'apply'):
    metadata = quote(json.dumps(audit, ensure_ascii=False, separators=(',', ':')))
    transaction = f"""
BEGIN;
SET LOCAL statement_timeout='15s'; SET LOCAL lock_timeout='5s';
SET LOCAL TIME ZONE 'UTC';
DO $guard$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended({quote(USER_ID)},0));
  PERFORM 1 FROM "user" WHERE id={quote(USER_ID)} AND lower(email)={quote(EMAIL)}
    AND email_verified=true FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Target identity changed'; END IF;
  IF NOT EXISTS (SELECT 1 FROM account WHERE user_id={quote(USER_ID)} AND provider_id='apple')
    THEN RAISE EXCEPTION 'Apple identity missing'; END IF;
  IF EXISTS (SELECT 1 FROM account_deletion_request WHERE user_id={quote(USER_ID)} AND status='pending')
    THEN RAISE EXCEPTION 'Account deletion pending'; END IF;
  IF EXISTS (SELECT 1 FROM subscription WHERE user_id={quote(USER_ID)}
    AND product_id='castreader-pro' AND status IN ('active','pending_cancel','trialing')
    AND current_period_end > now() AT TIME ZONE 'UTC' AND id <> {quote(ROW_ID)})
    THEN RAISE EXCEPTION 'Target already has another active Pro entitlement'; END IF;
END $guard$;
WITH inserted AS (
INSERT INTO subscription (id,subscription_no,user_id,user_email,status,payment_provider,
subscription_id,subscription_result,product_id,description,amount,currency,interval,
interval_count,current_period_start,current_period_end,created_at,updated_at,
plan_name,product_name)
VALUES ({quote(ROW_ID)},{quote(SUB_NO)},{quote(USER_ID)},{quote(EMAIL)},'active',
{quote(PROVIDER)},{quote(SUB_ID)},{metadata},'castreader-pro',
'Customer support: honor existing globally purchased yearly Pro on verified CN Apple account; no additional charge.',
0,'usd','year',1,TIMESTAMP {quote(START)},TIMESTAMP {quote(END)},
now() AT TIME ZONE 'UTC',now() AT TIME ZONE 'UTC','CastReader Pro','CastReader Pro')
ON CONFLICT (subscription_no) DO NOTHING RETURNING id
)
SELECT json_build_object('insertedRows',count(*)) FROM inserted;
DO $verify$
BEGIN
IF NOT EXISTS (SELECT 1 FROM subscription WHERE id={quote(ROW_ID)}
AND user_id={quote(USER_ID)} AND subscription_no={quote(SUB_NO)}
AND subscription_id={quote(SUB_ID)} AND payment_provider={quote(PROVIDER)}
AND product_id='castreader-pro' AND status='active' AND amount=0
AND currency='usd' AND interval='year' AND interval_count=1
AND current_period_start=TIMESTAMP {quote(START)}
AND current_period_end=TIMESTAMP {quote(END)}
AND subscription_result::jsonb={metadata}::jsonb)
THEN RAISE EXCEPTION 'Entitlement readback mismatch'; END IF;
END $verify$;
{'ROLLBACK' if MODE == 'dry-run' else 'COMMIT'};
"""
    print(json.dumps({'transaction': query(transaction),
                      'committed': MODE == 'apply', 'database': snapshot()}))
elif MODE == 'verify':
    statuses = mobile_status()
    assert all(s['httpStatus'] == 200 and s['responseCode'] == 0
               and s['pro'] is True and s['plan'] == 'yearly' for s in statuses), 'Mobile Pro verification failed'
    print(json.dumps({'verified': True, 'mobileStatus': statuses, 'database': snapshot()}))
