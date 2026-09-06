#!/usr/bin/env python3
"""Read-only log grouping; submitted text is hashed inside the US host only."""
from pathlib import Path
from datetime import datetime, timezone
import collections
import hashlib
import json
import re
import time

root=Path('/workspace/castreader-runtime/releases/20260906-kokoro-repeated-digits-us-r133/api/src')
ansi=re.compile(r'\x1b\[[0-9;]*m')
pattern=re.compile(r'^(\d\d:\d\d:\d\d [AP]M)\s*\|\s*(INFO|DEBUG|WARNING|ERROR|CRITICAL)\s*\|\s*([A-Za-z0-9_]+):(\d+)\s*\|\s*(.*)$')
groups={};sources=collections.Counter();langs=collections.Counter();characterCounts=collections.Counter();pending_chars=None
p=Path('/var/log/onstart.log');size=p.stat().st_size;offset=max(0,size-16*1024*1024)
with p.open('rb') as f:
 f.seek(offset);f.readline()
 while f.tell()<size:
  s=ansi.sub('',f.readline().decode(errors='replace').strip());m=pattern.match(s)
  if not m:continue
  at=datetime.strptime('2026-09-06 '+m.group(1),'%Y-%m-%d %I:%M:%S %p').replace(tzinfo=timezone.utc).isoformat()
  if not '2026-09-06T13:23:00+00:00'<=at<='2026-09-06T13:32:59+00:00':continue
  source=m.group(3)+':'+m.group(4);msg=m.group(5);sources[source]+=1
  if source=='text_processor:159':
   k=re.fullmatch(r'Starting smart split for (\d+) chars',msg)
   pending_chars=int(k.group(1)) if k else None
   if pending_chars is not None:characterCounts[pending_chars]+=1
  if source=='tts_service:427':
   k=re.match(r"Using lang_code '([^']+)'",msg)
   if k and k.group(1) in ('a','b','en','en-us','en-gb','zh','z','de','fr','ja','j','pt','p','es','e','it','i','hi','h','f'):langs[k.group(1)]+=1
  if source not in ('text_processor:271','text_processor:296','text_processor:308'):continue
  k=re.search(r": '(.*)' \((\d+) tokens\)$",msg)
  if not k:continue
  prefix=k.group(1);hashed=hashlib.sha256(prefix.encode()).hexdigest()
  if hashed not in groups:groups[hashed]={'loggedPrefixSHA256':hashed,'count':0,'firstUTC':at,'lastUTC':at,'wholeRequestTextCharCounts':collections.Counter(),'loggedPrefixCharCount':len(prefix)}
  g=groups[hashed];g['count']+=1;g['lastUTC']=at
  if pending_chars is not None:g['wholeRequestTextCharCounts'][pending_chars]+=1

out={'schema':'castreader.upstream-burst-patterns.v1','readOnly':True,'userTextExported':False,'windowUTC':['2026-09-06T13:23:00Z','2026-09-06T13:32:59Z'],'logClockTimezone':list(time.tzname),'requestTextLengthCounts':characterCounts,'languageCounts':langs,'chunkPrefixGroups':sorted(groups.values(),key=lambda v:v['count'],reverse=True)[:8], 'uniqueLoggedPrefixCount':len(groups),'provenanceConclusion':'Repeated identical logged prefixes can establish repeated inputs, but cannot identify probe/retry/user intent. Logged prefix is first50 characters plus possible ellipsis, not full input text.'}
ranges={'services/tts_service.py':[(58,71),(132,168),(377,398),(417,445),(561,589)],'services/text_processing/text_processor.py':[(157,159),(329,334)],'inference/kokoro_v1.py':[(895,915),(930,956)],'core/playback_diagnostics.py':[(50,65),(71,103)],'main.py':[(24,35)]}
out['sourceEvidence']=[]
for rel,spans in ranges.items():
 raw=(root/rel).read_bytes();lines=raw.decode().splitlines();out['sourceEvidence'].append({'path':str(root/rel),'sha256':hashlib.sha256(raw).hexdigest(),'lines':[{'line':i+1,'code':lines[i]}for a,b in spans for i in range(a-1,min(len(lines),b))]})
p=Path('/workspace/castreader-runtime/proxy-releases/us-tts-origin-proxy-20260906-v1/r133_stable_proxy.py');raw=p.read_bytes();lines=raw.decode().splitlines()
out['sourceEvidence'].append({'path':str(p),'sha256':hashlib.sha256(raw).hexdigest(),'lines':[{'line':i+1,'code':lines[i]}for a,b in [(35,38),(301,312),(402,423),(460,471),(492,516),(676,679)]for i in range(a-1,b)]})
print(json.dumps(out,sort_keys=True))
