import fs from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire('/Users/xuxuheng/Documents/MyProject/readout-web/package.json');
const env = require('dotenv').parse(fs.readFileSync('/tmp/castreader-core-audio-env-source-20260905/.vercel/.env.production.local'));
const origin = 'https://zqxgmqygirtpttnrvjpf.supabase.co';
const database = new URL(env.DATABASE_URL);
if (!decodeURIComponent(database.username).endsWith('.zqxgmqygirtpttnrvjpf')) throw new Error('database_project_mismatch');
const legacy = fs.readFileSync('/Users/xuxuheng/Documents/MyProject/cast-reader-api/reader-service/supabase_storage.py', 'utf8');
const assignment = name => legacy.match(new RegExp(`^\\s*${name}\\s*=\\s*["']([^"']+)["']`, 'm'))?.[1];
if (new URL(assignment('SUPABASE_URL')).origin !== origin) throw new Error('authoritative_origin_mismatch');
const key = assignment('SUPABASE_KEY');
const claim = JSON.parse(Buffer.from(key.split('.')[1], 'base64url').toString());
if (claim.role !== 'service_role' || (claim.ref && claim.ref !== 'zqxgmqygirtpttnrvjpf')) throw new Error('credential_scope_mismatch');
const start = '2026-09-05T18:50:21Z';
const end = '2026-09-06T00:24:11Z';
const fields = [
  'eventName:properties->>event_name', 'platform:properties->>client_platform',
  'serviceRoute:properties->>client_service_route', 'ingressRoute:properties->>ingress_service_route',
  'routeMismatch:properties->>service_route_mismatch', 'readSession:properties->>read_session_id',
  'explainSession:properties->>explain_session_id', 'result:properties->>result',
  'endReason:properties->>endReason', 'stopReason:properties->>stop_reason',
  'errorCode:properties->>errorCode', 'errorType:properties->>error_type',
  'errorMessage:properties->>error_message', 'latencyMs:properties->>latencyMs',
  'playbackSeconds:properties->>playbackSeconds', 'durationSec:properties->>duration_sec',
  'voiceId:properties->>voiceId', 'contentSource:properties->>contentSource',
  'completionBucket:properties->>completionBucket', 'blocksStarted:properties->>blocksStarted',
  'blocksCompleted:properties->>blocksCompleted', 'errorStage:properties->>errorStage',
  'legacyError:properties->>error', 'legacyStage:properties->>stage',
  'language:properties->>language', 'speed:properties->>speed',
  'clientVersion:properties->>client_version', 'clientBuild:properties->>client_build',
  'environment:properties->>environment',
  'legacyErrorCode:properties->>error_code', 'legacyErrorStage:properties->>error_stage',
  'httpStatus:properties->>http_status', 'contentOrigin:properties->>content_origin',
];
const enums = {
  platform: ['ios','android','extension','web'], route: ['cn','global','unknown'],
  result: ['success','failed','cancelled','canceled','completed','stopped','error','interrupted'],
  reason: ['completed','user_stop','user_pause','user_cancel','cancelled','canceled','error','failed','quota_exceeded','quota_limit','navigation','mode_switch','background','interrupted','unknown','document_end','natural_end','view_disappeared','content_changed'],
  source: ['kindle','weread','kobo','web','text','pdf','epub','photo','camera','file','youtube','url','clipboard'],
};
const safeEnum = (value, values) => value == null || value === '' ? 'unspecified' : values.includes(String(value)) ? String(value) : 'other';
const eventSafe = s => /^[a-z][a-z0-9_]{0,69}$/.test(s ?? '') ? s : 'other';
const codeSafe = s => s == null || s === '' ? 'unspecified' : /^[a-z][a-z0-9_]{0,69}$/.test(s) ? s : 'unclassified_format';
function errorClass(r) {
  const s = [r.errorCode,r.legacyErrorCode,r.errorType,r.errorMessage,r.legacyError,r.httpStatus].filter(Boolean).join(' ').toLowerCase();
  if (!s) return 'none';
  if (/502|bad gateway/.test(s)) return 'http_502';
  if (/503/.test(s)) return 'http_503';
  if (/500/.test(s)) return 'http_500';
  if (/504|gateway timeout/.test(s)) return 'http_504';
  if (/timeout|timed out|超时/.test(s)) return 'timeout';
  if (/cancel|abort/.test(s)) return 'cancel_or_abort';
  if (/credential|auth|401|403/.test(s)) return 'credential_or_auth';
  if (/quota|limit|429/.test(s)) return 'quota_or_limit';
  if (/network|connection|fetch/.test(s)) return 'network';
  if (/decode|audio|playback/.test(s)) return 'audio_or_decode';
  if (/unknown/.test(s)) return 'unknown';
  return 'other';
}
function stats(values) {
  const v = values.filter(Number.isFinite).sort((a,b)=>a-b);
  const q = p => v.length ? v[Math.min(v.length-1,Math.ceil(v.length*p)-1)] : null;
  return { n:v.length, p50:q(.5), p95:q(.95), max:v.at(-1)??null, sum:v.reduce((a,b)=>a+b,0) };
}
function aggregate(rows) {
  const groups = new Map();
  for (const r of rows) {
    const k = JSON.stringify([eventSafe(r.eventName || r.event_name || r.event || r.legacy_event),safeEnum(r.platform || r.client_platform,enums.platform),safeEnum(r.serviceRoute,enums.route),safeEnum(r.ingressRoute,enums.route),codeSafe(r.result),codeSafe(r.endReason || r.stopReason),errorClass(r),codeSafe(r.errorCode || r.legacyErrorCode),codeSafe(r.errorStage || r.legacyErrorStage || r.legacyStage),safeEnum(r.environment,['production','development','test','staging']),safeEnum(r.contentOrigin,['real','demo']),/^\d{3}$/.test(r.httpStatus??'')?Number(r.httpStatus):null]);
    if (!groups.has(k)) groups.set(k, {rows:[], devices:new Set()});
    const g=groups.get(k);g.rows.push(r);if(r.device_id || r.analytics_anonymous_id) g.devices.add(r.device_id || r.analytics_anonymous_id);
  }
  const records=[...groups].map(([k,g])=>{
    const [event,platform,clientRoute,ingressRoute,result,endReason,errorClass,errorCode,errorStage,environment,contentOrigin,httpStatus]=JSON.parse(k);
    return {event,platform,clientRoute,ingressRoute,result,endReason,errorClass,errorCode,errorStage,environment,contentOrigin,httpStatus,count:g.rows.length,devices:g.devices.size,
      routeMismatchCount:g.rows.filter(r=>String(r.routeMismatch)==='true').length,
      firstObserved:g.rows.map(r=>r.received_at || r.created_at).sort()[0],lastObserved:g.rows.map(r=>r.received_at || r.created_at).sort().at(-1),
      latencyMs:stats(g.rows.filter(r=>r.latencyMs!=null).map(r=>Number(r.latencyMs))),
      playbackSeconds:stats(g.rows.filter(r=>r.playbackSeconds!=null || r.durationSec!=null).map(r=>Number(r.playbackSeconds??r.durationSec)))};
  });
  const sessionMap = new Map();
  for (const r of rows) {
    const name=r.eventName || r.event_name;
    if(!r.readSession || !name?.startsWith('read_')) continue;
    const key=[r.device_id || r.analytics_anonymous_id,r.readSession].join(':');
    if(!sessionMap.has(key))sessionMap.set(key,[]);
    sessionMap.get(key).push({...r,name});
  }
  const cohorts=[];
  for(const platform of ['ios','android']) {
    const sessions=[...sessionMap.values()].filter(rs=>rs.some(r=>r.name==='read_start' && (r.platform || r.client_platform)===platform));
    const failing=sessions.filter(rs=>rs.some(r=>r.name==='read_end' && r.result==='failed'));
    const failurePatterns=new Map();
    for(const rs of failing) {
      const r=rs.find(r=>r.name==='read_end' && r.result==='failed');
      const first=rs.find(r=>r.name==='read_start');
      const voice=first?.voiceId;
      const voiceFamily=typeof voice==='string' && /clone|custom|gift/i.test(voice) ? 'clone_or_custom' : typeof voice==='string' && /^(af_|am_|bf_|bm_|zf_|zm_|jf_|jm_|hf_|hm_|ff_|ef_|pf_|if_)/.test(voice) ? 'preset_kokoro' : 'unknown';
      const version=/^\d{1,3}(\.\d{1,3}){1,3}$/.test(first?.clientVersion??'')?first.clientVersion:'unknown';
      const language=/^[a-z]{2,3}(-[A-Za-z]{2,4})?$/.test(first?.language??'')?first.language:'unknown';
      const presetVoice=voiceFamily==='preset_kokoro' && /^[a-z]{2}_[a-z0-9_]{1,30}$/.test(voice)?voice:null;
      const k=JSON.stringify([codeSafe(r.errorCode),codeSafe(r.errorStage),codeSafe(r.endReason),voiceFamily,safeEnum(first?.contentSource,enums.source),rs.some(x=>x.name==='read_first_audio'),safeEnum(first?.environment,['production','development','test','staging']),version,language,presetVoice]);
      const p=failurePatterns.get(k)??{n:0,devices:new Set()};p.n++;p.devices.add(r.device_id || r.analytics_anonymous_id);failurePatterns.set(k,p);
    }
    cohorts.push({platform,startedDistinctSessions:sessions.length,withFirstAudio:sessions.filter(rs=>rs.some(r=>r.name==='read_first_audio')).length,
      withFailureEnd:failing.length,withSuccessEnd:sessions.filter(rs=>rs.some(r=>r.name==='read_end' && r.result==='success')).length,
      withoutEndWithinWindow:sessions.filter(rs=>!rs.some(r=>r.name==='read_end')).length,
      failurePatterns:[...failurePatterns].map(([k,v])=>{const [errorCode,errorStage,endReason,voiceFamily,contentSource,hadFirstAudio,environment,clientVersion,language,presetVoice]=JSON.parse(k);return {errorCode,errorStage,endReason,voiceFamily,contentSource,hadFirstAudio,environment,clientVersion,language,presetVoice,sessions:v.n,devices:v.devices.size};})});
  }
  return {rows:rows.length,devices:new Set(rows.map(r=>r.device_id || r.analytics_anonymous_id).filter(Boolean)).size,groups:records,readSessionCohorts:cohorts};
}
async function collect(table, clock, baseFields) {
  const rows=[];let count=null;let page=0;
  for (;page<100;page++) {
    const url = new URL(`/rest/v1/${table}`,origin);
    url.searchParams.set('select',[...baseFields,...fields].join(','));
    url.searchParams.append(clock,`gte.${start}`);url.searchParams.append(clock,`lt.${end}`);
    const idColumn=table==='analytics_events'?'id':'event_id';
    url.searchParams.set('order',`${clock}.asc,${idColumn}.asc`);url.searchParams.set('limit','1000');url.searchParams.set('offset',String(page*1000));
    if(table==='analytics_events') url.searchParams.set('event',process.argv.includes('--errors-only')?'in.(tts_error,quickread_pipeline_error)':'in.(reading_start,reading_stop,reading_end,reading_abandon,tts_error,perf_metric,playback_progress,playback_resumed,quickread_pipeline_start,quickread_pipeline_done,quickread_pipeline_error,quickread_player_open,quickread_video_complete,quickread_live_done)');
    const response=await fetch(url,{headers:{apikey:key,Authorization:`Bearer ${key}`,Prefer:'count=exact'},signal:AbortSignal.timeout(25000),redirect:'error'});
    if (!response.ok) {let body={};try{body=await response.json()}catch{};return {table,clock,httpStatus:response.status,errorCode:body.code??'unavailable',complete:false};}
    const range=response.headers.get('content-range')??'';const total=range.split('/')[1];if(total && total!=='*')count=Number(total);
    const data=await response.json();rows.push(...data);
    if(data.length<1000 || (count!=null && rows.length>=count)) break;
  }
  const rowIdColumn=table==='analytics_events'?'id':'event_id';
  const unique=[...new Map(rows.map(r=>[r[rowIdColumn],r])).values()];
  return {table,clock,pages:page+1,expectedRows:count,rawRows:rows.length,duplicateRows:rows.length-unique.length,complete:count==null ? page<100 : unique.length===count,scope:table==='analytics_events'?(process.argv.includes('--errors-only')?'tts_error and quickread_pipeline_error only':'reading and explanation event allowlist'):'all accepted mobile events',...aggregate(unique)};
}
try {
  const results=[];
  for (const [table,clock,base] of [
    ['analytics_events','created_at',['id','event','device_id','created_at']],
    ['mobile_funnel_events','received_at',['event_id','event_name','legacy_event','analytics_anonymous_id','client_platform','received_at']],
  ]) {if(process.argv.includes('--errors-only') && table!=='analytics_events')continue;const result=await collect(table,clock,base);results.push(result);console.log(JSON.stringify({table,complete:result.complete,rows:result.rows,status:result.httpStatus??200}));}
  const out={schema:'castreader.global-client-observation.v1',since:start,untilExclusive:end,queriedAtUtc:new Date().toISOString(),readOnly:true,tlsCertificateVerification:true,
    source:'same Global database project via authenticated HTTPS PostgREST',
    limitations:['analytics_events created_at can be client-controlled; mobile_funnel received_at is server-clocked.','Tables overlap and must not be summed.','Device counts are installations, not verified unique people; manual testing cannot be excluded with certainty.','Starts and ends inside one window are not a cohort completion rate.','No raw event properties, identifiers, content or credentials are persisted.'],results};
  fs.writeFileSync(new URL(process.argv.includes('--errors-only')?'./legacy-error-observation.json':'./client-observation.json',import.meta.url),JSON.stringify(out,null,2)+'\n');
} catch (e) {console.log(JSON.stringify({ok:false,errorCode:e.code??e.name}));process.exitCode=1;}
