// node --test for web/src/interp.js, checked against PROTOCOL.md section 7 (and the presence and pause rules of section 5).
import { describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import * as I from '../web/src/interp.js';

const { SnapshotInterpolator, interpolationDelay, median } = I;
const SPEC = readFileSync(new URL('../PROTOCOL.md', import.meta.url), 'utf8');
const section = (n) => SPEC.split(/^## /m).find((part) => part.startsWith(`${n}.`)) ?? '';

// A validated resident, shaped like the entries that protocol.js validatePresence returns.
const res = (residentId, x, z, extra = {}) => ({ residentId, spaceId: 'home', x, y: 0, z, motion: 'walk', role: 'other', label: null, updatedAtMs: null, ...extra });

// Numbers within 1e-9, everything else strictly equal.
function near(actual, expected, msg = '') {
  assert.ok(actual, `${msg}: no sample`);
  for (const [k, v] of Object.entries(expected)) {
    if (typeof v === 'number') assert.ok(Math.abs(actual[k] - v) < 1e-9, `${msg} ${k} is ${actual[k]}, expected ${v}`);
    else assert.equal(actual[k], v, `${msg} ${k}`);
  }
}

// Three snapshots 250 ms apart (delay 375 ms): idle at (0, 0), then walking to (1, 0) and (2, -1).
function threeSnapshots() {
  const ip = new SnapshotInterpolator();
  ip.ingest(1, [res('a', 0, 0, { motion: 'idle' })], 1000);
  ip.ingest(2, [res('a', 1, 0)], 1250);
  ip.ingest(3, [res('a', 2, -1)], 1500);
  assert.equal(ip.delay, 375);
  return ip;
}

describe('interp.js agrees with PROTOCOL.md section 7', () => {
  test('delay, extrapolation and teleport constants are the section 7 numbers', () => {
    const s7 = section(7);
    assert.match(s7, /delay = 1\.5 /);
    assert.match(s7, /300\D{1,6}750 ms/);
    assert.match(s7, /250 ms/);
    assert.match(s7, /\b8 m\b/);
    assert.deepEqual([I.DELAY_FACTOR, I.DELAY_MIN_MS, I.DELAY_MAX_MS, I.EXTRAPOLATE_MAX_MS, I.TELEPORT_DISTANCE], [1.5, 300, 750, 250, 8]);
  });

  test('the 5 Hz and 2 Hz examples give the stated delays', () => {
    const pairs = [...section(7).matchAll(/(\d+) Hz\D{1,4}?(\d+) ms/g)].map((m) => [Number(m[1]), Number(m[2])]);
    assert.deepEqual(pairs, [[5, 300], [2, 750]]);
    for (const [hz, ms] of pairs) assert.equal(interpolationDelay(Array(5).fill(1000 / hz)), ms, `${hz} Hz`);
  });
});

describe('median and interpolationDelay', () => {
  test('median sorts numerically and does not touch its input', () => {
    assert.ok(Number.isNaN(median([])));
    assert.equal(median([5]), 5);
    assert.equal(median([3, 1, 2]), 2);
    assert.equal(median([4, 1, 3, 2]), 2.5);
    assert.equal(median([10, 9, 2]), 9);
    const v = [3, 1, 2];
    median(v);
    assert.deepEqual(v, [3, 1, 2]);
  });

  test('interpolationDelay is 1.5 x the median, clamped to 300-750 ms', () => {
    assert.equal(I.DEFAULT_INTERVAL_MS, 250);
    assert.equal(interpolationDelay([]), 375);
    assert.equal(interpolationDelay([250]), 375);
    assert.equal(interpolationDelay([400, 300]), 525);
    assert.equal(interpolationDelay([100, 100]), 300);
    assert.equal(interpolationDelay([1000]), 750);
    assert.equal(interpolationDelay([200, 200, 5000]), 300); // one late snapshot does not move the median
  });
});

describe('SnapshotInterpolator.ingest (PROTOCOL.md section 5, presence)', () => {
  test('t must grow: a repeated or older t drops the whole message (latest wins)', () => {
    const ip = new SnapshotInterpolator();
    assert.equal(ip.size, 0);
    assert.deepEqual(ip.ingest(100, [res('a', 0, 0), res('b', 1, 1)], 1000), { added: ['a', 'b'], removed: [], changed: true, metaChanged: [] });
    assert.equal(ip.ingest(100, [res('a', 5, 5)], 1200), null);
    assert.equal(ip.ingest(99, [], 1200), null);
    assert.equal(ip.ingest(NaN, [], 1200), null);
    assert.equal(ip.ingest(undefined, [], 1200), null);
    assert.deepEqual(ip.ids(), ['a', 'b']);
    near(ip.sample('a', 5000), { x: 0, z: 0 });
    // The dropped messages did not count as receive times either: the next interval is 400 ms.
    ip.ingest(101, [res('a', 0, 0), res('b', 1, 1)], 1400);
    assert.equal(ip.delay, 600);
  });

  test('every message is a full snapshot: residents missing from it are removed', () => {
    const ip = new SnapshotInterpolator();
    ip.ingest(1, [res('a', 0, 0), res('b', 0, 0)], 0);
    assert.deepEqual(ip.ingest(2, [res('b', 0, 0), res('c', 0, 0)], 250), { added: ['c'], removed: ['a'], changed: true, metaChanged: [] });
    assert.deepEqual(ip.ids(), ['b', 'c']);
    assert.equal(ip.sample('a', 1000), null);
    assert.equal(ip.meta('a'), null);
    assert.deepEqual(ip.ingest(3, [], 500), { added: [], removed: ['b', 'c'], changed: true, metaChanged: [] });
    assert.equal(ip.size, 0);
  });

  test('changed is false when nobody moved; metaChanged lists role and label changes', () => {
    const ip = new SnapshotInterpolator();
    const a = (x, extra) => res('a', x, 2, { role: 'friend', label: 'Ann', updatedAtMs: 5, ...extra });
    assert.deepEqual(ip.ingest(1, [a(1)], 0), { added: ['a'], removed: [], changed: true, metaChanged: [] });
    assert.deepEqual(ip.ingest(2, [a(1, { updatedAtMs: 6 })], 250), { added: [], removed: [], changed: false, metaChanged: [] });
    assert.deepEqual(ip.meta('a'), { residentId: 'a', spaceId: 'home', role: 'friend', label: 'Ann', updatedAtMs: 6 });
    assert.deepEqual(ip.ingest(3, [a(1, { motion: 'sit' })], 500), { added: [], removed: [], changed: true, metaChanged: [] });
    assert.deepEqual(ip.ingest(4, [a(1, { motion: 'sit', role: 'self' })], 750), { added: [], removed: [], changed: true, metaChanged: ['a'] });
    assert.deepEqual(ip.ingest(5, [a(1, { motion: 'sit', role: 'self', label: 'Bob' })], 1000).metaChanged, ['a']);
    assert.equal(ip.ingest(6, [a(1.5, { motion: 'sit', role: 'self', label: 'Bob' })], 1250).changed, true);
    assert.equal(ip.meta('nobody'), null);
    assert.deepEqual(ip.metas(), [ip.meta('a')]);
  });

  test('the delay follows the median of the last 7 receive intervals', () => {
    const ip = new SnapshotInterpolator();
    assert.equal(ip.delay, 375);
    let t = 0;
    let recv = 1000;
    const feed = (gap) => {
      recv += gap;
      assert.notEqual(ip.ingest(++t, [res('a', 0, 0)], recv), null);
    };
    feed(0);
    assert.equal(ip.delay, 375); // one message, no interval yet
    feed(0);
    assert.equal(ip.delay, 375); // a zero gap is not an interval
    for (let i = 0; i < 7; i++) feed(500);
    assert.equal(ip.delay, 750); // 2 Hz
    for (let i = 0; i < 3; i++) feed(200);
    assert.equal(ip.delay, 750); // window [500 x4, 200 x3]: median 500
    feed(200);
    assert.equal(ip.delay, 300); // window [500 x3, 200 x4]: median 200, i.e. 5 Hz
    feed(-100);
    assert.equal(ip.delay, 300); // a receive clock going back adds no interval
    assert.equal(I.INTERVAL_WINDOW, 7);
  });
});

describe('SnapshotInterpolator.sample (PROTOCOL.md section 7)', () => {
  test('a single snapshot is placed at once and settled', () => {
    const ip = new SnapshotInterpolator();
    ip.ingest(1, [res('a', 1, 2, { motion: 'sit' })], 1000);
    for (const now of [0, 1000, 1375, 1376, 99999]) {
      assert.deepEqual(ip.sample('a', now), { x: 1, y: 0, z: 2, vx: 0, vy: 0, vz: 0, spaceId: 'home', motion: 'sit', settled: true }, `now ${now}`);
    }
    assert.equal(ip.sample('nobody', 1000), null);
  });

  test('draws at now - delay between snapshots; motion switches at the snapshot time', () => {
    const ip = threeSnapshots();
    const first = { x: 0, y: 0, z: 0, vx: 0, vy: 0, vz: 0, spaceId: 'home', motion: 'idle', settled: false };
    assert.deepEqual(ip.sample('a', 1000), first); // render time 625: before the buffer
    assert.deepEqual(ip.sample('a', 1375), first); // render time 1000: the first snapshot
    near(ip.sample('a', 1500), { x: 0.5, z: 0, vx: 4, vz: 0, motion: 'idle', settled: false }, 'render time 1125');
    near(ip.sample('a', 1625), { x: 1, z: 0, vx: 4, vz: -4, motion: 'walk', settled: false }, 'render time 1250');
    near(ip.sample('a', 1700), { x: 1.3, z: -0.3, vx: 4, vz: -4, motion: 'walk', settled: false }, 'render time 1325');
  });

  test('without a newer snapshot it extrapolates the last velocity for at most 250 ms, then stops in place', () => {
    const ip = threeSnapshots();
    near(ip.sample('a', 1875), { x: 2, z: -1, vx: 4, vz: -4, settled: false }, 'render time 1500');
    near(ip.sample('a', 1975), { x: 2.4, z: -1.4, vx: 4, vz: -4, settled: false }, '100 ms ahead');
    const stop = { x: 3, y: 0, z: -2, vx: 0, vy: 0, vz: 0, spaceId: 'home', motion: 'walk', settled: true };
    near(ip.sample('a', 2125), stop, '250 ms ahead');
    near(ip.sample('a', 60000), stop, 'much later');
  });

  test('a step of more than 8 m or a spaceId change teleports; exactly 8 m still interpolates', () => {
    const ip = new SnapshotInterpolator();
    ip.ingest(1, [res('eight', -4, 0), res('far', 0, -4), res('moved', 0, 0)], 1000);
    const r = ip.ingest(2, [res('eight', 4, 0), res('far', 0, 4.5), res('moved', 0.5, 0, { spaceId: 'next-door' })], 1250);
    assert.deepEqual(r, { added: [], removed: [], changed: true, metaChanged: [] });
    assert.equal(ip.meta('moved').spaceId, 'next-door');
    // Render time 1125, halfway between the snapshots.
    near(ip.sample('eight', 1500), { x: 0, vx: 32, settled: false }, 'eight');
    near(ip.sample('far', 1500), { x: 0, z: -4, vx: 0, vz: 0, settled: false }, 'far');
    near(ip.sample('moved', 1500), { x: 0, vx: 0, spaceId: 'home', settled: false }, 'moved');
    // Render time 1250: the jumps have happened, without any travel in between.
    near(ip.sample('eight', 1625), { x: 4, vx: 32, settled: false }, 'eight later');
    near(ip.sample('far', 1625), { z: 4.5, vz: 0, settled: true }, 'far later');
    near(ip.sample('moved', 1625), { x: 0.5, vx: 0, spaceId: 'next-door', settled: true }, 'moved later');
  });

  test('a resident standing still is settled; only the last 6 snapshots are kept', () => {
    const ip = new SnapshotInterpolator();
    for (let i = 0; i < 8; i++) ip.ingest(i + 1, [res('still', 3, 3, { motion: 'sit' }), res('walker', i, 0)], 250 * i);
    assert.equal(ip.delay, 375);
    assert.deepEqual(ip.sample('still', 1000), { x: 3, y: 0, z: 3, vx: 0, vy: 0, vz: 0, spaceId: 'home', motion: 'sit', settled: true });
    assert.equal(ip.sample('walker', 1000).settled, false);
    // Render time 250: the snapshots at x = 0 and x = 1 are gone, so the walker holds at the oldest kept one.
    assert.equal(I.SNAPSHOTS_KEPT, 6);
    near(ip.sample('walker', 625), { x: 2, vx: 0, settled: false });
  });
});

describe('SnapshotInterpolator.clear (PROTOCOL.md section 5, pause and resume)', () => {
  test('pause freezes everyone where they are; the first snapshot after resume lands directly', () => {
    const ip = new SnapshotInterpolator();
    ip.ingest(1, [res('a', 0, 0), res('b', 5, 5)], 1000);
    ip.ingest(2, [res('a', 2, 0), res('b', 5, 5)], 1400);
    assert.equal(ip.delay, 600);
    near(ip.sample('a', 1800), { x: 1, vx: 5, settled: false }, 'render time 1200');
    ip.clear(1800);
    assert.equal(ip.delay, 375); // the timing history is forgotten
    const frozen = { x: 1, y: 0, z: 0, vx: 0, vy: 0, vz: 0, spaceId: 'home', motion: 'walk', settled: true };
    assert.deepEqual(ip.sample('a', 1800), frozen);
    assert.deepEqual(ip.sample('a', 99999), frozen);
    assert.deepEqual(ip.ids(), ['a', 'b']);
    // t keeps growing within one page session, so an old t is still dropped after the pause.
    assert.equal(ip.ingest(2, [res('a', 9, 9)], 9000), null);
    assert.deepEqual(ip.ingest(3, [res('a', 6, 0), res('c', 1, 1)], 9000), { added: ['c'], removed: ['b'], changed: true, metaChanged: [] });
    for (const now of [9000, 9375, 12000]) near(ip.sample('a', now), { x: 6, z: 0, vx: 0, settled: true }, `now ${now}`);
    assert.equal(ip.delay, 375); // no interval across the pause
    ip.ingest(4, [res('a', 7, 0), res('c', 1, 1)], 9200);
    assert.equal(ip.delay, 300);
    near(ip.sample('a', 9300), { x: 6, settled: false }, 'render time 9000');
    near(ip.sample('a', 9400), { x: 6.5, vx: 5, settled: false }, 'render time 9100');
  });
});

describe('SnapshotInterpolator.settledAt (the page draws for presence only when the picture can change)', () => {
  test('a repeated snapshot leaves an idle street settled; a move stays unsettled until it has played out', () => {
    const ip = new SnapshotInterpolator();
    const at = (t) => 500 * (t + 1); // 2 Hz from 1000 ms, so the delay is 750 ms
    const stand = (x) => [res('a', x, 0, { motion: 'idle' })];
    const unchanged = { added: [], removed: [], changed: false, metaChanged: [] };
    for (let t = 1; t <= 8; t += 1) ip.ingest(t, stand(0), at(t));
    assert.deepEqual(ip.ingest(9, stand(0), at(9)), unchanged);
    assert.equal(ip.delay, 750);
    assert.equal(ip.settledAt(['a'], at(9)), true);
    assert.equal(ip.settledAt(['a', 'nobody'], at(9)), true, 'unknown ids count as settled');
    assert.equal(ip.settledAt([], at(9)), true);
    assert.equal(ip.ingest(10, stand(1), at(10)).changed, true);
    assert.equal(ip.settledAt(['a'], at(10)), false);
    // The next message repeats the new position, so nothing changed, but at render time the resident is still on the way.
    assert.deepEqual(ip.ingest(11, stand(1), at(11)), unchanged);
    near(ip.sample('a', at(11)), { x: 0.5, settled: false }, 'render time 5250');
    assert.equal(ip.settledAt(new Map([['a', null]]).keys(), at(11)), false, 'accepts any iterable, such as Map keys');
    for (let t = 12; t <= 15; t += 1) ip.ingest(t, stand(1), at(t));
    assert.equal(ip.settledAt(['a'], at(15)), true, 'every kept snapshot is at the new position');
  });
});
