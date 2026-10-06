from pathlib import Path
import json,re,datetime
root=Path('/Users/xuxuheng/.codex/worktrees/castreader-mac-parity/CastReader/reports/mac-parity-20261004/g09-google-reveal-long-read')
meta=json.loads((root/'run.json').read_text());data=Path('/Users/xuxuheng/Library/Containers/com.same.castreader/Data/Documents/reader-refocus.log').read_bytes()[meta['logByteOffset']:meta.get('endLogByteOffset')].decode('utf-8',errors='replace');lines=data.splitlines()
word=[l for l in lines if re.search(r'GBOOKS JS (?:w )?p\d+.* ov=',l)];commits=[l for l in lines if 'GBOOKS page commit reason=auto' in l]
issues=[l for l in lines if re.search(r'(presentation.*timeout|render.*timeout|anchor_ack_timeout|repeat_guard|playback anchor unavailable|resume.*failed|GBOOKS.*error)',l,re.I)]
locations=[];last_location=None
for line in lines:
 m=re.search(r'GBOOKS location saved pg=(\S+)',line)
 if m:last_location=m[1]
 if 'GBOOKS page commit reason=auto' in line:locations.append(last_location)
holds={};durations=[]
for line in lines:
 m=re.search(r'PAGINATION (visual_hold|visual_release) id=(\S+).*mono=([\d.]+)',line)
 if not m:continue
 if m[1]=='visual_hold':holds[m[2]]=float(m[3])
 elif m[2] in holds:durations.append((float(m[3])-holds.pop(m[2]))*1000)
durations.sort()
def seconds(line):
 h,m,s=map(float,line[:12].split(':'));return h*3600+m*60+s
status={'status':'OBSERVING','observedAt':datetime.datetime.now().astimezone().isoformat(),'firstWordAt':word[0][:12] if word else None,'latestWordAt':word[-1][:12] if word else None,'wordSpanSeconds':round(seconds(word[-1])-seconds(word[0]),3) if word else 0,'automaticCommits':len(commits),'uniqueAutoLocators':len(set(locations)), 'autoLocators':locations,'wordPaints':len(word),'missingWordOverlays':sum('ov=0' in l for l in word),'carryCommits':data.count('boundary carry committed'),'acknowledgedEndpointContinues':data.count('acknowledged_endpoint_continued'),'refreshCommits':data.count('GBOOKS page commit reason=refresh'),'manualCommits':data.count('GBOOKS page commit reason=manual'),'issues':issues[-10:],'visualHoldsCompleted':len(durations),'visualHoldMedianMs':round(durations[len(durations)//2],2) if durations else None,'visualHoldMaxMs':round(max(durations),2) if durations else None,'holdsWithoutExplicitRelease':list(holds), 'note':'Page signature log is truncated; compare full saved locators. Hold reset by queue replacement may omit explicit release, so unmatched log IDs do not establish a stuck decoder.'}
(root/'status.json').write_text(json.dumps(status,indent=2)+'\n');print(json.dumps(status,indent=2))
