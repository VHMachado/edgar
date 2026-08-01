'use strict';

// Every value comes from the environment. See .env.example for the full list.
// systemd loads the file via EnvironmentFile=/opt/edgar-bot/.env

function required(name) {
  const v = process.env[name];
  if (!v) throw new Error(`${name} is not set — copy .env.example to .env and fill it in`);
  return v;
}

function toJid(n) {
  return n.includes('@') ? n : `${n}@s.whatsapp.net`;
}

const ALLOWLIST = required('EDGAR_ALLOWLIST')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean)
  .map(toJid);

if (ALLOWLIST.length === 0) {
  throw new Error('EDGAR_ALLOWLIST is empty — the bot would accept commands from nobody');
}

module.exports = {
  // WhatsApp numbers allowed to send commands. Anything else is dropped.
  ALLOWLIST,

  // Default recipient for messages pushed through the HTTP API.
  DEFAULT_TO: process.env.EDGAR_DEFAULT_TO || ALLOWLIST[0].split('@')[0],

  // HTTP send API. Shared secret — required, no default.
  HTTP_TOKEN: required('EDGAR_TOKEN'),
  HTTP_HOST: process.env.EDGAR_HTTP_HOST || '127.0.0.1',
  HTTP_PORT: Number(process.env.EDGAR_HTTP_PORT || 18790),

  // Optional second bind address, e.g. a Tailscale IP so other machines on the
  // tailnet can POST /send. Empty = loopback only.
  HTTP_EXTRA_HOST: process.env.EDGAR_HTTP_EXTRA_HOST || '',

  // Paths
  CREDS_DIR: process.env.EDGAR_CREDS_DIR || '/opt/edgar-bot/creds',
  STATE_FILE: process.env.EDGAR_STATE_FILE || '/opt/edgar-bot/state.json',
  NAS_MONITOR_DIR: process.env.NAS_MONITOR_DIR || '/opt/nas-monitor',

  // Default timeout for shell calls (ms). Vault handlers override it.
  EXEC_TIMEOUT_MS: Number(process.env.EDGAR_EXEC_TIMEOUT_MS || 20000),

  // Named commands runnable over chat with "run <name>", as JSON:
  //   EDGAR_JOBS={"photos":"/home/me/.venv/bin/python /home/me/organize.py"}
  // Each runs through scripts/cron-wrapper.sh, so the result also shows up
  // under the "cron" command. Values are operator-supplied, never user input.
  JOBS: JSON.parse(process.env.EDGAR_JOBS || '{}'),
};
