'use strict';

// One function per command. Each gets (msgText, regexMatch, opts) and returns a
// string ready to send to WhatsApp. Every shell call runs locally — the bot is
// meant to live on the same host as the scripts.
//
// Reply text lives here. Change the wording freely; dispatch.js owns the
// trigger words, this file owns what comes back.

const { exec } = require('child_process');
const { promisify } = require('util');
const fs = require('fs');
const path = require('path');
const config = require('./config');
const { HELP } = require('./help');

const execAsync = promisify(exec);

// Vault operations shell out to the Bitwarden CLI, which needs to sync and do a
// TLS handshake before it answers — 40s is normal, so give it room.
const VAULT_TIMEOUT_MS = 90000;

// ---- helpers ----

async function runShell(cmd, timeoutMs = config.EXEC_TIMEOUT_MS) {
  try {
    const { stdout, stderr } = await execAsync(cmd, {
      timeout: timeoutMs,
      maxBuffer: 4 * 1024 * 1024,
      shell: '/bin/bash',
    });
    return { ok: true, stdout: (stdout || '').trim(), stderr: (stderr || '').trim() };
  } catch (err) {
    return {
      ok: false,
      stdout: (err.stdout || '').toString().trim(),
      stderr: (err.stderr || err.message || '').toString().trim(),
      code: err.code,
    };
  }
}

function nasScript(name) {
  return path.join(config.NAS_MONITOR_DIR, name);
}

function readState() {
  try {
    return JSON.parse(fs.readFileSync(config.STATE_FILE, 'utf8'));
  } catch {
    return {};
  }
}

function writeState(obj) {
  try {
    fs.writeFileSync(config.STATE_FILE, JSON.stringify(obj, null, 2));
  } catch {
    // non-fatal — worst case a pending delete has to be re-issued
  }
}

function shellEscape(s) {
  return "'" + String(s).replace(/'/g, "'\\''") + "'";
}

function fail(r) {
  return `❌ Error: ${r.stderr || 'exit ' + r.code}`;
}

// ---- formatters ----

const SERVICE_EMOJIS = {
  pihole: '🛡️',
  syncthing: '🔄',
  tailscale: '🔒',
  samba: '📁',
  vaultwarden: '🔑',
  unbound: '🌐',
};

function formatStatusAll(json) {
  const lines = ['📊 *NAS status*', ''];
  for (const svc of json.services || []) {
    const ok = svc.status === 'ok' || svc.status === 'up';
    const svcEmoji = SERVICE_EMOJIS[svc.name] || '⚙️';
    lines.push(`${ok ? '🟢' : '🔴'} ${svcEmoji} ${svc.name}${svc.details ? ' — ' + svc.details : ''}`);
  }
  lines.push('');
  lines.push(json.has_issues
    ? '⚠️ Something needs attention. Try *issues* or *resources*.'
    : '✅ All normal.');
  return lines.join('\n');
}

function formatIssues(json) {
  const issues = json.service_issues || [];
  const cronFails = json.cron_failures_24h || [];
  if (issues.length === 0 && cronFails.length === 0) {
    return '🟢 Nothing wrong.';
  }
  const lines = ['🚨 *Problems found*', ''];
  for (const iss of issues) {
    const svcEmoji = SERVICE_EMOJIS[iss.name] || '⚙️';
    lines.push(`🔴 ${svcEmoji} ${iss.name}: ${iss.status}${iss.details ? ' — ' + iss.details : ''}`);
  }
  for (const cf of cronFails) {
    lines.push(`🟡 🗓️ job ${cf.job_name}: ${cf.status}${cf.stderr ? ' — ' + cf.stderr.split('\n')[0] : ''}`);
  }
  return lines.join('\n');
}

function formatDiskLine(d) {
  const freeStr = (d.avail_gb || 0) >= 1
    ? `${Math.round(d.avail_gb)}GB free`
    : `${Math.round((d.avail_gb || 0) * 1024)}MB free`;
  return `💿 ${d.mount}: ${d.used_pct}% (${freeStr})`;
}

function isRealDisk(d) {
  // Drop virtual filesystems (udev/tmpfs) and anything under a gigabyte
  return d.source && d.source.startsWith('/dev/') && (d.total_gb || 0) >= 1;
}

function formatResource(json, kind) {
  if (kind === 'ram' || kind === 'memory') {
    return `🧠 RAM: ${json.used_pct}% (${json.used_mb}MB/${json.total_mb}MB)\n🔄 Swap: ${json.swap_pct}%`;
  }
  if (kind === 'cpu' || kind === 'load') {
    return `🖥️ CPU: ${json.load_per_cpu}/core (${json.load_pct}%)`;
  }
  if (kind === 'swap') {
    return `🔄 Swap: ${json.used_pct}% (${json.used_mb}MB/${json.total_mb}MB)`;
  }
  if (kind === 'uptime') {
    if (typeof json === 'string') return `⏱️ Uptime: ${json}`;
    if (json && json.human) return `⏱️ Uptime: ${json.human}`;
    return `⏱️ Uptime: ${JSON.stringify(json)}`;
  }
  if (kind === 'disk' || kind === 'disks') {
    const arr = (Array.isArray(json) ? json : json.disks || []).filter(isRealDisk);
    return arr.map(formatDiskLine).join('\n') || '(no disks reported)';
  }
  return JSON.stringify(json);
}

function formatResourcesFull(json) {
  const lines = ['📈 *Resources*', ''];
  if (json.cpu) {
    lines.push(`🖥️ CPU: ${json.cpu.load_per_cpu}/core (${Math.floor((json.cpu.load_per_cpu || 0) * 100)}%)`);
  }
  if (json.memory) lines.push(`🧠 RAM: ${json.memory.used_pct}% (${json.memory.used_mb}MB/${json.memory.total_mb}MB)`);
  if (json.swap) lines.push(`🔄 Swap: ${json.swap.used_pct}% (${json.swap.used_mb}MB/${json.swap.total_mb}MB)`);
  if (Array.isArray(json.disks)) {
    for (const d of json.disks.filter(isRealDisk)) lines.push(formatDiskLine(d));
  }
  if (json.uptime) lines.push(`⏱️ Uptime: ${json.uptime.human}`);
  if (Array.isArray(json.warnings) && json.warnings.length) {
    lines.push('');
    for (const w of json.warnings) lines.push(`⚠️ ${w}`);
  }
  return lines.join('\n');
}

function formatServiceStatus(name, json) {
  const svc = json[name] || json;
  const ok = svc.status === 'ok' || svc.status === 'up';
  const svcEmoji = SERVICE_EMOJIS[name] || '⚙️';
  const details = svc.details ? `\n${svc.details}` : '';
  return `${ok ? '🟢' : '🔴'} ${svcEmoji} *${name}*: ${svc.status || 'unknown'}${details}`;
}

// ---- handlers ----

async function statusAll() {
  const r = await runShell(`${nasScript('status.sh')} all`);
  if (!r.ok) return fail(r);
  try {
    return formatStatusAll(JSON.parse(r.stdout));
  } catch (e) {
    return `❌ status.sh returned invalid JSON: ${e.message}`;
  }
}

async function statusIssues() {
  const r = await runShell(`${nasScript('status.sh')} issues`);
  if (!r.ok) return fail(r);
  try {
    return formatIssues(JSON.parse(r.stdout));
  } catch (e) {
    return `❌ Invalid response: ${e.message}`;
  }
}

async function statusCron() {
  const r = await runShell(`${nasScript('status.sh')} cron`);
  if (!r.ok) return fail(r);
  try {
    const jobs = JSON.parse(r.stdout).cron_jobs || [];
    if (!jobs.length) return '🟢 No jobs have run yet.';
    const lines = ['🗓️ *Recent jobs*', ''];
    for (const j of jobs) {
      lines.push(`${j.exit_code === 0 ? '✅' : '❌'} ${j.job_name}${j.timestamp ? ' — ' + j.timestamp.replace('T', ' ') : ''}`);
    }
    return lines.join('\n');
  } catch (e) {
    return `❌ Invalid response: ${e.message}`;
  }
}

async function statusService(name) {
  const r = await runShell(`${nasScript('status.sh')} ${shellEscape(name)}`);
  if (!r.ok) return fail(r);
  try {
    return formatServiceStatus(name, JSON.parse(r.stdout));
  } catch (e) {
    return r.stdout || `❌ Invalid response: ${e.message}`;
  }
}

async function resource(_msg, match) {
  const kind = match[1].toLowerCase();
  let jqExpr;
  if (kind === 'ram' || kind === 'memory') {
    jqExpr = `'{used_pct: .memory.used_pct, used_mb: .memory.used_mb, total_mb: .memory.total_mb, swap_pct: .swap.used_pct}'`;
  } else if (kind === 'cpu' || kind === 'load') {
    jqExpr = `'{load_per_cpu: .cpu.load_per_cpu, load_pct: (.cpu.load_per_cpu * 100 | floor)}'`;
  } else if (kind === 'swap') {
    jqExpr = `'{used_mb: .swap.used_mb, total_mb: .swap.total_mb, used_pct: .swap.used_pct}'`;
  } else if (kind === 'uptime') {
    jqExpr = `'.uptime'`;
  } else if (kind === 'disk' || kind === 'disks') {
    jqExpr = `'.disks'`;
  } else {
    return resourcesFull();
  }
  const r = await runShell(`${nasScript('status.sh')} resources | jq ${jqExpr}`);
  if (!r.ok) return fail(r);
  try {
    return formatResource(JSON.parse(r.stdout), kind);
  } catch {
    return r.stdout;
  }
}

async function resourcesFull() {
  const r = await runShell(`${nasScript('status.sh')} resources`);
  if (!r.ok) return fail(r);
  try {
    return formatResourcesFull(JSON.parse(r.stdout));
  } catch (e) {
    return `❌ Invalid response: ${e.message}`;
  }
}

async function panel(_msg, match) {
  const svc = match[1].toLowerCase();
  const r = await runShell(`${nasScript('panel.sh')} ${svc}`);
  if (!r.ok) return fail(r);
  if (r.stdout.startsWith('ERROR:')) return r.stdout;
  return r.stdout;
}

async function vaultList(_msg, _match, opts = {}) {
  if (opts.sendFeedback) await opts.sendFeedback('🔍 Opening the vault...');
  const r = await runShell(`${nasScript('vaultwarden.sh')} list`, VAULT_TIMEOUT_MS);
  if (!r.ok) return fail(r);
  try {
    const json = JSON.parse(r.stdout);
    if (json.error) return `❌ ${json.error}`;
    const lines = [`You have *${json.count}* entries:`, ''];
    for (const it of json.items || []) {
      lines.push(`🔑 ${it.name}${it.username ? ' (' + it.username + ')' : ''}`);
    }
    return lines.join('\n');
  } catch (e) {
    return `❌ Invalid response: ${e.message}`;
  }
}

async function vaultGet(_msg, match, opts = {}) {
  const site = match[1].trim();
  if (!site) return 'Usage: *vault get <site>*';
  if (opts.sendFeedback) await opts.sendFeedback(`🔍 Looking up "${site}"...`);
  const r = await runShell(`${nasScript('vaultwarden.sh')} get ${shellEscape(site)}`, VAULT_TIMEOUT_MS);
  if (!r.ok) return fail(r);
  try {
    const json = JSON.parse(r.stdout);
    if (json.error) return `❌ ${json.error}`;
    const items = json.items || [];
    if (items.length === 0) return `No entry found for "${site}".`;
    if (items.length === 1) {
      const it = items[0];
      return `🔑 *${it.name}*\nUser: ${it.username || '(empty)'}\nPassword: ${it.password || '(empty)'}`;
    }
    const lines = [`Found ${items.length} entries for "${site}":`, ''];
    for (const it of items) {
      lines.push(`🔑 *${it.name}*\nUser: ${it.username || '(empty)'}\nPassword: ${it.password || '(empty)'}\n`);
    }
    return lines.join('\n');
  } catch (e) {
    return `❌ Invalid response: ${e.message}`;
  }
}

async function vaultDelete(_msg, match, opts = {}) {
  const site = match[1].trim();
  if (!site) return 'Usage: *vault delete <site>*';
  if (opts.sendFeedback) await opts.sendFeedback(`🔍 Looking up "${site}"...`);
  const r = await runShell(`${nasScript('vaultwarden.sh')} search ${shellEscape(site)}`, VAULT_TIMEOUT_MS);
  if (!r.ok) return fail(r);
  try {
    const json = JSON.parse(r.stdout);
    if (json.error) return `❌ ${json.error}`;
    const items = json.items || [];
    if (items.length === 0) return `No entry found for "${site}".`;
    const state = readState();
    state.pendingDelete = { site, ids: items.map((i) => i.id).join(','), items };
    writeState(state);
    const lines = [`⚠️ About to *delete* ${items.length} entry(ies) for "${site}":`, ''];
    for (const it of items) lines.push(`🔑 ${it.name}${it.username ? ' (' + it.username + ')' : ''}`);
    lines.push('');
    lines.push('Send *vault confirm* to go ahead.');
    return lines.join('\n');
  } catch (e) {
    return `❌ Invalid response: ${e.message}`;
  }
}

async function vaultConfirm(_msg, _match, opts = {}) {
  const state = readState();
  const pd = state.pendingDelete;
  if (!pd) return 'Nothing pending. Run *vault delete <site>* first.';
  if (opts.sendFeedback) await opts.sendFeedback('🗑️ Deleting...');
  const r = await runShell(`${nasScript('vaultwarden.sh')} delete ${shellEscape(pd.ids)}`, VAULT_TIMEOUT_MS);
  delete state.pendingDelete;
  writeState(state);
  if (!r.ok) return fail(r);
  try {
    const json = JSON.parse(r.stdout);
    if (json.error) return `❌ ${json.error}`;
    const errs = json.errors ? `\n⚠️ ${json.errors} failed.` : '';
    return `🟢 Deleted ${json.deleted || 0} entry(ies) for "${pd.site}". They are in the vault trash.${errs}`;
  } catch {
    return r.stdout;
  }
}

async function runJob(_msg, match) {
  const name = match[1].trim().toLowerCase();
  const cmd = config.JOBS[name];
  if (!cmd) {
    const known = Object.keys(config.JOBS);
    return known.length
      ? `Unknown job "${name}". Configured: ${known.join(', ')}`
      : 'No jobs configured. Set EDGAR_JOBS in .env.';
  }
  // cmd comes from EDGAR_JOBS (operator config), never from the message.
  const r = await runShell(`${nasScript('cron-wrapper.sh')} ${shellEscape(name)} ${cmd}`, 60000);
  const out = r.stdout || r.stderr || '(no output)';
  const firstLine = out.split('\n').find((l) => l.trim()) || '';
  if (r.ok) return `✅ ${name} finished.${firstLine ? '\n' + firstLine.slice(0, 200) : ''}`;
  return `❌ ${name} failed.\n${out.split('\n').slice(0, 3).join('\n')}`;
}

async function heartbeatTrigger() {
  // Fire and forget — heartbeat.sh posts back over HTTP, so the reply can be
  // instant instead of waiting on the whole collection run.
  const script = nasScript('heartbeat.sh');
  exec(`${script} >> ${path.join(config.NAS_MONITOR_DIR, 'logs/heartbeat.log')} 2>&1`,
    { shell: '/bin/bash' }, () => {});
  return '⏳ Heartbeat triggered. Status arrives in a few seconds.';
}

async function backupStatus() {
  const log = path.join(config.NAS_MONITOR_DIR, 'logs/restic-backup.log');
  // Read backwards to the last "=== Backup started ===", then flip it back.
  const r = await runShell(`tac ${log} 2>/dev/null | sed '/=== Backup started ===/q' | tac`);
  if (!r.ok) return `❌ Could not read the log: ${r.stderr}`;
  if (!r.stdout) return 'No backup recorded yet.';
  return `📦 *Last backup*\n\n${r.stdout.split('\n').slice(-15).join('\n')}`;
}

async function restartEdgar() {
  // Delay so this reply is actually delivered before the socket dies.
  setTimeout(() => {
    exec('sudo -n /bin/systemctl restart edgar-bot.service', () => {});
  }, 2000);
  return 'Restarting the daemon. Back in a few seconds.';
}

function help() {
  return HELP;
}

module.exports = {
  statusAll, statusIssues, statusCron, statusService,
  resource, resourcesFull, panel,
  vaultList, vaultGet, vaultDelete, vaultConfirm,
  runJob, heartbeatTrigger, backupStatus,
  restartEdgar, help,
  // media.js keeps its pending picks in the same state file, and calls the
  // monitor scripts for the download queue.
  readState, writeState, runShell,
};
