// Adversarial: drive the canonical routing module (via the repo lib/ symlink)
// with an UNSAFE scope carrying allSeqs: [] (the lib scan's torn-row shape) and
// a durable passed set {5}. The guard must not sweep row 5; a SAFE scan without
// row 5 must.
import { createWakeRouter } from '/home/andre/.no-mistakes/worktrees/65938fb6b121/01M332F9TEEQPDPFTY1YEA8VGC/lib/fm-branch-routing.ts'
const events = [], writes = [], outcomes = []
let passed = ['5']
const deps = (scope) => ({
  log: (k, d) => events.push([k, d]), reasonLines: (t) => t.split('\n').filter((l) => /^(signal|stale|check|heartbeat):/.test(l)),
  clockNow: async () => 1_000_000, dateNow: () => Date.now(), modeOn: async () => true, latched: () => false, afkPresent: async () => false,
  scopeFor: async () => scope, readPassedSeqs: async () => passed, writePassedSeqs: async (s) => { passed = s; writes.push([...s]) },
  classify: async () => { throw new Error('classifier must not run on an unsafe scope') },
  ensureActivated: async () => true, grantPublish: async () => 0, grantRelease: async () => {}, advanceEvidence: () => {},
  runOutcome: async (argv) => { outcomes.push(argv); return { ok: true, stdout: '9', detail: '' } },
  passedToMainSummary: (w, r) => `${w}: ${r}`, classifierPassCoverArgv: (t, s, w) => ['append', '--task', t, s], claimWakeNo: async () => 1,
  freshAgentNeeded: () => true, stateDir: () => '/tmp/x', statusNote: async () => '', resetStepCounter: () => {},
  deliver: async () => ({ ok: true, via: 'spawn', detail: '' }), spawnSendCounts: () => ({ spawnCount: 0, sendCount: 0 }),
})
const router = createWakeRouter()
const unsafe = { status: 'unsafe', eligibleSeqs: [], eligibleWakeKey: '', eligibleTasks: ['ship-a'], corrupted: true, needsDecisionTasks: [], allSeqs: [] }
const v1 = await router.routeWake(deps(unsafe), 'signal: ship-a.status', 'test')
console.log('unsafe scope verdict:', v1, '| passed after:', JSON.stringify(passed), '| writes:', JSON.stringify(writes))
if (v1 !== 'passed' || JSON.stringify(passed) !== '["5"]' || writes.length !== 0) { console.log('FAIL: unsafe scan swept the passed guard'); process.exit(1) }
await new Promise((r) => setTimeout(r, 20))
console.log('cover rows on unsafe pass:', JSON.stringify(outcomes.filter((a) => a[0] === 'append')))
const safe = { status: 'safe', eligibleSeqs: ['7'], eligibleWakeKey: '100:7', eligibleTasks: ['ship-a'], corrupted: false, needsDecisionTasks: [], allSeqs: ['7'] }
const d2 = deps(safe); d2.classify = async () => ({ verdict: 'routine', reason: 'r', ms: 1, promptChars: 1, answer: '', model: 'haiku', evidence: [] })
const v2 = await createWakeRouter().routeWake(d2, 'signal: ship-a.status', 'test')
console.log('safe scope (row 5 gone) verdict:', v2, '| passed after:', JSON.stringify(passed), '| writes:', JSON.stringify(writes))
if (JSON.stringify(passed) !== '[]') { console.log('FAIL: safe scan did not sweep acknowledged row 5'); process.exit(1) }
console.log('PASS: unsafe scan keeps guard, safe scan sweeps it')
