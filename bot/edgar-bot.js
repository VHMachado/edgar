'use strict';

// Edgar — a deterministic WhatsApp bot. No LLM: messages go through a regex
// dispatch table (dispatch.js) and out to local shell scripts. It also exposes
// POST /send so cron jobs and other machines can push messages to you.

const fs = require('fs');
const http = require('http');
const path = require('path');
const pino = require('pino');
const qrcode = require('qrcode-terminal');
const {
  default: makeWASocket,
  useMultiFileAuthState,
  DisconnectReason,
  fetchLatestBaileysVersion,
} = require('@whiskeysockets/baileys');

const config = require('./config');
const { dispatch } = require('./dispatch');

// ---- logging ----

// stdout only — the systemd unit appends it to a file. Logging to the file from
// here as well would double every line.
const logger = pino({ level: process.env.LOG_LEVEL || 'info' });

const baileysLog = logger.child({ src: 'baileys' });
baileysLog.level = 'warn'; // baileys is very chatty at info

// ---- LID (Linked Identity) resolver ----
// Some accounts send messages from an @lid JID instead of @s.whatsapp.net, so
// the allowlist check would never match. Baileys writes lid-mapping-<phone>.json
// files into the creds directory; we use those to map back to the phone JID.

let LID_MAP = {};

function buildLidMap() {
  const map = {};
  try {
    for (const f of fs.readdirSync(config.CREDS_DIR)) {
      const m = f.match(/^lid-mapping-(\d+)\.json$/);
      if (!m) continue;
      const phone = m[1];
      try {
        const lid = JSON.parse(fs.readFileSync(path.join(config.CREDS_DIR, f), 'utf8').trim());
        map[`${String(lid)}@lid`] = `${phone}@s.whatsapp.net`;
        logger.info({ lid: String(lid), phone }, 'LID mapping loaded');
      } catch {
        // ignore unreadable/half-written mapping files
      }
    }
  } catch {
    // creds dir missing on first run — startSocket creates it
  }
  return map;
}

// ---- WhatsApp socket ----

let sock = null;

async function startSocket() {
  const { state, saveCreds } = await useMultiFileAuthState(config.CREDS_DIR);
  const { version, isLatest } = await fetchLatestBaileysVersion().catch(() => ({
    version: undefined,
    isLatest: false,
  }));
  if (version) logger.info({ version, isLatest }, 'baileys version fetched');

  LID_MAP = buildLidMap();
  logger.info({ entries: Object.keys(LID_MAP).length }, 'LID map ready');

  sock = makeWASocket({
    version,
    auth: state,
    logger: baileysLog,
    printQRInTerminal: false, // we render the QR ourselves
    syncFullHistory: false,
    markOnlineOnConnect: false,
  });

  sock.ev.on('creds.update', () => {
    saveCreds();
    // Baileys may write new lid-mapping files after pairing
    LID_MAP = buildLidMap();
  });

  sock.ev.on('connection.update', (update) => {
    const { connection, lastDisconnect, qr } = update;
    if (qr) {
      logger.info('QR code received — scan it with the phone running the bot number');
      qrcode.generate(qr, { small: true });
    }
    if (connection === 'open') {
      logger.info({ user: sock.user && sock.user.id }, 'connection open');
    }
    if (connection === 'close') {
      const code =
        (lastDisconnect &&
          lastDisconnect.error &&
          lastDisconnect.error.output &&
          lastDisconnect.error.output.statusCode) || 0;
      logger.warn({ code, reason: DisconnectReason[code] || code }, 'connection closed');
      if (code === DisconnectReason.loggedOut) {
        logger.error('logged out — delete creds/ and pair again');
        process.exit(1);
      }
      setTimeout(startSocket, 3000);
    }
  });

  sock.ev.on('messages.upsert', async (m) => {
    if (m.type !== 'notify') return;
    for (const msg of m.messages || []) {
      try {
        await handleIncoming(msg);
      } catch (err) {
        logger.error({ err: err.message }, 'handleIncoming threw');
      }
    }
  });
}

function extractText(msg) {
  const m = msg.message || {};
  return (
    m.conversation ||
    (m.extendedTextMessage && m.extendedTextMessage.text) ||
    (m.imageMessage && m.imageMessage.caption) ||
    (m.videoMessage && m.videoMessage.caption) ||
    (m.buttonsResponseMessage && m.buttonsResponseMessage.selectedDisplayText) ||
    (m.listResponseMessage && m.listResponseMessage.title) ||
    ''
  ).trim();
}

async function handleIncoming(msg) {
  if (!msg.key || msg.key.fromMe) return;
  if (msg.key.remoteJid && msg.key.remoteJid.endsWith('@g.us')) return; // groups off

  let sender = msg.key.remoteJid;

  if (sender && sender.endsWith('@lid')) {
    const resolved = LID_MAP[sender];
    if (resolved) {
      logger.info({ lid: sender, resolved }, 'LID resolved to phone JID');
      sender = resolved;
    } else {
      logger.warn({ lid: sender }, 'unknown LID — not in creds map');
    }
  }

  if (!config.ALLOWLIST.includes(sender)) {
    logger.warn({ sender }, 'message from non-allowlisted sender, ignoring');
    return;
  }
  const text = extractText(msg);
  if (!text) return;
  logger.info({ sender, text }, 'inbound');

  // Lets a slow handler ack immediately, before the real reply is ready.
  const sendFeedback = (feedbackText) =>
    sendText(sender, feedbackText).catch((e) => logger.warn({ err: e.message }, 'sendFeedback failed'));

  const reply = await dispatch(text, { sendFeedback });
  await sendText(sender, reply);
  logger.info({ sender, len: reply.length }, 'outbound');
}

async function sendText(to, text) {
  if (!sock) throw new Error('socket not ready');
  const jid = to.includes('@') ? to : `${to}@s.whatsapp.net`;
  await sock.sendMessage(jid, { text });
}

// ---- HTTP send API ----

function startHttp() {
  const handler = (req, res) => {
    if (req.method !== 'POST' || req.url !== '/send') {
      res.statusCode = 404;
      return res.end(JSON.stringify({ error: 'not found' }));
    }
    if (req.headers['x-edgar-token'] !== config.HTTP_TOKEN) {
      res.statusCode = 401;
      return res.end(JSON.stringify({ error: 'unauthorized' }));
    }
    let body = '';
    req.on('data', (chunk) => {
      body += chunk;
      if (body.length > 65536) req.destroy();
    });
    req.on('end', async () => {
      let payload;
      try {
        payload = JSON.parse(body);
      } catch {
        res.statusCode = 400;
        return res.end(JSON.stringify({ error: 'invalid json' }));
      }
      const to = payload.to || config.DEFAULT_TO;
      const text = (payload.text || '').toString();
      if (!text) {
        res.statusCode = 400;
        return res.end(JSON.stringify({ error: 'missing text' }));
      }
      try {
        await sendText(to, text);
        res.setHeader('Content-Type', 'application/json');
        res.end(JSON.stringify({ ok: true }));
        logger.info({ to, len: text.length, src: 'http' }, 'sent');
      } catch (err) {
        res.statusCode = 500;
        res.end(JSON.stringify({ error: err.message }));
        logger.error({ err: err.message }, 'send failed');
      }
    });
  };

  http.createServer(handler).listen(config.HTTP_PORT, config.HTTP_HOST, () => {
    logger.info({ host: config.HTTP_HOST, port: config.HTTP_PORT }, 'http listening');
  });

  if (config.HTTP_EXTRA_HOST) {
    http.createServer(handler).listen(config.HTTP_PORT, config.HTTP_EXTRA_HOST, () => {
      logger.info({ host: config.HTTP_EXTRA_HOST, port: config.HTTP_PORT }, 'http listening (extra)');
    });
  }
}

// ---- main ----

(async () => {
  try {
    if (!fs.existsSync(config.CREDS_DIR)) {
      fs.mkdirSync(config.CREDS_DIR, { recursive: true });
    }
    startHttp();
    await startSocket();
  } catch (err) {
    logger.fatal({ err: err.message, stack: err.stack }, 'fatal');
    process.exit(1);
  }
})();

['SIGINT', 'SIGTERM'].forEach((sig) =>
  process.on(sig, () => {
    logger.info({ sig }, 'shutting down');
    try {
      sock && sock.end && sock.end();
    } catch {
      // already gone
    }
    process.exit(0);
  })
);
