/** Node.js 22+. No dependencies, generation, recording upload, or payment. */
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const origin = 'https://voice.castreader.com';
const bases = new Set([`${origin}/v1`, 'https://voice.castreader.cn/v1']);
export const recovery = {
  missing_key: 'Verify and activate at /request-access; create a key in the console. Keep it on your server.',
  invalid_api_key: 'Check the key in your server environment. Replace expired or revoked keys; never paste secrets into a prompt.',
  expired_api_key: 'This key has expired. Create or rotate a key in the console, then update the server secret and rerun the check.',
  admission_paused: 'New work is temporarily paused. Existing downloads can remain available. Check service status before rerunning.',
  account_unavailable: 'This account or workspace cannot use the API. Check its status in the console; do not retry with another identity to bypass restrictions.',
  insufficient_scope: 'Grant speech:generate, voices:read and usage:read to this key. Check its voice restriction.',
  no_ready_voice: 'Open Console → Playground and choose a ready library voice. A pending custom voice must finish preparation.',
  voice_not_found: 'Use an authorized voice ID from this workspace and execution region, not a display name or preset key.',
  unsupported_language: 'Use a language listed by this region’s models endpoint. Do not silently fall back to English.',
  voice_language_unverified: 'This voice is not enabled for the requested language. Choose a compatible voice; do not silently change the input language.',
  text_language_mismatch: 'Match TTS_LANGUAGE to the actual input text. A page locale is not a synthesis language.',
  text_limit_exceeded: 'Use a short first-check input within the returned limit. The queued-job limit may be different.',
  insufficient_balance: 'Check remaining trial, its expiry/daily allowance, and API wallet credit. The check does not top up.',
  regional_voice_required: 'Choose a voice in the returned execution region; recordings are not copied between regions.',
  invalid_route: 'Stop: the route did not return an approved API origin. Do not forward the key elsewhere.',
  rate_limit_exceeded: 'Wait for Retry-After before rerunning. This check never submits a replacement job.',
};
const fail = (code, extra = {}) => Object.assign(new Error(code), {code, ...extra});

export async function checkConnection({apiKey, language='en', text='Hello. This is my first connection check.', voiceId, fetchImpl=fetch} = {}) {
  const checks=[];
  let stage='input';
  try {
    if(!apiKey || /[\r\n]/.test(apiKey)) throw fail('missing_key');
    if(typeof text!=='string'||!text.isWellFormed()) throw fail('invalid_text');
    text=text.replace(/\r\n?/g,'\n').normalize('NFC').trim();
    if(!text || Array.from(text).length>500)throw fail('text_limit_exceeded');
    if(!/^[a-z]{2}$/.test(language))throw fail('unsupported_language');
    if(voiceId && !/^voice_[a-f0-9]{32}$/.test(voiceId))throw fail('voice_not_found');
    async function json(url, {auth=true,body}={}) {
      let res;
      try {res=await fetchImpl(url,{redirect:'error',signal:AbortSignal.timeout(20000),method:body?'POST':'GET',headers:{...(auth?{Authorization:`Bearer ${apiKey}`} : {}),...(body?{'Content-Type':'application/json'}:{})},...(body?{body:JSON.stringify(body)}:{})});}
      catch {throw fail('network_error');}
      const raw=await res.text();
      if(raw.length>1024*1024)throw fail('invalid_response');
      let value;try{value=JSON.parse(raw);}catch{throw fail('invalid_response');}
      if(!res.ok)throw fail(/^[a-z0-9_]{1,70}$/.test(value.error?.code||'')?value.error.code:'api_error',{httpStatus:res.status,retryAfter:res.headers.get('retry-after')});
      return value;
    }
    stage='public_configuration';
    const facts=await json(`${origin}/integration-manifest.json`,{auth:false});
    if(!facts.capabilities?.service_enabled || !facts.capabilities?.new_work_admission_enabled)throw fail('admission_paused');
    checks.push({stage,status:'passed',pricePerMillion: facts.pricing?.amount_per_million_characters});
    stage='authentication_and_region';
    const route=await json(`${origin}/v1/route${voiceId?'?voice_id='+encodeURIComponent(voiceId):''}`);
    if(!bases.has(route.base_url))throw fail('invalid_route');
    const base=route.base_url;
    checks.push({stage,status:'passed',region:route.region});
    stage='language_and_length';
    const model=(await json(base+'/models')).data?.find(m=>m.id==='clone-v1');
    if(!model?.languages?.includes(language))throw fail('unsupported_language');
    if(!Number.isSafeInteger(model.max_characters)||Array.from(text).length>model.max_characters)throw fail('text_limit_exceeded');
    checks.push({stage,status:'passed',language,characters:Array.from(text).length,shortRequestLimit:model.max_characters});
    stage='authorized_ready_voice';
    let selected, cursor='', seen=new Set();
    for(let page=0;page<50;page++) {
      const list=await json(base+'/voices?limit=100'+(cursor?'&cursor='+encodeURIComponent(cursor):''));
      if(!Array.isArray(list.data))throw fail('invalid_response');
      selected=voiceId?list.data.find(v=>v.id===voiceId&&v.status==='ready'):list.data.find(v=>v.status==='ready'&&v.default_voice_key==='narrator')||list.data.find(v=>v.status==='ready');
      if(selected)break;
      if(!list.has_more)break;
      if(!list.next_cursor||seen.has(list.next_cursor))throw fail('invalid_pagination');
      cursor=list.next_cursor;seen.add(cursor);
    }
    if(!selected)throw fail(voiceId?'voice_not_found':'no_ready_voice');
    if(!/^voice_[a-f0-9]{32}$/.test(selected.id))throw fail('invalid_response');
    const voiceRoute=await json(`${origin}/v1/route?voice_id=${encodeURIComponent(selected.id)}`);
    if(!bases.has(voiceRoute.base_url)||voiceRoute.base_url!==base)throw fail('invalid_route');
    checks.push({stage,status:'passed',voiceId:selected.id,voiceName:selected.name});
    stage='authorization_and_estimate';
    const estimate=await json(base+'/usage/estimate',{body:{model:'clone-v1',voice_id:selected.id,text,language,output_format:'mp3'}});
    if(estimate.reservation_created!==false)throw fail('invalid_response');
    if(estimate.balance_sufficient!==true)throw fail('insufficient_balance');
    checks.push({stage,status:'passed',billableCharacters:estimate.billable_characters,trialCharacters:estimate.trial_characters,estimatedChargeUSD:estimate.estimated_charge_usd,maximumChargeUSD:estimate.maximum_charge_usd});
    return {version:1,ok:true,generated:false,checks,next:'Metadata and authorization checks passed. Submit one short request only when ready; use the checkpointed starter for generation and recovery.',limitations:['Not a live synthesis or audio-quality test.','Model health, queue capacity and key/project monthly budgets can still prevent generation.','Voice listing may initialize built-in workspace references; it does not synthesize or charge audio.','The estimate is a balance snapshot, not a reservation.']};
  } catch(error) {
    const code=error.code||'check_failed';
    return {version:1,ok:false,generated:false,checks,failedAt:stage,error:{code,httpStatus:error.httpStatus,retryAfter:error.retryAfter,action:recovery[code]||'Inspect this stage and the documented API error. No generation was submitted. Keep keys and private IDs out of public reports.'}};
  }
}

if(process.argv[1]&&import.meta.url===pathToFileURL(resolve(process.argv[1])).href){
  if(process.argv.length>2){console.error('No CLI key or flags. Set CASTREADER_API_KEY in your server environment; optional TTS_LANGUAGE, TTS_TEXT and VOICE_ID.');process.exitCode=2;}
  else {const result=await checkConnection({apiKey:process.env.CASTREADER_API_KEY,language:process.env.TTS_LANGUAGE||'en',text:process.env.TTS_TEXT||'Hello. This is my first connection check.',voiceId:process.env.VOICE_ID});console.log(JSON.stringify(result,null,2));process.exitCode=result.ok?0:1;}
}
