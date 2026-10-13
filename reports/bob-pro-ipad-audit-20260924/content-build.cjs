const fs=require('node:fs');const {spawn}=require('node:child_process');
const root='/Users/xuxuheng/Documents/MyProject/.worktrees/castreader-content-pro-consistency-20260924';
const req=require('node:module').createRequire(root+'/package.json');
const production=req('dotenv').parse(fs.readFileSync(root+'/.vercel/.env.production.local'));
const publicCheck={appURLCorrect:production.NEXT_PUBLIC_APP_URL==='https://castreader.com',authURLCorrect:production.AUTH_URL==='https://castreader.com'};
if(!publicCheck.appURLCorrect||!publicCheck.authURLCorrect)throw new Error('Canonical build configuration mismatch');
// CLI sensitive placeholders are not runtime credentials. This local build
// verifies code with the existing authorized local DB only; Vercel supplies
// the unchanged production secrets to the remote candidate.
const local=req('dotenv').parse(fs.readFileSync('/Users/xuxuheng/Documents/MyProject/readout-web/.env.local'));
const env={...process.env,...Object.fromEntries(Object.entries(production).filter(([,v])=>v!=='[SENSITIVE]')),DATABASE_URL:local.DATABASE_URL,NODE_OPTIONS:'--max-old-space-size=6144',NEXT_TELEMETRY_DISABLED:'1'};
fs.rmSync(root+'/.env.local',{force:true});
const log=fs.openSync(__dirname+'/content-build.log','w',0o600);
const start=Date.now();
const child=spawn('pnpm',['build'],{cwd:root,env,stdio:['ignore',log,log]});
child.on('exit',code=>{fs.closeSync(log);const result={...publicCheck,code,elapsedSeconds:(Date.now()-start)/1000};fs.writeFileSync(__dirname+'/content-build-result.json',JSON.stringify(result,null,2)+'\n',{mode:0o600});console.log(JSON.stringify(result));process.exitCode=code??1;});
