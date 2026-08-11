'use strict';

// Sent for "help" and for anything the dispatch table does not recognise.
// Keep it in sync with dispatch.js by hand — it is a plain string on purpose,
// so the help text can say more than the regexes do.

const HELP = [
  '🐅 *Edgar — available commands*',
  '',
  '*Status*',
  'status — overall summary',
  'issues — only what is broken',
  'cron — last result of each job',
  'pihole | unbound | syncthing | tailscale | samba | vaultwarden | immich — one service',
  '',
  '*Hardware*',
  'cpu | ram | swap | disk | uptime | resources',
  '',
  '*Panels*',
  'panel pihole | panel syncthing | panel tailscale',
  '',
  '*Vault (Vaultwarden)*',
  'vault list — every entry',
  'vault get <site> — username and password',
  'vault delete <site> — asks to confirm first',
  'vault confirm — confirms the pending delete',
  '',
  '*Media*',
  'movie <name> — search a movie',
  'series <name> — search a series',
  'book <name> — search an ebook',
  'grab <n> — request result n (valid for 5 min)',
  'queue — what is downloading',
  'media up — start the media stack',
  'media down — stop the media stack',
  '',
  '*Other*',
  'heartbeat — push the status summary now',
  'run <job> — run a configured job',
  'backup — last backup result',
  'restart — restart the daemon',
  'help — this list',
].join('\n');

module.exports = { HELP };
