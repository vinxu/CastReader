import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFileSync,writeFileSync } from 'node:fs';
const root='/Users/xuxuheng/Documents/MyProject/.worktrees/castreader-content-pro-consistency-20260924';
const req=createRequire(root+'/package.json');
const env=req('dotenv').parse(readFileSync('/Users/xuxuheng/Documents/MyProject/readout-web/.env.local'));
process.env.DATABASE_URL=env.DATABASE_URL;
process.env.DB_SINGLETON_ENABLED='true';
process.env.DB_MAX_CONNECTIONS='1';
const model=await import(root+'/src/shared/models/pro.ts');
const {closeDb}=await import(root+'/src/core/db/index.ts');
try {
 const user='78f67399-9d7e-489e-a367-8ccd7aef99e5';
 const entitlement=await model.getProEntitlement(user);
 const checkout=await model.getProCheckoutGuardActionForUser(user);
 assert.equal(entitlement.pro,false);
 assert.equal(entitlement.plan,null);
 assert.equal(entitlement.graceUntil,null);
 assert.equal(checkout,'open_billing_portal');
 const result={checkedAt:new Date().toISOString(),membership:false,checkoutRecovery:checkout,billingWrites:0,passed:true};
 writeFileSync('/Users/xuxuheng/Documents/CastReader/reports/bob-pro-ipad-audit-20260924/content-model-readonly-check.json',JSON.stringify(result,null,2)+'\n',{mode:0o600});
 console.log(JSON.stringify(result));
} finally {await closeDb()}
