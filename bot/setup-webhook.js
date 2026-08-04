'use strict';

// Points Jellyseerr's webhook at the bot, so you get a WhatsApp message when a
// request finishes downloading. Run it once, on the machine running both:
//
//   node setup-webhook.js          # write the config
//   node setup-webhook.js --test   # write it, then fire a real test message
//
// Needs JELLYSEERR_KEY (Settings > General > API Key) and EDGAR_HTTP_DOCKER_HOST.

const fs = require('fs');

// The daemon gets its environment from systemd's EnvironmentFile. Run by hand,
// that file is not loaded, so config.js would fall back to different values and
// the webhook would be written with a token the bot rejects. Load it first.
const ENV_FILE = process.env.EDGAR_ENV_FILE || '/opt/edgar-bot/.env';
try {
  for (const line of fs.readFileSync(ENV_FILE, 'utf8').split('\n')) {
    const m = /^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$/.exec(line);
    if (m && !process.env[m[1]]) process.env[m[1]] = m[2].replace(/^["']|["']$/g, '');
  }
} catch {
  // Already in the environment? Fine. config.js will complain if it is not.
}

const config = require('./config');

const JSR = `${config.JELLYSEERR_URL}/api/v1`;
const TYPES = 8 | 16; // MEDIA_AVAILABLE | MEDIA_FAILED

if (!config.JELLYSEERR_KEY) {
  console.error('JELLYSEERR_KEY is not set');
  process.exit(1);
}
if (!config.HTTP_DOCKER_HOST) {
  console.error(
    'EDGAR_HTTP_DOCKER_HOST is not set — Jellyseerr runs in a container and\n' +
    'cannot reach the bot on 127.0.0.1. Set it to your Docker bridge gateway.'
  );
  process.exit(1);
}

const EDGAR_URL = `http://${config.HTTP_DOCKER_HOST}:${config.HTTP_PORT}/send`;

// The bot's /send expects {"to","text"}. WhatsApp formatting is *bold* only.
// {{subject}} first: it is the one field always populated ({{event}} is empty
// on the test notification).
const template = JSON.stringify({
  to: config.DEFAULT_TO,
  text: '🎬 *{{subject}}*\n{{event}}',
});

// Jellyseerr's webhook agent does JSON.parse(JSON.parse(payload)), so what it
// stores has to decode to a JSON *string*, not to the object. Hence the second
// stringify — passing the object straight through yields "[object Object]".
const payload = JSON.stringify(template);

async function call(p, method = 'GET', body) {
  const res = await fetch(`${JSR}${p}`, {
    method,
    headers: { 'X-Api-Key': config.JELLYSEERR_KEY, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(60000),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${p} -> ${res.status}: ${text.slice(0, 300)}`);
  return text ? JSON.parse(text) : {};
}

const SETTINGS = {
  enabled: true,
  types: TYPES,
  options: {
    webhookUrl: EDGAR_URL,
    jsonPayload: payload,
    // Jellyseerr sends this verbatim as the Authorization header; the bot
    // compares it to EDGAR_TOKEN as-is, with no Bearer prefix.
    authHeader: config.HTTP_TOKEN,
  },
};

(async () => {
  await call('/settings/notifications/webhook', 'POST', SETTINGS);

  if (process.argv.includes('--test')) {
    await call('/settings/notifications/webhook/test', 'POST', SETTINGS);
    console.log('test notification fired');
  }

  const cur = await call('/settings/notifications/webhook');
  console.log('webhook saved:');
  console.log('  enabled =', cur.enabled);
  console.log('  types   =', cur.types, '(8=available, 16=failed)');
  console.log('  url     =', cur.options && cur.options.webhookUrl);
  console.log('  header  =', cur.options && cur.options.authHeader ? 'set' : 'EMPTY');
})().catch((e) => {
  console.error('ERROR:', e.message);
  process.exit(1);
});
