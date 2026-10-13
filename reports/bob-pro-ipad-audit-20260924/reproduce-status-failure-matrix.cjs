// Local fault injection against the exact deployed handler. No production writes or requests.
const fs=require('node:fs');
const vm=require('node:vm');
const assert=require('node:assert/strict');
const {execFileSync}=require('node:child_process');
const {createRequire}=require('node:module');
const ts=createRequire('/Users/xuxuheng/.codex/worktrees/safari-app-store-20260924/readout-desktop/package.json')('typescript');
const root='/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-pro-growth-conflict-20260921';
const ref='0a4c32edb5b7e89107a7e927afc2afccf630a051';
function extract(file,name){
 const src=execFileSync('git',['show',`${ref}:${file}`],{cwd:root,encoding:'utf8'});
 const ast=ts.createSourceFile(file,src,ts.ScriptTarget.Latest,true);
 const node=ast.statements.find(n=>n.name?.text===name);assert.ok(node,name);
 return node.getText(ast).replace(/^export\s+/,'');
}
const context=vm.createContext({Response,Request,Headers,console:{warn(){}},voiceCloneRequestId:()=> 'local-audit',VOICE_CLONE_MONTHLY_LIMIT_SECONDS:7200});
const code=[
 extract('src/shared/growth/growth-config.ts','GrowthIdentityOwnershipConflictError'),
 extract('src/shared/voice-clone/errors.ts','VoiceCloneError'),
 extract('src/app/api/mobile/pro/status/v2/route.ts','createMobileProStatusGET'),
 'globalThis.make=createMobileProStatusGET; globalThis.ownershipError=()=>new GrowthIdentityOwnershipConflictError();'
].join('\n');
vm.runInContext(ts.transpileModule(code,{compilerOptions:{target:ts.ScriptTarget.ES2022}}).outputText,context);
function dependencies(pro=true){return {
 requirePrincipal:async()=>({userId:'audit-user'}),isUserPro:async()=>pro,
 activePlan:async()=> 'yearly',userProfile:async()=>({name:'Test'}),
 freeUsage:async()=>({remaining:0,max:3}),listenUsage:async()=>({remaining:0,limit:1200,seconds:1200}),
 quotaSubject:()=> 'audit-subject',growthConfig:async()=>({assignment:null,killSwitch:false}),
 voiceClonePolicy:async()=>({canCreate:false,canApply:false,usedMs:0,remainingMs:0,resetAt:null})
};}
(async()=>{
 const results=[];
 async function run(name,d,expectedHTTP,expectedPro){
  const response=await context.make(d)(new Request('https://example.invalid/api/mobile/pro/status/v2'));
  const body=await response.json();assert.equal(response.status,expectedHTTP,name);assert.equal(body.data?.pro,expectedPro,name);
  results.push({name,httpStatus:response.status,pro:body.data?.pro??null,error:body.error||body.message||null});
 }
 const conflict=async()=>{throw context.ownershipError()};
 await run('valid Pro, historical install conflict', {...dependencies(),growthConfig:conflict},200,true);
 await run('Pro expired/payment failed, same historical install conflict', {...dependencies(false),growthConfig:conflict},409,undefined);
 await run('Non-Pro, correctly owned install',dependencies(false),200,false);
 for(const dependency of ['freeUsage','listenUsage','userProfile','activePlan','growthConfig']){
  await run(`valid Pro, ${dependency} unavailable`,{...dependencies(),[dependency]:async()=>{throw new Error('InjectedDependencyFailure')}},503,undefined);
 }
 await run('valid Pro, clone policy unavailable',{...dependencies(),voiceClonePolicy:async()=>{throw new Error('InjectedDependencyFailure')}},200,true);
 const report={checkedAt:new Date().toISOString(),sourceCommit:ref,mode:'local extracted handler with dependency fault injection; no live API or database',results};
 fs.writeFileSync(__dirname+'/status-failure-matrix.json',JSON.stringify(report,null,2)+'\n',{mode:0o600});
 console.log(JSON.stringify(report,null,2));
})().catch(e=>{console.error(e);process.exitCode=1});
