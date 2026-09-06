"""Read only fixed QuickRead log tags; never export text or error messages."""
import collections,json,re
from datetime import datetime,timezone
from pathlib import Path
START='2026-09-06T21:23:00+00:00'
END='2026-09-06T21:29:00+00:00'
start=datetime.fromisoformat(START);end=datetime.fromisoformat(END)
tags=('compose-block error:', 'fast-block0 error:', 'extract-block error:', 'extract-plan error:')
# Only a leading ISO timestamp (optionally preceded by a PM2 process label) is trusted.
leading=re.compile(r'^(?:\d+\|[^|]{1,40}\|\s*)?(?:\[)?(20\d{2}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)')
results=[]
for p in (Path('/root/.pm2/logs/quickread-out.log'),Path('/root/.pm2/logs/quickread-error.log')):
 s=p.stat();raw=p.read_bytes();lines=raw.decode('utf-8','replace').splitlines()
 trusted=[];inside=0;matched=collections.Counter();unattributed=collections.Counter();outside=collections.Counter()
 for line in lines:
  match=leading.match(line);stamp=None
  if match:
   try:stamp=datetime.fromisoformat(match.group(1).replace('Z','+00:00')).replace(tzinfo=timezone.utc) if not re.search(r'(Z|[+-]\d{2}:?\d{2})$',match.group(1)) else datetime.fromisoformat(match.group(1).replace('Z','+00:00'))
   except ValueError:pass
  if stamp:trusted.append(stamp)
  in_window=stamp is not None and start<=stamp<end
  if in_window:inside+=1
  for tag in tags:
   if tag in line:
    if in_window:matched[tag]+=1
    elif stamp is None:unattributed[tag]+=1
    else:outside[tag]+=1
 results.append({'file':p.name,'bytesRead':len(raw),'fileBytesBeforeRead':s.st_size,'completeFileRead':len(raw)>=s.st_size,'mtimeUtc':datetime.fromtimestamp(s.st_mtime,timezone.utc).isoformat(),'linesRead':len(lines),'trustedTimestampedLines':len(trusted),'firstTrustedTimestampUtc':min(trusted).isoformat() if trusted else None,'lastTrustedTimestampUtc':max(trusted).isoformat() if trusted else None,'windowTimestampedLines':inside,'fixedErrorTagCountsInWindow':dict(matched),'undatedFixedErrorTagCounts':dict(unattributed),'outsideWindowFixedErrorTagCounts':dict(outside)})
print(json.dumps({'schema':'castreader.quickread-fixed-log-window.v1','readOnly':True,'productionModified':False,'synthesisStarted':False,'rawUserContentExported':False,'startUtc':START,'endUtc':END,'files':results,'limitations':['Only explicit leading ISO timestamps are trusted; naive timestamps are provisionally treated as UTC.','Undated errors are not attributed to the incident. No matched fixed tags does not prove the service or network had no failure.','No client/server request correlation is available; no arbitrary error content, request body or user identity was exported.']}))
