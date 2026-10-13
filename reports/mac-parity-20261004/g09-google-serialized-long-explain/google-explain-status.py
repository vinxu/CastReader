from pathlib import Path
import json,re,datetime,subprocess
root=Path('/Users/xuxuheng/.codex/worktrees/castreader-mac-parity/CastReader/reports/mac-parity-20261004/g09-google-serialized-long-explain')
meta=json.loads((root/'run.json').read_text())
data=(Path.home()/'Library/Containers/com.same.castreader/Data/Documents/reader-refocus.log').read_bytes()[meta['logByteOffset']:meta.get('endLogByteOffset')].decode(errors='replace')
lines=data.splitlines()
playing=[l for l in lines if 'AUDIO state reason=time-control actual=playing' in l]
cues=[l for l in lines if 'EXPLAIN subtitle cue' in l and (m:=re.search(r'clock=([\d.]+)',l)) and float(m[1])>0]
commits=[l for l in lines if 'GBOOKS page commit reason=auto' in l]
issues=[l for l in lines if re.search(r'(presentation.*timeout|anchor_ack_timeout|repeat_guard|blocked|plan failed|turn.*timeout|render.*timeout|timed out)',l,re.I)]
locations=[];last_location=None
for line in lines:
 m=re.search(r'GBOOKS location saved pg=(\S+)',line)
 if m:last_location=m[1]
 if 'GBOOKS page commit reason=auto' in line:locations.append(last_location)
completed_media=0.0; finished_media=0; staged=None; started_media=False
for line in lines:
 stage=re.search(r'AUDIO stage segment=(\S+).* duration=([\d.]+)',line)
 if stage: staged=(stage[1],float(stage[2]));started_media=False
 if 'AUDIO state reason=time-control actual=playing' in line:started_media=True
 ended=re.search(r'AUDIO item finished segment=(\S+)',line)
 if ended and staged and started_media and ended[1]==staged[0]:
  completed_media+=staged[1];finished_media+=1;staged=None;started_media=False
first=playing[0][:12] if playing else None; last=cues[-1][:12] if cues else None
seconds=lambda s:sum(float(v)*f for v,f in zip(s.split(':'),[3600,60,1]))
status={'observedAt':datetime.datetime.now().astimezone().isoformat(),'firstPlayback':first,'lastPlaybackSubtitle':last,'conservativeSpanSeconds':round(seconds(last)-seconds(first),3) if first and last else 0,'completedMediaSeconds':round(completed_media,3), 'finishedMediaItems':finished_media, 'automaticCommits':len(commits),'uniqueAutoLocators':len(set(locations)), 'autoLocators':locations,'subtitleCues':len(cues),'refreshCommits':data.count('GBOOKS page commit reason=refresh'),'manualCommits':data.count('GBOOKS page commit reason=manual'),'issues':issues[-12:], 'sourceReveals':data.count('GBOOKS reflow reveals explanation source'), 'deferredContinuations':data.count('GBOOKS explain continuation waits for source reveal'), 'reflowRemainderRestarts':data.count('GBOOKS explain continues newly visible reflow remainder')}
(root/'status.json').write_text(json.dumps(status,indent=2)+'\n');(root/'events.log').write_text('\n'.join(l for l in lines if re.search(r'(PAGINATION|EXPLAIN|GBOOKS (?:page commit|location saved|turn|next page|JS|reflow reveals explanation|explain continuation|explain continues newly)|AUDIO (?:state|stage|item finished|queue complete))',l))+'\n')
print(json.dumps(status,indent=2))
pids=subprocess.run(['pgrep','-f','^/(private/)?tmp/CastReaderMacParity/Build/Products/Debug-maccatalyst/CastReaderMac.app/Contents/MacOS/CastReaderMac$'],capture_output=True,text=True).stdout.strip()
if pids:
 sample=subprocess.run(['ps','-o','pid=,etime=,%cpu=,rss=','-p',pids.splitlines()[0]],capture_output=True,text=True).stdout.strip()
 with (root/'resources.jsonl').open('a') as f:f.write(json.dumps({'at':status['observedAt'],'mainProcessOnly':sample})+'\n')

# Queue completion -> first subsequent audible media, including cold TTS waits.
gaps=[];ended=None
for line in lines:
 if 'AUDIO queue complete' in line: ended=line[:12]
 if 'AUDIO state reason=time-control actual=playing' in line and ended:
  gaps.append({'queueCompleted':ended,'nextPlayback':line[:12],'seconds':round(seconds(line[:12])-seconds(ended),3)})
  ended=None
(root/'queue-gaps.json').write_text(json.dumps({'scope':'Completed audio queues to next actual playing event; does not measure the duration of all possible in-item buffering.','intervals':gaps,'maxSeconds':max((g['seconds'] for g in gaps),default=0)},indent=2)+'\n')
