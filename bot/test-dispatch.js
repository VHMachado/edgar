'use strict';

// Routing check for dispatch.js. Runs no shell, hits no network: it only asks
// which handler each message would reach. Run with: node test-dispatch.js
//
// Add a line here whenever you add or reword a command — the ordering bugs
// (a generic pattern swallowing a specific one) are the ones that hurt.

process.env.EDGAR_TOKEN = 'test';
process.env.EDGAR_ALLOWLIST = '15551234567';
process.env.EDGAR_JOBS = '{"photos":"/bin/true"}';

const assert = require('assert');
const { DISPATCH } = require('./dispatch');
const h = require('./handlers');

// Entries whose handler is an inline arrow, matched by position instead.
const INLINE = new Map([
  [0, 'help'],
  [DISPATCH.findIndex((e) => e.pattern.source.includes('resources')), 'resourcesFull'],
  [DISPATCH.findIndex((e) => e.pattern.source.includes('samba')), 'statusService'],
]);

function route(text) {
  const i = DISPATCH.findIndex((e) => e.pattern.test(text));
  if (i === -1) return 'help'; // dispatch() falls through to help
  if (INLINE.has(i)) return INLINE.get(i);
  const fn = DISPATCH[i].handler;
  const name = Object.keys(h).find((k) => h[k] === fn);
  return name || `<anonymous #${i}>`;
}

const CASES = [
  ['help', 'help'],
  ['?', 'help'],
  ['status', 'statusAll'],
  ['hello', 'statusAll'],
  ['good morning', 'statusAll'],
  ['issues', 'statusIssues'],
  ['cron', 'statusCron'],
  ['pihole', 'statusService'],
  ['unbound', 'statusService'],
  ['vaultwarden?', 'statusService'],
  ['cpu', 'resource'],
  ['disk', 'resource'],
  ['disks', 'resource'],
  ['uptime?', 'resource'],
  ['resources', 'resourcesFull'],
  ['panel pihole', 'panel'],
  ['panel syncthing', 'panel'],
  ['backup', 'backupStatus'],
  ['last backup', 'backupStatus'],
  ['heartbeat', 'heartbeatTrigger'],
  ['restart', 'restartEdgar'],
  ['run photos', 'runJob'],
  ['vault list', 'vaultList'],
  ['vault get gmail', 'vaultGet'],
  ['vault delete gmail', 'vaultDelete'],
  ['vault confirm', 'vaultConfirm'],

  // Ordering traps: the more specific pattern has to win.
  ['status now', 'heartbeatTrigger'],
  ['vault delete confirm', 'vaultDelete'],

  // Chatter must not trigger anything — patterns stay anchored.
  ['what is the status of my order', 'help'],
  ['please restart the router', 'help'],
  ['run', 'help'],
  ['', 'help'],
];

let failures = 0;
for (const [input, expected] of CASES) {
  const got = route(input);
  if (got !== expected) {
    console.error(`FAIL ${JSON.stringify(input)}: expected ${expected}, got ${got}`);
    failures++;
  }
}

assert.strictEqual(failures, 0, `${failures} routing case(s) failed`);
console.log(`ok — ${CASES.length} routing cases`);
