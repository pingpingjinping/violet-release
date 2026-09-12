import { syncActivity } from './activity-sync';
import { getGroups, getBookmarkArticles } from '../api/bookmarks';
import { transactBookmarkSync } from './user-database';

const CONFIG_KEY = 'violet-bookmark-sync-config';
const ENDPOINT = `${window.location.protocol}//${window.location.hostname}:3002/api/bookmark-sync`;
type Config = { token: string; days: number };
type Payload = { requestId: string; baseRevision: number; add: string[]; remove: string[] };
type State = { Id: 'state'; revision: number; shadow: string[]; lastSuccess: number;
  leaseUntil: number; pending?: { payload: Payload; captured: string[] } };

export function getBookmarkSyncConfig(): Config {
  try {
    const value = JSON.parse(localStorage.getItem(CONFIG_KEY) ?? '{}');
    return { token: typeof value.token === 'string' ? value.token : '', days: value.days === 7 ? 7 : 1 };
  } catch { return { token: '', days: 1 }; }
}
export function saveBookmarkSyncConfig(config: Config) {
  localStorage.setItem(CONFIG_KEY, JSON.stringify(config));
}
function requestId() {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  const hex = Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0,8)}-${hex.slice(8,12)}-${hex.slice(12,16)}-${hex.slice(16,20)}-${hex.slice(20)}`;
}
function ids(articles: Array<{ Article: string }>) {
  return [...new Set(articles.map(a => String(a.Article)).filter(x => /^\d{1,20}$/.test(x)))];
}

export async function syncBookmarks(force = false): Promise<number | null> {
  const count = await syncArticleBookmarks(force);
  await syncActivity(force);
  return count;
}
async function syncArticleBookmarks(force: boolean): Promise<number | null> {
  const config = getBookmarkSyncConfig();
  if (!config.token) return null;
  await getGroups();
  await getBookmarkArticles(); // Finish legacy storage migration first.
  const state = await transactBookmarkSync<State | null>((articles, saved, _store, meta) => {
    const s: State = saved ?? { Id: 'state', revision: 0, shadow: [], lastSuccess: 0, leaseUntil: 0 };
    const now = Date.now();
    if (s.leaseUntil > now || (!force && now - s.lastSuccess < config.days * 86400000)) return null;
    if (!s.pending) {
      const captured = ids(articles);
      const current = new Set(captured), shadow = new Set(s.shadow);
      s.pending = { captured, payload: { requestId: requestId(), baseRevision: s.revision,
        add: captured.filter(id => !shadow.has(id)), remove: s.shadow.filter(id => !current.has(id)) } };
    }
    s.leaseUntil = now + 120000;
    meta.put(s);
    return s;
  });
  if (!state?.pending) return null;
  try {
    const response = await fetch(ENDPOINT, { method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Violet-Sync-Token': config.token },
      body: JSON.stringify(state.pending.payload), signal: AbortSignal.timeout(60000) });
    if (!response.ok) throw new Error(`Sync HTTP ${response.status}`);
    const data = await response.json();
    if (!Number.isSafeInteger(data.revision) || data.revision < state.revision ||
        !Array.isArray(data.articles) || data.articles.length > 100000 ||
        data.articles.some((x: unknown) => typeof x !== 'string' || !/^\d{1,20}$/.test(x))) {
      throw new Error('Invalid sync response');
    }
    const group = (await getGroups()).find(g => g.Name === 'violet_default') ?? (await getGroups())[0];
    await transactBookmarkSync((articles, saved: State, store, meta) => {
      if (saved?.pending?.payload.requestId !== state.pending!.payload.requestId) throw new Error('Sync state changed');
      const captured = new Set(state.pending!.captured);
      const current = new Set(ids(articles));
      const wanted = new Set<string>(data.articles);
      // Keep local edits made while the request was in flight.
      for (const id of current) if (!captured.has(id)) wanted.add(id);
      for (const id of captured) if (!current.has(id)) wanted.delete(id);
      let nextId = articles.reduce((n, a) => Math.max(n, a.Id), 0) + 1;
      for (const article of articles) if (/^\d{1,20}$/.test(String(article.Article)) && !wanted.has(String(article.Article))) store.delete(article.Id);
      for (const id of wanted) if (!current.has(id)) store.put({ Id: nextId++, Article: id, GroupId: group.Id, DateTime: new Date().toISOString() });
      meta.put({ Id: 'state', revision: data.revision, shadow: data.articles, lastSuccess: Date.now(), leaseUntil: 0 });
    });
    window.dispatchEvent(new Event('violet-bookmarks-synced'));
    return data.articles.length;
  } catch (error) {
    await transactBookmarkSync((_articles, saved: State, _store, meta) => {
      if (saved?.pending?.payload.requestId === state.pending!.payload.requestId) meta.put({ ...saved, leaseUntil: 0 });
    });
    throw error;
  }
}
