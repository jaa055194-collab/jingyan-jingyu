// node --test for web/src/demo-host.js, the ?demo=1 host of PROTOCOL.md section 1. Clock, interval timers
// and message delivery are injected, so these tests run synchronously and leave no timers behind.
import { describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import * as D from '../web/src/demo-host.js';
import { Bridge } from '../web/src/bridge.js';
import { SnapshotInterpolator } from '../web/src/interp.js';
import { PLOT_HALF, VILLA_BOX, assignSlots, selectResidents } from '../web/src/lots.js';
import { MAX_RESIDENTS, MOTIONS, helloPayload, parseEnvelope, validateHelloAck, validateLayout, validatePresence } from '../web/src/protocol.js';

const SPEC = readFileSync(new URL('../PROTOCOL.md', import.meta.url), 'utf8');
const section = (n) => SPEC.split(/^## /m).find((part) => part.startsWith(`${n}.`)) ?? '';
const WALL = Date.UTC(2026, 10, 26, 4); // the demo host's wall clock
const DEFAULT_CONFIG = { theme: 'light', quality: 'high', maxResidents: 8, statsIntervalMs: 0 };
const types = (msgs) => msgs.map((m) => m.type);
const tOf = (msgs) => msgs.filter((m) => m.type === 'presence').map((m) => m.payload.t);

// Numbers within 1e-9, everything else strictly equal.
function near(actual, expected, msg) {
  for (const [k, v] of Object.entries(expected)) {
    if (typeof v === 'number') assert.ok(Math.abs(actual[k] - v) < 1e-9, `${msg}: ${k} is ${actual[k]}, expected ${v}`);
    else assert.equal(actual[k], v, `${msg}: ${k}`);
  }
}

// A demo host on a fake clock that starts at 5000 ms, fake interval timers and a delivery queue:
// tick() moves the clock and fires every live timer once, flush() delivers what was queued.
function demo(opts = {}) {
  const clock = { ms: 5000 };
  const timers = new Map();
  const cancelled = [];
  const pending = [];
  let nextId = 0;
  const host = D.createDemoHost({
    now: () => clock.ms,
    wallNow: () => WALL,
    every: (fn, ms) => { nextId += 1; timers.set(nextId, { fn, ms }); return nextId; },
    cancel: (id) => { cancelled.push(id); timers.delete(id); },
    deliver: (fn) => { pending.push(fn); },
    ...opts,
  });
  const got = [];
  host.onmessage = (event) => got.push(JSON.parse(event.data));
  return {
    host, got, timers, cancelled,
    intervals: () => [...timers.values()].map((tm) => tm.ms),
    hello: () => host.postMessage(JSON.stringify({ v: 1, type: 'hello', ts: 1, payload: helloPayload() })),
    tick(ms = 250) {
      clock.ms += ms;
      for (const tm of [...timers.values()]) tm.fn();
    },
    flush() {
      while (pending.length) pending.shift()();
    },
  };
}

describe('demo-host.js: synthetic street and residents', () => {
  test('PROTOCOL.md describes it: ?demo=1, 4 Hz presence, within the 2-5 Hz of section 5', () => {
    const s1 = section(1);
    for (const s of ['`?demo=1`', '`web/src/demo-host.js`', '`hello-ack`', '4 Hz']) assert.ok(s1.includes(s), s);
    assert.equal(D.DEMO_HZ, 4);
    const range = /(\d+) \S{1,3} (\d+) Hz/.exec(section(5));
    assert.ok(range, 'section 5 gives a presence rate');
    assert.ok(D.DEMO_HZ >= Number(range[1]) && D.DEMO_HZ <= Number(range[2]), range[0]);
  });

  test('pathAt: stay, loop and stroll (A to B, wait, back, wait), periodic, with phase', () => {
    assert.deepEqual(D.pathAt({ kind: 'stay', p: [2, -1], motion: 'sit' }, 12345), { x: 2, z: -1, motion: 'sit' });
    const stroll = { kind: 'stroll', a: [0, 0], b: [4, -2], period: 1000 };
    for (const [ms, x, z, motion] of [[0, 0, 0, 'walk'], [200, 2, -1, 'walk'], [400, 4, -2, 'idle'], [450, 4, -2, 'idle'], [500, 4, -2, 'walk'],
      [700, 2, -1, 'walk'], [900, 0, 0, 'idle'], [999, 0, 0, 'idle'], [1200, 2, -1, 'walk'], [-800, 2, -1, 'walk'], [-100, 0, 0, 'idle']]) {
      near(D.pathAt(stroll, ms), { x, z, motion }, `stroll at ${ms} ms`);
    }
    near(D.pathAt({ ...stroll, phase: 200 }, 0), { x: 2, z: -1, motion: 'walk' }, 'stroll with phase');
    const loop = { kind: 'loop', c: [1, -3], r: 2, period: 1000 };
    for (const [ms, x, z] of [[0, 3, -3], [250, 1, -1], [500, -1, -3], [750, 1, -5], [1000, 3, -3], [-250, 1, -5]]) {
      near(D.pathAt(loop, ms), { x, z, motion: 'walk' }, `loop at ${ms} ms`);
    }
    near(D.pathAt({ ...loop, phase: 250 }, 0), { x: 1, z: -1 }, 'loop with phase');
  });

  test('every demo resident stays in its front yard and moves at about 1 m/s', () => {
    for (const r of D.DEMO_RESIDENTS) {
      const span = 2 * (r.path.period ?? 1000);
      let prev = null;
      let top = 0;
      for (let ms = 0; ms <= span; ms += 10) {
        const p = D.pathAt(r.path, ms);
        assert.ok(Math.abs(p.x) <= PLOT_HALF && p.z >= -PLOT_HALF && p.z < VILLA_BOX.zMin, `${r.residentId} at ${ms} ms: (${p.x}, ${p.z})`);
        assert.ok(MOTIONS.includes(p.motion), `${r.residentId}: ${p.motion}`);
        if (prev) top = Math.max(top, Math.hypot(p.x - prev.x, p.z - prev.z) / 0.01);
        prev = p;
      }
      if (r.path.kind === 'stay') assert.equal(top, 0, r.residentId);
      else assert.ok(top > 0.9 && top < 1.1, `${r.residentId}: ${top.toFixed(3)} m/s`);
    }
  });

  test('presencePayload: a valid presence with all ten residents, positions rounded to mm, updatedAt a minute apart', () => {
    const ms = 1234;
    const payload = D.presencePayload(ms, D.DEMO_T0 + ms, WALL);
    const v = validatePresence(payload);
    assert.deepEqual(v.errors, []);
    assert.equal(v.t, D.DEMO_T0 + ms);
    assert.equal(v.residents.length, 10);
    assert.equal(D.DEMO_RESIDENTS.length, 10);
    payload.residents.forEach((r, i) => {
      const src = D.DEMO_RESIDENTS[i];
      const p = D.pathAt(src.path, ms);
      assert.deepEqual([r.residentId, r.spaceId, r.label, r.role, r.motion, r.y], [src.residentId, src.spaceId, src.label, src.role, p.motion, 0]);
      for (const k of ['x', 'z']) {
        assert.ok(Math.abs(r[k] - p[k]) <= 0.0005 + 1e-12, `${src.residentId}.${k}`);
        assert.ok(Math.abs(r[k] * 1000 - Math.round(r[k] * 1000)) < 1e-6, `${src.residentId}.${k} = ${r[k]}`);
      }
      assert.match(r.updatedAt, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/);
      assert.equal(Date.parse(r.updatedAt), WALL - i * 60000);
    });
  });

  test('the demo layout is valid: eight spaces on slots 0-7; the section 8 example is its first space', () => {
    const { spaces, errors } = validateLayout({ spaces: D.DEMO_SPACES });
    assert.deepEqual(errors, []);
    assert.deepEqual([...assignSlots(spaces)], D.DEMO_SPACES.map((s, i) => [s.spaceId, i]));
    const block = /```json\r?\n([\s\S]*?)```/.exec(section(8));
    const layout = block[1].split(/\r?\n/).filter((l) => l.trim()).map((l) => JSON.parse(l)).find((e) => e.type === 'layout');
    assert.deepEqual(layout.payload.spaces, [D.DEMO_SPACES[0]]);
    assert.ok(Object.isFrozen(D.DEMO_SPACES) && Object.isFrozen(D.DEMO_RESIDENTS));
  });

  test('with maxResidents 8, demo-resident-9 (oldest updatedAt) is culled and demo-resident-10 is unplaced', () => {
    const { residents } = validatePresence(D.presencePayload(0, D.DEMO_T0, WALL));
    const street = new Set(D.DEMO_SPACES.map((s) => s.spaceId));
    const opts = { maxResidents: MAX_RESIDENTS, isPlaced: (id) => street.has(id) };
    const ids = (...n) => n.map((k) => `demo-resident-${k}`);
    assert.deepEqual(selectResidents(residents, opts), { shown: ids(1, 2, 3, 4, 5, 6, 7, 8), culled: ids(9), unplaced: ids(10) });
    // With the camera at demo-resident-9's villa it is kept, and the next oldest one is culled instead.
    assert.deepEqual(selectResidents(residents, { ...opts, focusSpaceId: 'demo-home-8' }),
      { shown: ids(1, 2, 9, 3, 4, 5, 6, 7), culled: ids(8), unplaced: ids(10) });
  });
});

describe('createDemoHost (PROTOCOL.md section 3)', () => {
  test('answers hello with hello-ack, layout and a presence, then sends presence at 4 Hz', () => {
    const d = demo();
    d.flush();
    assert.deepEqual([d.got.length, d.timers.size], [0, 0]); // silent until the page says hello
    d.hello();
    assert.equal(d.got.length, 0); // delivered through deliver(), not from inside postMessage
    d.flush();
    assert.deepEqual(types(d.got), ['hello-ack', 'layout', 'presence']);
    assert.deepEqual(d.intervals(), [250]);
    for (let i = 0; i < 4; i++) d.tick();
    d.flush();
    assert.deepEqual(tOf(d.got), [100000, 100250, 100500, 100750, 101000]);
    d.got.forEach((m, i) => {
      assert.deepEqual(parseEnvelope(JSON.stringify(m)), { ok: true, msg: m });
      assert.deepEqual([m.id, m.ts], [`demo-${i + 1}`, WALL]);
    });
    assert.deepEqual(validateHelloAck(d.got[0].payload), { major: 1, compatible: true, config: DEFAULT_CONFIG, errors: [] });
    assert.deepEqual(d.got[1].payload, { spaces: D.DEMO_SPACES });
    for (const m of d.got.slice(2)) {
      assert.deepEqual(m.payload, JSON.parse(JSON.stringify(D.presencePayload(m.payload.t - D.DEMO_T0, m.payload.t, WALL))));
    }
    assert.deepEqual(d.host.received.map((m) => m.type), ['hello']);
  });

  test('t stays strictly increasing even when the clock does not move', () => {
    const d = demo();
    d.hello();
    d.tick(0);
    d.tick(0);
    d.tick(1);
    d.tick(500);
    d.flush();
    assert.deepEqual(tOf(d.got), [100000, 100001, 100002, 100003, 100501]);
  });

  test('pause stops presence until resume; resume sends one at once and restarts the 4 Hz timer (item 7)', () => {
    const d = demo();
    d.hello();
    d.host.pause();
    assert.equal(d.timers.size, 0);
    d.tick();
    d.tick();
    d.host.resume();
    d.tick();
    d.flush();
    assert.deepEqual(types(d.got), ['hello-ack', 'layout', 'presence', 'pause', 'resume', 'presence', 'presence']);
    assert.deepEqual(tOf(d.got), [100000, 100500, 100750]);
    assert.deepEqual([d.got[3].payload, d.got[4].payload], [{}, {}]);
    assert.deepEqual(d.intervals(), [250]);
  });

  test('every hello starts a new session: all of it is sent again and only one timer runs (item 2)', () => {
    const d = demo();
    d.hello();
    d.tick();
    d.hello();
    d.flush();
    assert.deepEqual(types(d.got), ['hello-ack', 'layout', 'presence', 'presence', 'hello-ack', 'layout', 'presence']);
    assert.deepEqual(tOf(d.got), [100000, 100250, 100251]);
    assert.deepEqual([d.timers.size, d.cancelled], [1, [1]]);
    assert.deepEqual(d.host.received.map((m) => m.type), ['hello', 'hello']);
  });

  test('send, stop, config, hz and the log of received page messages', () => {
    const d = demo({ config: { theme: 'dark', statsIntervalMs: 1000 }, hz: 5 });
    d.hello();
    d.host.send('theme', { mode: 'light' });
    d.host.send('focus', { kind: 'overview' });
    d.flush();
    assert.deepEqual(types(d.got), ['hello-ack', 'layout', 'presence', 'theme', 'focus']);
    assert.deepEqual(validateHelloAck(d.got[0].payload).config, { ...DEFAULT_CONFIG, theme: 'dark', statsIntervalMs: 1000 });
    assert.deepEqual([d.got[3].payload, d.got[4].payload], [{ mode: 'light' }, { kind: 'overview' }]);
    assert.deepEqual(d.intervals(), [200]);
    d.host.stop();
    d.host.stop();
    assert.deepEqual([d.timers.size, d.cancelled], [0, [1]]);
    const slow = demo({ hz: 2 });
    slow.hello();
    assert.deepEqual(slow.intervals(), [500]);

    const log = demo();
    log.host.postMessage('not json');
    for (let i = 0; i < 205; i++) log.host.postMessage(JSON.stringify({ v: 1, type: 'stats', id: `s${i}`, ts: 1, payload: {} }));
    assert.equal(log.host.received.length, 200);
    assert.deepEqual([log.host.received[0].id, log.host.received.at(-1).id], ['s5', 's204']);
    log.flush();
    assert.equal(log.got.length, 0); // only hello starts the demo
  });

  test('drives the page Bridge end to end, and the interpolator accepts every presence', () => {
    const d = demo();
    const seen = [];
    const bridge = new Bridge(d.host, { onMessage: (m) => seen.push(m), now: () => 42 });
    assert.equal(bridge.send('hello', helloPayload({ webgl: 2 })), true);
    assert.deepEqual(d.host.received, [{ v: 1, type: 'hello', ts: 42, payload: helloPayload({ webgl: 2 }) }]);
    d.flush();
    assert.equal(bridge.acked, true);
    d.tick();
    d.host.pause();
    d.tick();
    d.host.resume();
    d.flush();
    assert.deepEqual(types(seen), ['hello-ack', 'layout', 'presence', 'presence', 'pause', 'resume', 'presence']);
    assert.equal(validateHelloAck(seen[0].payload).compatible, true);
    assert.deepEqual(validateLayout(seen[1].payload).errors, []);
    const ip = new SnapshotInterpolator();
    seen.filter((m) => m.type === 'presence').forEach((m, k) => {
      const v = validatePresence(m.payload);
      assert.deepEqual(v.errors, []);
      assert.notEqual(ip.ingest(v.t, v.residents, 1000 + 250 * k), null, `presence ${k}`);
    });
    assert.equal(ip.size, 10);
    // The page had nothing to complain about: its only message is the hello.
    assert.deepEqual(d.host.received.map((m) => m.type), ['hello']);
  });

  test('defaults: delivery in a microtask and a 250 ms setInterval that stop() clears', async (t) => {
    t.mock.timers.enable({ apis: ['setInterval'] });
    const settle = () => new Promise((resolve) => setImmediate(resolve));
    const host = D.createDemoHost();
    const seen = [];
    host.onmessage = (event) => seen.push(JSON.parse(event.data).type);
    try {
      host.postMessage(JSON.stringify({ v: 1, type: 'hello', ts: 1, payload: {} }));
      assert.deepEqual(seen, []);
      await settle();
      assert.deepEqual(seen, ['hello-ack', 'layout', 'presence']);
      for (let i = 0; i < 4; i++) t.mock.timers.tick(250);
      await settle();
      assert.equal(seen.length, 7);
      t.mock.timers.tick(249);
      await settle();
      assert.equal(seen.length, 7);
    } finally {
      host.stop();
    }
    t.mock.timers.tick(1000);
    await settle();
    assert.deepEqual(seen, ['hello-ack', 'layout', 'presence', 'presence', 'presence', 'presence', 'presence']);
  });
});
