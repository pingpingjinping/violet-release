const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const deps = process.env.VIOLET_TEST_MODULES;
if (!deps) throw new Error('Set VIOLET_TEST_MODULES to the test dependency node_modules directory');
const { build } = require(path.join(deps, 'esbuild'));
const { indexedDB } = require(path.join(deps, 'fake-indexeddb'));

(async () => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'violet-activity-test-'));
  try {
    const out = path.join(temp, 'client.cjs');
    await build({ entryPoints: [path.join(__dirname, 'activity_client_entry.ts')], outfile: out, bundle: true, platform: 'node', format: 'cjs' });
    const values = new Map();
    global.localStorage = { getItem: k => values.get(k) ?? null, setItem: (k, v) => values.set(k, String(v)) };
    global.window = { location: { protocol: 'http:', hostname: 'localhost' }, localStorage, dispatchEvent() {} };
    global.indexedDB = indexedDB;
    const client = require(out);
    client.saveBookmarkSyncConfig({ token: 'test-only-token', days: 1 });
    const actualDownloads = [
      { Id: 1, Article: '55', Status: 'completed', DateTime: '2026-01-01T00:00:00Z', Path: '/private/fixture' },
      { Id: 2, Article: '66', Status: 'failed', DateTime: '2026-01-01T00:00:00Z' },
      { Id: 3, Article: '77', Status: 'downloading', DateTime: '2026-01-01T00:00:00Z' },
    ];
    client.api.defaults.adapter = async config => ({ data: config.url === '/downloads/ids'
      ? { articleIds: actualDownloads.map(r => r.Article) }
      : { downloads: actualDownloads, totalCount: 3, page: 0, pageSize: 1000 }, status: 200, statusText: 'OK', headers: {}, config });
    await client.putUserItem(client.USER_STORES.readHistory, { Id: 1, Article: '42', DateTimeStart: '2026-01-01T00:00:00Z', DateTimeEnd: null, LastPage: 11, Type: 0 });
    const appDevice = '00000000-0000-4000-8000-000000000001';
    const records = [
      { kind: 'read', device: appDevice, origin: 'app', article: '99', timestamp: Date.parse('2026-01-02T00:00:00Z'), page: 23, type: 0 },
      { kind: 'download', device: appDevice, origin: 'app', article: '88', timestamp: Date.parse('2026-01-02T00:00:00Z'), page: 0, type: 0 },
    ];
    let sent, calls = 0;
    global.fetch = async (_url, request) => {
      calls++; sent = JSON.parse(request.body);
      return { ok: true, json: async () => ({ version: 1, records }) };
    };
    await client.syncActivity(true);
    assert.equal(sent.origin, 'web');
    assert.deepEqual(sent.download.map(r => r.article), ['55']);
    assert.equal(sent.read[0].page, 11);
    assert(!JSON.stringify(sent).includes('/private'));
    assert.equal((await client.getLocalHistory()).length, 1, 'remote records must not become local sessions');
    assert((await client.getHistoryIds()).includes('99'));
    assert((await client.getDownloadIds()).includes('88'));
    assert(!(await client.getDownloads()).downloads.some(r => r.Article === '88'), 'remote download must not become a local file/job');
    await client.syncActivity(false);
    assert.equal(calls, 1, 'daily interval must avoid constant polling');
    const saved = await client.getSharedActivity();
    const lastSuccess = localStorage.getItem('violet-activity-last-success');
    global.fetch = async () => { throw new Error('offline'); };
    await assert.rejects(client.syncActivity(true));
    assert.deepEqual(await client.getSharedActivity(), saved);
    assert.equal(localStorage.getItem('violet-activity-last-success'), lastSuccess);
    let release;
    global.fetch = async () => new Promise(resolve => { release = () => resolve({ ok: true, json: async () => ({ version: 1, records }) }); });
    const pending = client.syncActivity(true);
    while (!release) await new Promise(resolve => setImmediate(resolve));
    await client.updateReadLog(1, { LastPage: 2 });
    release(); await pending;
    assert.equal((await client.getLocalHistory())[0].LastPage, 2, 'in-flight reading edits must survive cache replacement');
    assert.equal((await client.getSharedActivity()).length, 2, 'retries must not duplicate shared records');
    assert.throws(() => client.validateActivity([{ ...records[0], page: -1 }]));
    assert.throws(() => client.validateActivity([{ ...records[0], timestamp: Infinity }]));
    console.log('Web client tests passed: completed-only upload, remote history and download IDs, no fake local files, interval, offline retry and in-flight edits');
  } finally { fs.rmSync(temp, { recursive: true, force: true }); }
})().catch(error => { console.error(error); process.exitCode = 1; });
