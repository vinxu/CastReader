// Local-only regression reproduction. Executes functions extracted from the
// reviewed extension source, with network/player/UI dependencies replaced.
// It never connects to a customer session or requests generated audio.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { createRequire } = require('node:module');
const path = require('node:path');
const root = '/Users/xuxuheng/.codex/worktrees/safari-app-store-20260924/readout-desktop';
const ts = createRequire(path.join(root, 'package.json'))('typescript');
const ref = process.argv[2] || 'fa2fbf2';
const file = 'src/entrypoints/content.ts';
const source = execFileSync('git', ['show', `${ref}:${file}`], { cwd: root, encoding: 'utf8' });
const ast = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true);
const wanted = new Set(['armListenGateForNewSession', 'handleListenTrackerState']);
const extracted = [];
let panel;
function walk(node) {
  if (ts.isFunctionDeclaration(node) && wanted.has(node.name?.text)) extracted.push(node.getText(ast));
  if (ts.isPropertyAssignment(node) && node.name.getText(ast) === 'onPanelOpen') panel = node.initializer.getText(ast);
  ts.forEachChild(node, walk);
}
walk(ast);
assert.equal(extracted.length, 2);
assert.ok(panel);
const state = { now: 100_000, serverPro: true, fetches: 0, trackerStarts: 0, walls: 0, uiPro: null };
const status = () => ({ pro: state.serverPro, statusKnown: true, listenRemaining: 0, listenLimit: 1200, listenSeconds: 1200, account: null });
const context = vm.createContext({
  Date: { now: () => state.now },
  fetchListenStartGateStatus: async () => { state.fetches++; return { legacyGrace: false, status: status() }; },
  fetchListenStatus: async () => { state.fetches++; return status(); },
  showListenPaywall: () => { state.walls++; },
  startListenTracker: () => { state.trackerStarts++; },
  stopListenTracker() {}, endListenGrace() {},
  onListenLimitReached() {}, onListenQuotaProgress() {}, onListenGraceEntered() {},
  refreshBrowserAccountState() {}, refreshQuickreadQuota() {},
  pageTrigger: { setProEntitlement(pro) { state.uiPro = pro; }, setListenQuota() {} },
});
const js = ts.transpileModule(`
let listenTrackerEligible = false;
let currentProEntitled = true;
let currentProStatusKnown = true;
let _lastStatusRefetchAt = 0;
${extracted.join('\n')}
globalThis.openPanel = ${panel};
globalThis.start = armListenGateForNewSession;
globalThis.play = () => handleListenTrackerState('playing');
globalThis.eligible = () => listenTrackerEligible;
`, { compilerOptions: { target: ts.ScriptTarget.ES2022 } }).outputText;
vm.runInContext(js, context);
(async () => {
  assert.equal(await context.start(), true);
  context.play();
  assert.equal(state.trackerStarts, 0);
  state.now += 2 * 60 * 60 * 1000;
  state.serverPro = false; // Expiry or verified payment failure, free quota exhausted.
  context.openPanel(); // Actual UI callback receives the new server false.
  await Promise.resolve(); await Promise.resolve();
  assert.equal(state.uiPro, false, 'The UI correctly receives revocation');
  context.play(); // Existing session resumes/continues with stale eligibility.
  assert.equal(context.eligible(), false);
  assert.equal(state.trackerStarts, 0, 'BUG: revoked session still bypasses usage tracker');
  assert.equal(state.walls, 0, 'BUG: no exhausted-quota gate for existing session');
  const beforeNewSession = { ...state, trackerEligible: context.eligible() };
  assert.equal(await context.start(), false, 'Control: a brand new reading session is denied');
  assert.equal(state.walls, 1);
  const result = {
    checkedAt: new Date().toISOString(), sourceCommit: ref, sourceFile: file,
    mode: 'isolated execution of extracted reviewed-source functions; mocked dependencies; no live API or audio',
    reproduced: true,
    finding: 'Existing Pro-started session retains tracker bypass even after settings refresh receives pro=false; new-session gate correctly denies exhausted free quota.',
    beforeNewSession, afterNewSession: state,
    limitation: 'This is a source-level regression reproduction, not evidence of Bob\'s exact device state or an end-to-end synthesis request.'
  };
  fs.writeFileSync(path.join(__dirname, `extension-revocation-reproduction-${ref}.json`), JSON.stringify(result, null, 2) + '\n', { mode: 0o600 });
  console.log(JSON.stringify(result, null, 2));
})().catch(error => { console.error(error); process.exitCode = 1; });
