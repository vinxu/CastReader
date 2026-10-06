from pathlib import Path
import re,json
r=Path('/Users/xuxuheng/.codex/worktrees/castreader-mac-parity/CastReader/reports/mac-parity-20261004/g09-google-reveal-long-read');m=json.loads((r/'run.json').read_text());lines=Path('/Users/xuxuheng/Library/Containers/com.same.castreader/Data/Documents/reader-refocus.log').read_bytes()[m['logByteOffset']:m.get('endLogByteOffset')].decode().splitlines()
def sec(l):
 h,m,s=map(float,l[:12].split(':'));return 3600*h+60*m+s
words=[(i,l) for i,l in enumerate(lines) if re.search(r'GBOOKS JS (?:w )?p\d+.* ov=',l)]
gaps=[]
for (i,a),(j,b) in zip(words,words[1:]):
 gap=sec(b)-sec(a)
 if gap>3:
  within=lines[max(0,i-12):j];gaps.append({'from':a[:12],'to':b[:12],'seconds':round(gap,3),'refresh':any('reason=refresh' in l for l in within),'autoPage':any('reason=auto' in l for l in within),'shortOpeningBuffer':any('short_opening_ready' in l for l in within),'ttsRequests':sum('TTS transport response' in l for l in within)})
result={'note':'Includes both normal-word and retained-carry DOM range paint events. Word-paint interval includes sentence pauses and speech generation; it is not measured silent-audio time.','gapsOver3Seconds':gaps}
(r/'word-gap-audit.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
