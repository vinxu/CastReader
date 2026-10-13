from pathlib import Path
import json,re,datetime,subprocess
root=Path('/Users/xuxuheng/.codex/worktrees/castreader-mac-parity/CastReader/reports/mac-parity-20261004/g09-google-long-explain')
meta=json.loads((root/'run.json').read_text())
data=(Path.home()/'Library/Containers/com.same.castreader/Data/Documents/reader-refocus.log').read_bytes()[meta['logByteOffset']:meta.get('endLogByteOffset')].decode(errors='replace')
lines=data.splitlines()
playing=[l for l in lines if 'AUDIO state reason=time-control actual=playing' in l]
cues=[l for l in lines if 'EXPLAIN subtitle cue' in l and (m:=re.search(r'clock=([\d.]+)',l)) and float(m[1])>0]
commits=[l for l in lines if 'GBOOKS page commit reason=auto' in l]
issues=[l for l in lines if re.search(r'(presentation.*timeout|anchor_ack_timeout|repeat_guard|blocked|plan failed|turn.*timeout|render.*timeout)',l,re.I)]
locations=[];last_location=None
for line in lines:
 m=re.search(r'GBOOKS location saved pg=(\S+)',line)
 if m:last_location=m[1]
 if 'GBOOKS page commit reason=auto' in line:locations.append(last_location)
first=playing[0][:12] if playing else None; last=cues[-1][:12] if cues else None
seconds=lambda s:sum(float(v)*f for v,f in zip(s.split(':'),[3600,60,1]))
status={'observedAt':datetime.datetime.now().astimezone().isoformat(),'firstPlayback':first,'lastPlaybackSubtitle':last,'conservativeSpanSeconds':round(seconds(last)-seconds(first),3) if first and last else 0,'automaticCommits':len(commits),'uniqueAutoLocators':len(set(locations)), 'autoLocators':locations,'subtitleCues':len(cues),'refreshCommits':data.count('GBOOKS page commit reason=refresh'),'manualCommits':data.count('GBOOKS page commit reason=manual'),'issues':issues[-12:]}
(root/'status.json').write_text(json.dumps(status,indent=2)+'\n');(root/'events.log').write_text('\n'.join(l for l in lines if re.search(r'(PAGINATION|EXPLAIN|GBOOKS (?:page commit|location saved|turn|next page|JS)|AUDIO (?:state|stage|item finished|queue complete))',l))+'\n')
print(json.dumps(status,indent=2))
pids=subprocess.run(['pgrep','-f','^/(private/)?tmp/CastReaderMacParity/Build/Products/Debug-maccatalyst/CastReaderMac.app/Contents/MacOS/CastReaderMac$'],capture_output=True,text=True).stdout.strip()
if pids:
 sample=subprocess.run(['ps','-o','pid=,etime=,%cpu=,rss=','-p',pids.splitlines()[0]],capture_output=True,text=True).stdout.strip()
 with (root/'resources.jsonl').open('a') as f:f.write(json.dumps({'at':status['observedAt'],'mainProcessOnly':sample})+'\n')
