'use strict';

// Media commands: search something, pick a result, get told when it lands.
//
// Movies and TV go through Jellyseerr, which owns the request lifecycle and
// hands off to Sonarr/Radarr. Books skip that layer entirely — see the comment
// on prowlarr() below.
//
// A search writes its candidates to state.json; "grab <n>" reads them back.
// That is why the two live in the same file.

const config = require('./config');
const { readState, writeState } = require('./handlers');

// How long a search result list stays pickable. Long enough to walk away from
// the phone, short enough that a stale "grab 1" cannot request the wrong thing.
const PICK_TTL_MS = 5 * 60 * 1000;

const MAX_RESULTS = 3;
// Book results are releases, not works: several rows are the same book in
// different formats, so show more of them.
const MAX_BOOK_RESULTS = 5;

const HTTP_TIMEOUT_MS = 20000;
// Prowlarr queries every indexer before answering. Measured at 22.7s with ten
// of them, so the 20s above is not enough.
const PROWLARR_TIMEOUT_MS = 60000;

// Jellyseerr media availability codes.
const AVAIL = { 2: 'pending', 3: 'downloading', 4: 'partial', 5: 'in the library' };

// ---- http ----

async function jsr(path, opts = {}) {
  if (!config.JELLYSEERR_KEY) throw new Error('JELLYSEERR_KEY is not set');
  const res = await fetch(`${config.JELLYSEERR_URL}/api/v1${path}`, {
    ...opts,
    headers: {
      'X-Api-Key': config.JELLYSEERR_KEY,
      'Content-Type': 'application/json',
      ...(opts.headers || {}),
    },
    signal: AbortSignal.timeout(HTTP_TIMEOUT_MS),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`Jellyseerr ${res.status}: ${text.slice(0, 200)}`);
  return text ? JSON.parse(text) : {};
}

// Books talk to Prowlarr directly instead of going through a *arr app.
// Readarr was retired upstream and LazyLibrarian's add-book API does not work
// (it answers "OK" and writes nothing), so there is no book manager to request
// from. Prowlarr can search and grab on its own, which is all this needs:
// it hands the torrent to the download client under a "books" category, and
// whatever watches that category imports the file.
async function prowlarr(path, opts = {}) {
  if (!config.PROWLARR_KEY) throw new Error('PROWLARR_KEY is not set');
  const res = await fetch(`${config.PROWLARR_URL}/api/v1${path}`, {
    ...opts,
    headers: {
      'X-Api-Key': config.PROWLARR_KEY,
      'Content-Type': 'application/json',
      ...(opts.headers || {}),
    },
    signal: AbortSignal.timeout(PROWLARR_TIMEOUT_MS),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`Prowlarr ${res.status}: ${text.slice(0, 200)}`);
  return text ? JSON.parse(text) : {};
}

// ---- formatting ----

function humanSize(bytes) {
  if (!bytes) return '?';
  const mb = bytes / 1024 / 1024;
  return mb >= 1024 ? `${(mb / 1024).toFixed(1)} GB` : `${Math.round(mb)} MB`;
}

function year(item) {
  const d = item.releaseDate || item.firstAirDate || '';
  return d ? d.slice(0, 4) : 'no year';
}

function savePicks(items) {
  const state = readState();
  state.mediaPick = { at: Date.now(), items };
  writeState(state);
}

function takePicks() {
  const state = readState();
  const pick = state.mediaPick;
  if (!pick || Date.now() - pick.at > PICK_TTL_MS) return null;
  return pick.items;
}

function renderList(header, items) {
  const lines = items.map((it, i) => {
    const status = it.status ? ` — already ${it.status}` : '';
    return `${i + 1}. *${it.title}* (${it.year})${status}`;
  });
  return `${header}\n\n${lines.join('\n')}\n\nReply: grab 1`;
}

// ---- handlers ----

function makeSearch(kind, emoji, label) {
  return async (_msg, match, opts = {}) => {
    const query = (match[1] || '').trim();
    if (!query) return `${emoji} Usage: ${label} <name>`;
    if (opts.sendFeedback) await opts.sendFeedback(`🔍 Searching ${label} "${query}"...`);

    const data = await jsr(`/search?query=${encodeURIComponent(query)}&page=1`);
    const hits = (data.results || [])
      .filter((r) => r.mediaType === kind)
      .slice(0, MAX_RESULTS);

    if (!hits.length) return `${emoji} Nothing found for "${query}".`;

    const items = hits.map((r) => ({
      kind,
      id: r.id,
      title: r.title || r.name,
      year: year(r),
      status: AVAIL[r.mediaInfo && r.mediaInfo.status] || null,
    }));
    savePicks(items);
    return renderList(`${emoji} Results for "${query}":`, items);
  };
}

const searchMovie = makeSearch('movie', '🎬', 'movie');
const searchTv = makeSearch('tv', '📺', 'series');

// 7000 = Books, 7020 = Books/EBook in the Torznab/Newznab category tree.
// Prowlarr wants the parameter repeated; a comma-separated list returns 400.
const BOOK_CATEGORIES = 'categories=7000&categories=7020';

async function searchBook(_msg, match, opts = {}) {
  const query = (match[1] || '').trim();
  if (!query) return '📚 Usage: book <name>';
  if (opts.sendFeedback) await opts.sendFeedback(`🔍 Searching book "${query}"...`);

  const releases = await prowlarr(
    `/search?query=${encodeURIComponent(query)}&${BOOK_CATEGORIES}&type=search`
  );
  if (!releases.length) {
    return `📚 Nothing found for "${query}".\nNo book indexer configured in Prowlarr?`;
  }

  // Sort by seeders: a dead swarm never finishes, and the indexer's own
  // ordering ignores that.
  const hits = releases
    .slice()
    .sort((a, b) => (b.seeders || 0) - (a.seeders || 0))
    .slice(0, MAX_BOOK_RESULTS);

  const items = hits.map((r) => ({
    kind: 'book',
    guid: r.guid,
    indexerId: r.indexerId,
    title: r.title,
    year: `${humanSize(r.size)}, ${r.seeders || 0} seeds`,
    status: null,
  }));
  savePicks(items);
  return renderList(`📚 Results for "${query}":`, items);
}

async function request(_msg, match, opts = {}) {
  const items = takePicks();
  if (!items) return '⏱️ No recent search. Send *movie <name>* first.';

  const n = parseInt(match[1], 10);
  const item = items[n - 1];
  if (!item) return `❌ Pick between 1 and ${items.length}.`;

  if (opts.sendFeedback) await opts.sendFeedback(`📥 Requesting "${item.title}"...`);

  if (item.kind === 'book') {
    // POST /search is Prowlarr's grab: it pushes the release to the download
    // client configured *in Prowlarr*, which is separate from the one Sonarr
    // and Radarr use.
    await prowlarr('/search', {
      method: 'POST',
      body: JSON.stringify({ guid: item.guid, indexerId: item.indexerId }),
    });
  } else {
    const body = { mediaType: item.kind, mediaId: item.id };
    if (item.kind === 'tv') body.seasons = 'all';
    await jsr('/request', { method: 'POST', body: JSON.stringify(body) });
  }

  const state = readState();
  delete state.mediaPick;
  writeState(state);

  return `✅ Requested: *${item.title}* (${item.year})\nI will tell you when it is ready.`;
}

async function queue(_msg, _match, opts = {}) {
  if (opts.sendFeedback) await opts.sendFeedback('🔍 Checking the queue...');
  const data = await jsr('/request?take=20&filter=processing');
  const reqs = data.results || [];
  if (!reqs.length) return '📭 Queue is empty.';

  // One extra request per row to turn a tmdbId into a title — the request API
  // does not return one. Fine at this size; cache it if the queue ever grows.
  const lines = await Promise.all(
    reqs.map(async (r) => {
      const m = r.media || {};
      const emoji = m.mediaType === 'tv' ? '📺' : '🎬';
      try {
        const det = await jsr(`/${m.mediaType}/${m.tmdbId}`);
        return `${emoji} ${det.title || det.name}`;
      } catch {
        return `${emoji} tmdb:${m.tmdbId}`;
      }
    })
  );
  return `📥 *Downloading now* (${lines.length})\n\n${lines.join('\n')}`;
}

module.exports = { searchMovie, searchTv, searchBook, request, queue };
