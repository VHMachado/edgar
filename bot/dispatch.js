'use strict';

// ─────────────────────────────────────────────────────────────────────────────
// THIS IS WHERE YOU CHANGE THE COMMANDS.
//
// Each entry is { pattern: RegExp, handler }. The first pattern that matches
// the incoming message wins, so specific patterns go above generic ones.
// Anything that matches nothing falls through to the help text in help.js.
//
// To add a word: add it to an existing alternation, e.g.
//     /^\s*(cpu|load|processor)\s*\??\s*$/i
// To add a command: add an entry here, a function in handlers.js, and a line
// in help.js. Nothing else needs to know about it.
// To translate: rewrite the patterns and the strings in handlers.js/help.js.
//   Patterns are anchored (^...$) and case-insensitive; keep it that way or
//   a chatty message will trigger a command by accident.
// ─────────────────────────────────────────────────────────────────────────────

const h = require('./handlers');
const m = require('./media');

const DISPATCH = [
  // Help
  { pattern: /^\s*(help|commands|menu|\?)\s*$/i, handler: () => h.help() },

  // Restart the daemon
  { pattern: /^\s*(restart|restart\s+edgar|reset\s+edgar)\s*$/i, handler: h.restartEdgar },

  // Push a status summary right now (same message the cron heartbeat sends)
  { pattern: /^\s*(heartbeat|status\s+now|ping\s+me)\s*$/i, handler: h.heartbeatTrigger },

  // Vault — order matters: confirm > delete > get > list
  { pattern: /^\s*vault\s+confirm\s*$/i, handler: h.vaultConfirm },
  { pattern: /^\s*vault\s+delete\s+(.+)$/i, handler: h.vaultDelete },
  { pattern: /^\s*vault\s+(?:get|show)\s+(.+?)\s*\??\s*$/i, handler: h.vaultGet },
  { pattern: /^\s*vault\s+(?:list|ls)\s*\??\s*$/i, handler: h.vaultList },

  // Media — Jellyseerr for movies/series, Prowlarr for books.
  // "grab <n>" sits above the searches: it consumes the pending pick, and a
  // search word followed by a number should not be mistaken for one.
  { pattern: /^\s*(?:grab|get|want)\s+(\d+)\s*$/i, handler: m.request },
  { pattern: /^\s*(?:movies?|films?)\s+(.+)$/i, handler: m.searchMovie },
  { pattern: /^\s*(?:series|shows?|tv)\s+(.+)$/i, handler: m.searchTv },
  { pattern: /^\s*(?:books?|ebooks?)\s+(.+)$/i, handler: m.searchBook },
  { pattern: /^\s*(?:queue|downloading|downloads?)\s*\??\s*$/i, handler: m.queue },

  // Power the whole stack. Above the per-service status line, which matches a
  // bare service name and would otherwise swallow nothing here — but keeping
  // the pair together makes the ordering intent obvious.
  { pattern: /^\s*media\s+(?:up|start)\s*$/i, handler: m.mediaUp },
  { pattern: /^\s*media\s+(?:down|stop)\s*$/i, handler: m.mediaDown },

  // Detailed panels
  { pattern: /^\s*(?:panel|dashboard)\s+(pihole|syncthing|tailscale)\s*$/i, handler: h.panel },

  // Named jobs from EDGAR_JOBS
  { pattern: /^\s*run\s+(.+?)\s*$/i, handler: h.runJob },

  // Backup
  { pattern: /^\s*(?:backup|last\s+backup|backup\s+status)\s*\??\s*$/i, handler: h.backupStatus },

  // Single hardware metric
  { pattern: /^\s*(cpu|load|ram|memory|swap|disks?|uptime)\s*\??\s*$/i, handler: h.resource },

  // All hardware metrics
  { pattern: /^\s*(?:resources|usage|how\s+busy)\s*\??\s*$/i, handler: () => h.resourcesFull() },

  // One service
  { pattern: /^\s*(pihole|unbound|syncthing|tailscale|samba|vaultwarden|immich)\s*\??\s*$/i,
    handler: (msg, match) => h.statusService(match[1].toLowerCase()) },

  // Everything else
  { pattern: /^\s*(?:issues|problems|anything\s+wrong)\s*\??\s*$/i, handler: h.statusIssues },
  { pattern: /^\s*(?:cron|jobs)\s*\??\s*$/i, handler: h.statusCron },
  { pattern: /^\s*(?:status|services|all\s+good|everything\s+ok|hi|hey|hello|good\s+(?:morning|afternoon|evening))\s*\??\s*$/i,
    handler: h.statusAll },
];

async function dispatch(text, opts = {}) {
  for (const entry of DISPATCH) {
    const m = entry.pattern.exec(text);
    if (m) {
      try {
        return await entry.handler(text, m, opts);
      } catch (err) {
        return `❌ Handler error: ${err.message}`;
      }
    }
  }
  return h.help();
}

module.exports = { dispatch, DISPATCH };
