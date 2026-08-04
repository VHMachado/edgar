<p align="center">
  <img src="docs/edgar.png" alt="Edgar" width="220">
</p>

<h1 align="center">Edgar</h1>

A WhatsApp bot that watches a home server and answers questions about it.

You text it `status`, it texts back what every service is doing. It messages you
on its own when something breaks, when a backup finishes, when a cron job fails.
It can read your Vaultwarden vault, restart itself, and run jobs you configure.

**No LLM.** Messages go through a regex table to a shell script and back. Same
input, same output, every time — and no API bill.

```
🟢 ALL OK — 14:30

📡 Services
✅ 🛡️ pihole — FTL up, DNS resolving (example.com -> 93.184.216.34)
✅ 🌐 unbound — Recursion up on port 5335 (example.com -> 93.184.216.34)
✅ 🔄 syncthing — Unit active, API answering, all folders healthy
✅ 🔒 tailscale — Connected, IP 100.x.y.z, 4 active peer(s)
✅ 🔑 vaultwarden — Container running, HTTPS answering

📊 Hardware
🖥️ CPU: 0.21/core (21%)
🧠 RAM: 43.8% (2360MB/5390MB)
💿 /: 38% (204GB free)
⏱️ Uptime: 12d 4h 18m
```

---

## How it fits together

```
WhatsApp  ──►  edgar-bot.js  ──►  dispatch.js  ──►  handlers.js  ──►  scripts/*.sh
                    ▲                                                      │
                    │                                                 JSON │
                    └───────────── POST /send ◄── cron jobs ◄──────────────┘
```

- **`bot/`** — the Node daemon. Talks to WhatsApp over [Baileys], routes
  messages, and exposes `POST /send` so anything else can push you a message.
  `media.js` is the exception to the diagram above: it calls Jellyseerr and
  Prowlarr over HTTP instead of shelling out.
- **`scripts/`** — the plumbing. Every script prints JSON, so the bot never
  parses human text. `monitor.sh` runs from cron and writes the state;
  everything else reads it.
- **`systemd/`** — the unit file.

The bot and the scripts are meant to run **on the machine being monitored**. No
SSH round-trip on every message.

[Baileys]: https://github.com/WhiskeySockets/Baileys

---

## Requirements

- Linux with systemd (developed on Debian 12)
- Node.js 20+
- `jq`, `curl`, `python3` (only `panel.sh` needs python)
- A **second phone number** for the bot. It logs into WhatsApp as that number by
  scanning a QR code, exactly like WhatsApp Web. Do not use your own number —
  the bot ignores messages it sends itself, and you want to text *it*.
- Optional, per feature: Pi-hole, Unbound, Syncthing, Tailscale, Samba, Docker +
  Vaultwarden, the Bitwarden CLI (`bw`), `restic` + a Backblaze B2 bucket.
- Optional, for the media commands: Jellyseerr and Prowlarr.

Nothing is mandatory. `CHECKS` in `config.env` decides which services get
checked; drop the ones you do not run.

---

## Install

### 1. Put the files in place

```bash
sudo mkdir -p /opt/edgar-bot /opt/nas-monitor
sudo chown -R "$USER" /opt/edgar-bot /opt/nas-monitor

git clone https://github.com/VHMachado/edgar.git
cp -r edgar/bot/*     /opt/edgar-bot/
cp -r edgar/scripts/* /opt/nas-monitor/
chmod +x /opt/nas-monitor/*.sh

cd /opt/edgar-bot && npm install
```

### 2. Configure

Three files, none of which belong in git:

```bash
cd /opt/edgar-bot && cp .env.example .env && chmod 600 .env
cd /opt/nas-monitor && cp config.env.example config.env && chmod 600 config.env
cp restic.env.example restic.env && chmod 600 restic.env   # only if you want backups
```

Fill them in. The comments in each `.example` explain every field. The two that
matter most:

```bash
# /opt/edgar-bot/.env
EDGAR_TOKEN=$(openssl rand -hex 32)   # shared secret for POST /send
EDGAR_ALLOWLIST=15551234567           # your number — everyone else is ignored
```

`EDGAR_ALLOWLIST` is the only thing standing between a stranger and your vault.
It is checked before anything is dispatched. Set it.

The shell scripts read `/opt/edgar-bot/.env` too, so the token and your phone
number are defined in exactly one place.

### 3. Pair with WhatsApp

Run it in the foreground once and scan the QR code with the bot's phone
(WhatsApp → Settings → Linked devices → Link a device):

```bash
cd /opt/edgar-bot && node edgar-bot.js
```

Once it logs `connection open`, stop it. The session now lives in
`/opt/edgar-bot/creds/` — treat that directory like a password.

### 4. Run it as a service

```bash
sudo cp edgar/systemd/edgar-bot.service /etc/systemd/system/
sudo sed -i "s/^User=CHANGEME/User=$USER/" /etc/systemd/system/edgar-bot.service
mkdir -p /opt/edgar-bot/logs
sudo systemctl daemon-reload
sudo systemctl enable --now edgar-bot
```

For the `restart` command to work, let the service user restart the unit without
a password — `sudo visudo -f /etc/sudoers.d/edgar`:

```
youruser ALL=(root) NOPASSWD: /bin/systemctl restart edgar-bot.service
```

### 5. Schedule the background jobs

`crontab -e`:

```cron
*/5     * * * * /opt/nas-monitor/monitor.sh         >> /opt/nas-monitor/logs/monitor.log 2>&1
*/30    * * * * /opt/nas-monitor/heartbeat.sh       >> /opt/nas-monitor/logs/heartbeat-cron.log 2>&1
5-55/10 * * * * /opt/nas-monitor/alerts.sh          >> /opt/nas-monitor/logs/alerts-cron.log 2>&1
2-52/10 * * * * /opt/nas-monitor/downloads-report.sh >> /opt/nas-monitor/logs/downloads-cron.log 2>&1
0       4 * * * /opt/nas-monitor/cleanup.sh         >> /opt/nas-monitor/logs/cleanup.log 2>&1
30     12 * * * /opt/nas-monitor/restic-backup.sh   >> /opt/nas-monitor/logs/backup-cron.log 2>&1
```

Those offsets are deliberate. Anything written as `*/N` fires on the hour, so
`*/30` and `*/10` collide at :00 and :30 and you get two unrelated messages in
the same second — a status summary and an alert, arriving as one wall of text.
Staggering them keeps each message its own event:

| Job | Fires at |
|---|---|
| `heartbeat.sh` | :00 :30 |
| `downloads-report.sh` | :02 :12 :22 :32 :42 :52 |
| `alerts.sh` | :05 :15 :25 :35 :45 :55 |

Give any new message-sending job its own offset rather than a bare `*/N`.

`monitor.sh` is the one that matters — without it, `status` has nothing to read.

Text the bot `status`. You should get an answer.

---

## Commands

| You send | You get |
|---|---|
| `status`, `hi`, `good morning` | every service, one line each |
| `issues` | only what is broken |
| `cron` | last result of each wrapped job |
| `pihole`, `unbound`, `syncthing`, `tailscale`, `samba`, `vaultwarden` | one service |
| `cpu`, `ram`, `swap`, `disk`, `uptime` | one metric |
| `resources` | all of them |
| `panel pihole`, `panel syncthing`, `panel tailscale` | a detailed panel |
| `vault list` | every entry in the vault |
| `vault get <site>` | username and password |
| `vault delete <site>` → `vault confirm` | deletes to the vault trash |
| `movie <name>`, `series <name>`, `book <name>` | search, numbered results |
| `grab <n>` | request result `n` from the last search |
| `queue` | what is downloading right now, with progress bars |
| `media up`, `media down` | start or stop the whole media stack |
| `heartbeat` | pushes the full summary right now |
| `run <job>` | runs a job from `EDGAR_JOBS` |
| `backup` | tail of the last backup log |
| `restart` | restarts the daemon |
| `help` | the list above |

Anything unrecognised gets the help text, so a typo never does something
surprising.

### Changing the commands

Two files, and nothing else needs to know:

**[`bot/dispatch.js`](bot/dispatch.js) — the trigger words.** An ordered array of
`{ pattern, handler }`. First match wins, so specific patterns sit above generic
ones.

To teach an existing command a new word, add it to the alternation:

```js
{ pattern: /^\s*(cpu|load|processor)\s*\??\s*$/i, handler: h.resource },
```

To add a command: one entry here, one function in
[`bot/handlers.js`](bot/handlers.js), one line in [`bot/help.js`](bot/help.js).
(The media commands live in [`bot/media.js`](bot/media.js) instead, since they
talk to HTTP APIs rather than shell scripts.)

```js
// dispatch.js — above the generic patterns
{ pattern: /^\s*(?:temp|temperature)\s*\??\s*$/i, handler: h.temperature },
```

```js
// handlers.js
async function temperature() {
  const r = await runShell('sensors -j');
  if (!r.ok) return fail(r);
  return `🌡️ ${JSON.parse(r.stdout)['coretemp-isa-0000']['Package id 0'].temp1_input}°C`;
}
// ...and add `temperature` to module.exports
```

**[`bot/handlers.js`](bot/handlers.js) — what comes back.** All reply text lives
here. Rewrite the strings freely; nothing parses them.

Keep patterns anchored (`^…$`) and case-insensitive. Unanchored patterns fire on
ordinary conversation — `/status/` would match "what's the status of my order".

Run the routing check after any change:

```bash
cd bot && node test-dispatch.js
```

It asserts which handler each message reaches, without touching the shell or the
network. Add a line to `CASES` for whatever you added — the bugs this catches
are the ordering ones, where a generic pattern swallows a specific one.

### The media commands

Off by default. Fill in the keys and they turn on:

```bash
# /opt/edgar-bot/.env
JELLYSEERR_KEY=...   # Jellyseerr > Settings > General > API Key
PROWLARR_KEY=...     # Prowlarr > Settings > General
```

Then a search, a pick, and a notification:

```
you:   series deep space nine
edgar: 📺 Results for "deep space nine":

       1. *Star Trek: Deep Space Nine* (1993)
       2. ...

       Reply: grab 1
you:   grab 1
edgar: ✅ Requested: *Star Trek: Deep Space Nine* (1993)
```

A pick expires after five minutes, so a stale `grab 1` cannot request something
you no longer have on screen.

Movies and series go through Jellyseerr, which hands off to Sonarr/Radarr.
**Books skip that layer** and talk to Prowlarr directly — Readarr was retired
upstream and LazyLibrarian's add-book API is broken (it answers `OK` and writes
nothing), so there is no book manager left to request from. Prowlarr searches
and grabs on its own, dropping the torrent into a `books` category for whatever
imports your library. Book results are sorted by seeders, because a dead swarm
never finishes.

#### Getting notified when it lands

`setup-webhook.js` points Jellyseerr's webhook back at the bot:

```bash
cd /opt/edgar-bot && node setup-webhook.js --test
```

Jellyseerr runs in a container, and `127.0.0.1` inside a container is not the
host — so the bot has to listen on the Docker bridge gateway as well:

```bash
# /opt/edgar-bot/.env
EDGAR_HTTP_DOCKER_HOST=172.20.0.1
```

Pin that subnet in your compose file or the address will move, and let it
through the firewall:

```bash
sudo ufw allow from 172.20.0.0/16 to any port 18790 proto tcp
```

Jellyseerr can only send an `Authorization` header, so `/send` accepts either
that or `X-Edgar-Token`. The value is the raw token — no `Bearer` prefix.

### Speaking another language

Edgar was originally Portuguese. Nothing in the design is English-specific:
translate the patterns in `dispatch.js`, the strings in `handlers.js`, and the
text in `help.js`. The scripts print JSON, so they do not need touching.

### Adding a runnable job

Anything in `EDGAR_JOBS` becomes `run <name>`:

```bash
# /opt/edgar-bot/.env
EDGAR_JOBS='{"photos":"/home/me/.venv/bin/python /home/me/organize-photos.py"}'
```

Jobs run through `cron-wrapper.sh`, so the result also shows up under `cron` and
a failure triggers an alert. Wrap your real cron jobs the same way:

```cron
0 12 * * * /opt/nas-monitor/cron-wrapper.sh "photos" /home/me/.venv/bin/python /home/me/organize-photos.py
```

---

## The HTTP API

The bot listens on `127.0.0.1:18790`. Anything on the box can message you:

```bash
curl -X POST http://127.0.0.1:18790/send \
  -H "X-Edgar-Token: $EDGAR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"text":"deploy finished"}'
```

`to` is optional and defaults to `EDGAR_DEFAULT_TO`. Only `POST /send` exists.

To reach it from another machine, set `EDGAR_HTTP_EXTRA_HOST` to a second bind
address. Use a VPN address (Tailscale, WireGuard) — the only protection is the
token, so this must never face the internet.

> **Windows / PowerShell 5.1:** passing a string body makes `Invoke-RestMethod`
> encode it as ANSI, and every emoji turns into `?`. Send bytes instead:
>
> ```powershell
> $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
> Invoke-RestMethod -Uri $url -Method Post -Body $bytes -ContentType 'application/json' -Headers $headers
> ```

---

## The JSON contract

`handlers.js` parses these shapes. Change a field name in a script and the bot
answers `❌ undefined` — which is exactly how this list came to be documented.

| Command | Emits |
|---|---|
| `status.sh all` | `{timestamp, has_issues, services: [{name, status, details}]}` |
| `status.sh issues` | `{has_service_issues, has_cron_failures, service_issues[], cron_failures_24h[]}` |
| `status.sh cron` | `{cron_jobs: [{job_name, timestamp, exit_code, status, command, stdout, stderr}]}` |
| `status.sh resources` | `{cpu{}, memory{}, swap{}, disks[], uptime{}, has_resource_warnings, warnings[]}` |
| `status.sh <service>` | one `{name, status, details}` object |
| `vaultwarden.sh list` | `{count, items: [{name, username}]}` |
| `vaultwarden.sh get` | `{count, items: [{name, username, password}]}` |
| `vaultwarden.sh search` | `{count, items: [{id, name, username}]}` |
| `vaultwarden.sh delete` | `{deleted, errors}` |
| `panel.sh <service>` | pre-formatted text, or `ERROR: …` |
| `downloads.sh` | `{ok, downloading[], completed[], count_downloading, count_completed}` |
| `fix-syncthing-markers.sh --check` | `{error_count, errors[], out_of_sync_count, out_of_sync[]}` |

`status` is `ok`, `warn` or `error`. Check the real output before touching a
formatter:

```bash
/opt/nas-monitor/status.sh all | jq keys
```

---

## Security

This bot reads your password vault over WhatsApp. Be deliberate about it.

- **`EDGAR_ALLOWLIST` is the whole access-control model.** Messages from anyone
  else are logged and dropped. Group messages are ignored outright.
- **`vault get` sends plaintext passwords over WhatsApp.** They are
  end-to-end encrypted in transit and then sit in your chat history forever. If
  that is not a trade you want, delete the four vault entries from `dispatch.js`
  and the `bw` config from `config.env`.
- **`vault delete` always asks first** and moves entries to the vault trash, not
  oblivion.
- **`creds/` is a live WhatsApp session.** Anyone who copies it is your bot.
  `.gitignore` covers it; keep it that way.
- **Never expose port 18790 publicly.** Token auth only, no rate limiting.
- **`.env`, `config.env` and `restic.env` are gitignored.** They hold the send
  token, a Pi-hole password, a Syncthing API key and B2 credentials. Keep them
  `chmod 600`. If you ever push one by accident, rotate everything in it — git
  history is forever.

### Known WhatsApp quirks

- **`@lid` JIDs.** Some accounts send from a Linked-Identity JID instead of a
  phone JID, and the allowlist check never matches. The bot resolves these via
  the `lid-mapping-*.json` files Baileys writes into `creds/`. If your messages
  are being dropped with `unknown LID — not in creds map` in the log, send one
  message and restart — the mapping gets written on the next `creds.update`.
- **Baileys is unofficial.** WhatsApp does not support this. Using it on a
  number you care about carries a real ban risk. Use a spare number.

---

## Troubleshooting

```bash
systemctl status edgar-bot          # is it up
journalctl -u edgar-bot -f          # live log
/opt/nas-monitor/monitor.sh         # write a fresh state file
/opt/nas-monitor/status.sh all | jq # what the bot sees
cd /opt/edgar-bot && node test-dispatch.js  # is routing sane
```

| Symptom | Usually |
|---|---|
| No reply at all | your number is not in `EDGAR_ALLOWLIST`, or an `@lid` JID (see above) |
| `❌ undefined` in a reply | a script changed a field name — check the JSON contract |
| `No monitor result yet` | `monitor.sh` has never run; add the cron entry |
| Vault commands time out | `bw` needs ~40s; callers already allow 90s. Check `bw login` |
| Emoji arrive as `?` | a PowerShell caller sending a string body (see above) |
| `EDGAR_TOKEN is not set` at startup | `.env` missing, or `EnvironmentFile=` points elsewhere |

---

## License

MIT. See [LICENSE](LICENSE).
