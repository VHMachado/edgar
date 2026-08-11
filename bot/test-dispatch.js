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
const m = require('./media');

// Handlers live in two modules; look the name up in both.
const HANDLERS = { ...h, ...m };

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
  const name = Object.keys(HANDLERS).find((k) => HANDLERS[k] === fn);
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
  ['immich', 'statusService'],
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

  ['movie dune', 'searchMovie'],
  ['film dune', 'searchMovie'],
  ['series deep space nine', 'searchTv'],
  ['show deep space nine', 'searchTv'],
  ['book sapiens', 'searchBook'],
  ['ebook sapiens', 'searchBook'],
  ['grab 1', 'request'],
  ['get 2', 'request'],
  ['queue', 'queue'],
  ['downloading', 'queue'],
  ['media up', 'mediaUp'],
  ['media start', 'mediaUp'],
  ['media down', 'mediaDown'],
  ['media stop', 'mediaDown'],

  // Ordering traps: the more specific pattern has to win.
  ['status now', 'heartbeatTrigger'],
  ['vault delete confirm', 'vaultDelete'],
  // "get <n>" is a pick; "vault get <site>" is the vault. Both start with a
  // word that the other could claim.
  ['vault get gmail', 'vaultGet'],
  // A search needs an argument — a bare word is not a search.
  ['movie', 'help'],
  ['book', 'help'],
  // "media" alone powers nothing — the verb is required.
  ['media', 'help'],
  // "grab" only takes a number, so this is not a pick.
  ['grab the milk', 'help'],

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
