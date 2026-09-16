// Security §7 rules drill (Security-Enhancement): validSecurityFields +
// app_config floor. Run against a local Firestore emulator:
//   firebase emulators:start --only firestore --project demo-org-drill
//   node sec-drill.mjs
// Exits non-zero on any unexpected verdict. Cleans up its install (see
// cleanup note at the bottom).
import { readFileSync } from 'node:fs';
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import {
  collection,
  doc,
  getDoc,
  getDocs,
  setDoc,
} from 'firebase/firestore';

const projectId = 'demo-org-drill';
const rules = readFileSync(
  new URL('../firestore.rules', import.meta.url),
  'utf8',
);

const now = Date.now();
const baseDevice = (email, install) => ({
  email,
  uid: 'uid-' + email,
  pkHex: 'aa'.repeat(32),
  installId: install,
  name: 'S',
  roll: 'R1',
  modelVer: 'm',
  platform: 'android',
  org: 'x.in',
  createdAtMillis: now,
  lastMoveAtMillis: now,
  lastSeenAtMillis: now,
  updatedAtMillis: now,
  moveCount: 0,
  pkDHex: 'bb'.repeat(32),
  attestationLevel: 'NONE',
  attestedAtMillis: now,
  attestedUntilMillis: now + 90 * 86400000,
});

const env = await initializeTestEnvironment({
  projectId,
  firestore: { rules, host: '127.0.0.1', port: 8080 },
});

let pass = 0;
let total = 0;
// NOTE: assertSucceeds resolves on ALLOW; assertFails resolves on DENY
// (it rejects on the opposite). Do not invert.
const allow = async (name, op) => {
  total++;
  try {
    await assertSucceeds(op);
    pass++;
    console.log('ok   ALLOW ' + name);
  } catch (e) {
    console.error('FAIL (want ALLOW) ' + name + ' → ' + (e?.message ?? e));
    process.exitCode = 1;
  }
};
const deny = async (name, op) => {
  total++;
  try {
    await assertFails(op);
    pass++;
    console.log('ok   DENY  ' + name);
  } catch (e) {
    console.error('FAIL (want DENY) ' + name + ' → ' + (e?.message ?? e));
    process.exitCode = 1;
  }
};

const stu = (email) =>
  env.authenticatedContext('uid-' + email, { email }).firestore();

await allow(
  'create with valid attestationChain/livenessVer/integrityFlag',
  setDoc(doc(stu('s1@x.in'), 'studentDevices/s1@x.in'), {
    ...baseDevice('s1@x.in', 'inst-1'),
    attestationChain: ['ab12', 'cd34'],
    livenessVer: 'liveness/minifasnet-v2-se+heuristic-v1',
    integrityFlag: '',
  }),
);

await deny(
  'create with attestationChain:string',
  setDoc(doc(stu('s2@x.in'), 'studentDevices/s2@x.in'), {
    ...baseDevice('s2@x.in', 'inst-2'),
    attestationChain: 'ab12',
  }),
);

await deny(
  "create with integrityFlag:'evil'",
  setDoc(doc(stu('s3@x.in'), 'studentDevices/s3@x.in'), {
    ...baseDevice('s3@x.in', 'inst-3'),
    integrityFlag: 'evil',
  }),
);

await deny(
  'create with livenessVer:number',
  setDoc(doc(stu('s4@x.in'), 'studentDevices/s4@x.in'), {
    ...baseDevice('s4@x.in', 'inst-4'),
    livenessVer: 123,
  }),
);

await allow(
  'update same-device with integrity-flagged',
  setDoc(
    doc(stu('s1@x.in'), 'studentDevices/s1@x.in'),
    {
      ...baseDevice('s1@x.in', 'inst-1'),
      attestationChain: ['ab12', 'cd34'],
      livenessVer: 'liveness/minifasnet-v2-se+heuristic-v1',
      integrityFlag: 'integrity-flagged',
    },
    { merge: true },
  ),
);

await allow(
  'create legacy without security fields',
  setDoc(
    doc(stu('s5@x.in'), 'studentDevices/s5@x.in'),
    baseDevice('s5@x.in', 'inst-5'),
  ),
);

// app_config world-readable get, no list, no writes (seeded with rules
// disabled — production deploys the doc via console/CLI).
await env.withSecurityRulesDisabled(async (ctx) => {
  await setDoc(doc(ctx.firestore(), 'app_config/min_version'), {
    minVersion: '1.0.0',
    force: false,
  });
});
const unauth = env.unauthenticatedContext().firestore();
await allow(
  'unauthenticated get app_config/min_version',
  getDoc(doc(unauth, 'app_config/min_version')),
);
await deny(
  'unauthenticated list app_config',
  getDocs(collection(unauth, 'app_config')),
);

await env.cleanup();
console.log(pass + '/' + total + ' drill checks behaved as specified');
