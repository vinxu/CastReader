// Read-only case audit. Do not print credentials, session tokens or log bodies.
const fs = require('node:fs');
const { createRequire } = require('node:module');
const { promisify } = require('node:util');
const execFile = promisify(require('node:child_process').execFile);
const req = createRequire('/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-pro-growth-conflict-20260921/package.json');
const { fetch, ProxyAgent } = req('undici');
const proxy = process.env.https_proxy || process.env.HTTPS_PROXY;
const dispatcher = proxy ? new ProxyAgent(proxy) : undefined;
const userId = '78f67399-9d7e-489e-a367-8ccd7aef99e5';
const oldUserId = 'b2ca0005-ebc3-4a3b-8b37-2e47c155e53f';
const subscriptionId = 'sub_1UHUj3RV6kkh5M6r2fh2QZn1';
const save = (name, data) => fs.writeFileSync(`${__dirname}/${name}.json`, JSON.stringify(data, null, 2)+'\n', {mode:0o600});
async function logs(query, status, limit = 500) {
  const args = ['logs', '--project', 'prj_wYf9gRnrKR28vEUtOP9hY7ITa7tK', '--scope', 'castreader', '--environment', 'production', '--since', '2026-09-22T20:00:00Z', '--until', '2026-09-24T06:55:00Z', '--query', query, '--limit', String(limit), '--json', '--non-interactive'];
  if (status) args.push('--status-code', status);
  const token = fs.readFileSync(require('node:os').homedir()+'/.config/castreader/vercel-token','utf8').trim();
  try {
    const {stdout,stderr} = await execFile('vercel', args, {cwd:'/Users/xuxuheng/Documents/MyProject/readout-web', env:{...process.env,VERCEL_TOKEN:token}, timeout:45000, maxBuffer:12*1024*1024});
    const rows = stdout.split('\n').flatMap(line=>{try{return [JSON.parse(line)]}catch{return []}});
    const items = rows.map(row=>{
      const text = JSON.stringify(row.logs || [])+' '+(row.message || '');
      return {
        timestamp: row.timestamp, requestPath: row.requestPath?.split('?')[0], status: row.responseStatusCode,
        level: row.level, deploymentId: row.deploymentId, domain: row.domain,
        markers: ['GROWTH_IDENTITY_CONFLICT','SESSION_EXPIRED','INVALID_SESSION','SESSION_ROUTE_MISMATCH','status temporarily unavailable','Pro status is temporarily unavailable','[mobile/pro/status/v2] unavailable','clone policy unavailable','signature verification failed','handle error','No such subscription','resource_missing','timeout','TIMED_OUT'].filter(s=>text.toLowerCase().includes(s.toLowerCase())),
        matchesCaseSubscription: text.includes(subscriptionId),
      };
    });
    const statusCounts = {}; for (const item of items) statusCounts[item.status]=(statusCounts[item.status]||0)+1;
    return {query,status,limit,returned:rows.length,possiblyTruncated:rows.length>=limit,statusCounts,items,cliNote:stderr.replace(/\x1b\[[0-9;]*m/g,'').slice(0,300)};
  } catch(e) { return {query,status,error:e.code||e.name,killed:e.killed,signal:e.signal, note:String(e.stderr||'').slice(0,500)}; }
}
async function domains() {
  const result=[];
  for (const host of ['castreader.com','castreader.ai','api.castreader.ai']) {
    const start=Date.now();
    const params=new URLSearchParams({user_id:userId,fresh:'1'});
    try {
      let url=`https://${host}/api/pro/status?${params}`; const hops=[];
      for (let i=0;i<3;i++) {
        const response=await fetch(url,{dispatcher,redirect:'manual',signal:AbortSignal.timeout(20000)});
        hops.push({host:new URL(url).host,status:response.status});
        if ([301,302,303,307,308].includes(response.status)) {
          const next=new URL(response.headers.get('location'),url);
          if(!['castreader.com','www.castreader.com','castreader.ai','api.castreader.ai'].includes(next.host)) throw new Error('UnexpectedRedirect');
          url=next.href;continue;
        }
        const body=await response.json();const data=body.data||{};
        result.push({host,hops,elapsedMs:Date.now()-start,pro:data.pro,plan:data.plan,resolvedUserId:data.resolvedUserId,code:body.code,cacheControl:response.headers.get('cache-control')});break;
      }
    }catch(e){result.push({host,elapsedMs:Date.now()-start,error:e.name,code:e.cause?.code});}
  }
  return result;
}
async function database() {
  const env=req('dotenv').parse(fs.readFileSync('/Users/xuxuheng/Documents/MyProject/readout-web/.env.local'));
  const sql=req('postgres')(env.DATABASE_URL,{max:1,prepare:false,connect_timeout:15,idle_timeout:5});
  try { return await sql.begin('read only',async q=>{
    await q`set local statement_timeout='15s'`;
    const links=await q`select device_id,user_id from pro_device_link where user_id in (${userId},${oldUserId})`;
    const installs=await q`select analytics_anonymous_id,stable_device_id,user_id,app_version,conflict_count,last_conflict_at,last_linked_at from mobile_growth_identity_links where user_id in (${userId},${oldUserId})`;
    const devices=[...new Set([...links.map(x=>x.device_id),...installs.flatMap(x=>[x.analytics_anonymous_id,x.stable_device_id])])];
    const mobile=await q`select analytics_anonymous_id,event_name,count(*)::int as count,min(received_at) as first_received,max(received_at) as last_received from mobile_funnel_events where analytics_anonymous_id in ${q(devices)} and received_at>='2026-09-22T20:00:00Z' group by 1,2 order by 1,2`;
    const errors=await q`select device_id,event,extension_version,created_at,properties->>'reason' as reason,properties->>'httpStatus' as http_status,properties->>'apiCode' as api_code,properties->>'apiMessage' as api_message,properties->>'endpoint' as endpoint from analytics_events where device_id in ${q(devices)} and created_at>='2026-09-19T00:00:00Z' and event in ('pro_status_error','listen_track_error') order by created_at desc limit 150`;
    const sessions=await q`select user_agent, count(*)::int as count,min(created_at)::text as first_created,max(created_at)::text as last_created,min(expires_at)::text as min_expires,max(expires_at)::text as max_expires from session where user_id=${userId} and token like 'cms_%' group by user_agent`;
    return {links,installs,mobile,errors,sessions};
  }); } finally {await sql.end();}
}
(async()=>{
  const mode=process.argv[2];
  let result;
  if(mode==='logs') result=await Promise.all([logs('/api/mobile/pro/status/v2','4xx'),logs('/api/mobile/pro/status/v2','5xx'),logs('/api/pro/status','5xx'),logs('handle error',null,100),logs('No such subscription',null,100)]);
  else if(mode==='client-errors') result=await Promise.all([logs('/api/mobile/pro/status/v2','409',100),logs('/api/mobile/pro/status/v2','401',100)]);
  else if(mode==='domains') result=await domains();
  else if(mode==='database') result=await database();
  else throw new Error('Expected logs, domains or database');
  save(`query-diagnostics-${mode}`,{checkedAt:new Date().toISOString(),result});
  console.log(JSON.stringify(mode==='logs'?result.map(({items,...rest})=>({...rest,examples:items?.slice(0,4),caseMatches:items?.filter(x=>x.matchesCaseSubscription)})):result,null,2));
})().catch(e=>{console.error(JSON.stringify({error:e.name,code:e.code}));process.exitCode=1}).finally(async()=>{await dispatcher?.close()});
