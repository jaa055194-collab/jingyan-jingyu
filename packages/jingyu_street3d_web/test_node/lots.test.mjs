// node --test for web/src/lots.js, checked against PROTOCOL.md sections 5-7.
import { describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import * as L from '../web/src/lots.js';
import { MAX_RESIDENTS, SLOT_COUNT, validateLayout } from '../web/src/protocol.js';

const SPEC = readFileSync(new URL('../PROTOCOL.md', import.meta.url), 'utf8');
// A numbered section of PROTOCOL.md with typographic minus signs, <= and no-break spaces made plain.
const section = (n) => (SPEC.split(/^## /m).find((part) => part.startsWith(`${n}.`)) ?? '')
  .replace(/[\u2010-\u2013\u2212\uff0d]/g, '-').replace(/\u2264/g, '<=').replace(/\u00a0/g, ' ');
const ticks = (line) => line.split('`').filter((_, i) => i % 2 === 1);
const SLOTS = Array.from({ length: SLOT_COUNT }, (_, i) => i);

// Compares the listed keys numerically, so that -0 and rounding noise do not matter.
function near(actual, expected, msg) {
  for (const k of Object.keys(expected)) {
    assert.ok(Math.abs(actual[k] - expected[k]) < 1e-9, `${msg}: ${k} is ${actual[k]}, expected ${expected[k]}`);
  }
}

describe('lots.js: plots (PROTOCOL.md section 6)', () => {
  test('constants are the section 6 numbers', () => {
    const s6 = section(6);
    for (const re of [/14\s*m\s*\S\s*14\s*m/, /\[-7,\s*7\]/, /\(0,\s*0,\s*-7\)/, /\[-4\.5,\s*4\.5\]/, /\[0\.5,\s*6\.5\]/, /\(0,\s*0,\s*0\.5\)/,
      /\(16c,\s*0,\s*12s\)/, /\|Z\|\s*=\s*5/, /\|z\|\s*<=\s*3\.5/, /3\.5\s*<\s*\|z\|\s*<=\s*5/,
      /X\s*=\s*16c\s*\+\s*x/, /Z\s*=\s*12\s*\+\s*z/, /X\s*=\s*16c\s*-\s*x/, /Z\s*=\s*-12\s*-\s*z/]) {
      assert.match(s6, re);
    }
    assert.deepEqual([L.PLOT_SIZE, L.PLOT_HALF, L.COLUMN_SPACING, L.PLOT_OFFSET, L.COLUMN_COUNT, L.LANE_HALF, L.SIDEWALK_OUTER], [14, 7, 16, 12, 6, 3.5, 5]);
    assert.deepEqual(L.VILLA_BOX, { xMin: -4.5, xMax: 4.5, zMin: 0.5, zMax: 6.5 });
    assert.deepEqual(L.GATE, { x: 0, z: -7 });
    assert.deepEqual(L.DOOR, { x: 0, z: 0.5 });
    assert.ok(Object.isFrozen(L.VILLA_BOX) && Object.isFrozen(L.GATE) && Object.isFrozen(L.DOOR));
    // Neighbouring plots leave a gap, and the plot edge is the outer edge of the sidewalk.
    assert.ok(L.COLUMN_SPACING > L.PLOT_SIZE);
    assert.equal(L.PLOT_OFFSET - L.PLOT_HALF, L.SIDEWALK_OUTER);
  });

  test('plotOf: column floor(slot / 2); even slots on side +1 (theta 0), odd slots on side -1 (theta pi)', () => {
    for (const slot of SLOTS) {
      const column = Math.floor(slot / 2);
      const side = slot % 2 === 0 ? 1 : -1;
      assert.deepEqual(L.plotOf(slot), { slot, column, side, x: 16 * column, z: 12 * side, theta: side === 1 ? 0 : Math.PI });
    }
    assert.deepEqual(L.plotOf(11), { slot: 11, column: 5, side: -1, x: 80, z: -12, theta: Math.PI });
  });

  test('localToStreet uses the section 6 formulas, which equal a rotation by theta about +y', () => {
    const points = [[0, 0, 0], [1.5, 0.25, -3], [-7, 0, 7], [7, 2, -7], [-4.5, 0, 6.5]];
    for (const slot of SLOTS) {
      const c = Math.floor(slot / 2);
      const { x: ox, z: oz, theta } = L.plotOf(slot);
      for (const [x, y, z] of points) {
        const at = `slot ${slot} (${x}, ${y}, ${z})`;
        const got = L.localToStreet(slot, x, y, z);
        near(got, slot % 2 === 0 ? { x: 16 * c + x, y, z: 12 + z } : { x: 16 * c - x, y, z: -12 - z }, at);
        near(got, { x: ox + x * Math.cos(theta) + z * Math.sin(theta), y, z: oz - x * Math.sin(theta) + z * Math.cos(theta) }, `${at} rotation`);
        near(L.streetToLocal(slot, got.x, got.y, got.z), { x, y, z }, `${at} round trip`);
      }
    }
  });

  test('the gate is on the sidewalk edge, local +z leads away from the street and the door faces it', () => {
    for (const slot of SLOTS) {
      const gate = L.localToStreet(slot, L.GATE.x, 0, L.GATE.z);
      const door = L.localToStreet(slot, L.DOOR.x, 0, L.DOOR.z);
      const back = L.localToStreet(slot, 0, 0, L.PLOT_HALF);
      assert.equal(Math.abs(gate.z), L.SIDEWALK_OUTER, `slot ${slot} gate`);
      assert.ok(Math.abs(gate.z) < Math.abs(door.z) && Math.abs(door.z) < Math.abs(back.z), `slot ${slot}: +z leads away from the street`);
      const facing = L.localDirToStreet(slot, 0, -1);
      assert.equal(Math.sign(facing.z), -Math.sign(door.z), `slot ${slot}: the door faces the street`);
      for (const p of [L.localToStreet(slot, L.VILLA_BOX.xMin, 0, L.VILLA_BOX.zMin), L.localToStreet(slot, L.VILLA_BOX.xMax, 0, L.VILLA_BOX.zMax)]) {
        assert.ok(Math.abs(p.z) >= 12.5 && Math.abs(p.z) <= 18.5, `slot ${slot}: the villa is in the back half`);
      }
    }
  });

  test('localDirToStreet turns a local velocity the way localToStreet turns positions', () => {
    for (const slot of SLOTS) {
      const a = L.localToStreet(slot, 1, 0, 2);
      const b = L.localToStreet(slot, 1.6, 0, 1.2);
      near(L.localDirToStreet(slot, 0.6, -0.8), { x: b.x - a.x, z: b.z - a.z }, `slot ${slot}`);
    }
  });

  test('clampToPlot pulls positions back into [-7, 7] and says so', () => {
    assert.deepEqual(L.clampToPlot(1, -2), { x: 1, z: -2, clamped: false });
    assert.deepEqual(L.clampToPlot(7, -7), { x: 7, z: -7, clamped: false });
    assert.deepEqual(L.clampToPlot(7.5, 0), { x: 7, z: 0, clamped: true });
    assert.deepEqual(L.clampToPlot(-100, 100), { x: -7, z: 7, clamped: true });
    assert.deepEqual(L.clampToPlot(0, -7.01), { x: 0, z: -7, clamped: true });
  });
});

describe('lots.js: assignSlots (PROTOCOL.md section 5, layout slot)', () => {
  test('a missing slot uses the array index; a later space on a taken slot moves to the next free one', () => {
    const line = section(5).split(/\r?\n/).find((l) => l.includes('`slot?`')) ?? '';
    assert.match(line, /0.*11/);
    const m = L.assignSlots([
      { spaceId: 'a', slot: 3, index: 0 },
      { spaceId: 'b', slot: null, index: 1 },
      { spaceId: 'c', slot: 3, index: 2 },
      { spaceId: 'd', slot: 4, index: 3 },
      { spaceId: 'e', slot: 11, index: 4 },
      { spaceId: 'f', slot: 11, index: 5 },
    ]);
    assert.ok(m instanceof Map);
    assert.deepEqual([...m], [['a', 3], ['b', 1], ['c', 4], ['d', 5], ['e', 11], ['f', 0]]);
    assert.equal(L.assignSlots([]).size, 0);
  });

  test('twelve spaces that all ask for slot 5 fill all twelve slots in order (via validateLayout)', () => {
    const { spaces, errors } = validateLayout({ spaces: SLOTS.map((i) => ({ spaceId: `s${i}`, version: 1, style: 'modern', rooms: [], slot: 5 })) });
    assert.deepEqual(errors, []);
    assert.deepEqual([...L.assignSlots(spaces).values()], [5, 6, 7, 8, 9, 10, 11, 0, 1, 2, 3, 4]);
    const byIndex = validateLayout({ spaces: [{ spaceId: 'p', version: 1, slot: 1 }, { spaceId: 'q', version: 1 }, { spaceId: 'r', version: 1, slot: 99 }] });
    assert.equal(byIndex.errors.length, 1);
    assert.deepEqual([...L.assignSlots(byIndex.spaces)], [['p', 1], ['q', 2], ['r', 3]]);
  });

  test('bad slots and indexes fall back; a space with no free slot is left out', () => {
    assert.deepEqual([...L.assignSlots([{ spaceId: 'x', slot: 12, index: 2 }, { spaceId: 'y', slot: 1.5, index: -1 }, { spaceId: 'z', index: 14 }])],
      [['x', 2], ['y', 0], ['z', 3]]);
    const m = L.assignSlots(Array.from({ length: 13 }, (_, i) => ({ spaceId: `s${i}`, slot: null, index: i })));
    assert.equal(m.size, 12);
    assert.equal(m.has('s12'), false);
  });
});

describe('lots.js: streetBounds', () => {
  test('frames the occupied columns, at least two of them', () => {
    const z = { minZ: -19, maxZ: 19 };
    assert.deepEqual(L.streetBounds([]), { minX: -7, maxX: 23, ...z });
    assert.deepEqual(L.streetBounds([0]), { minX: -7, maxX: 23, ...z });
    assert.deepEqual(L.streetBounds([1, 0]), { minX: -7, maxX: 23, ...z });
    assert.deepEqual(L.streetBounds([4, 9]), { minX: 25, maxX: 71, ...z });
    assert.deepEqual(L.streetBounds([10]), { minX: 57, maxX: 87, ...z });
    assert.deepEqual(L.streetBounds([11, 0]), { minX: -7, maxX: 87, ...z });
    assert.deepEqual(L.streetBounds(new Map([['a', 6], ['b', 7]]).values()), { minX: 41, maxX: 71, ...z });
  });

  test('contains every corner of every occupied plot', () => {
    for (const slots of [[0], [3, 8], [11], SLOTS]) {
      const b = L.streetBounds(slots);
      for (const slot of slots) {
        for (const [x, z] of [[-7, -7], [7, 7], [-7, 7], [7, -7]]) {
          const p = L.localToStreet(slot, x, 0, z);
          assert.ok(p.x >= b.minX && p.x <= b.maxX && p.z >= b.minZ && p.z <= b.maxZ, `slot ${slot} corner (${x}, ${z})`);
        }
      }
    }
  });
});

describe('lots.js: on-screen resident limit (PROTOCOL.md section 7)', () => {
  const r = (residentId, extra = {}) => ({ residentId, spaceId: 'home', role: 'other', updatedAtMs: null, ...extra });

  test('the spec lists the priority self, own_ai, ..., updatedAt, residentId', () => {
    const line = section(7).split(/\r?\n/).find((l) => l.includes('`maxResidents`') && l.includes('`own_ai`')) ?? '';
    assert.deepEqual(ticks(line).filter((t) => ['self', 'own_ai', 'updatedAt', 'residentId'].includes(t)), ['self', 'own_ai', 'updatedAt', 'residentId']);
  });

  test('compareResidents: self, own_ai, the focused villa, newer updatedAt, then residentId', () => {
    const list = [
      r('z-old', { updatedAtMs: 1 }), r('b-none'), r('a-none'), r('y-new', { updatedAtMs: 5 }), r('focus', { spaceId: 'v2' }),
      r('ai', { role: 'own_ai', updatedAtMs: 0 }), r('me', { role: 'self', spaceId: 'elsewhere' }), r('friend', { role: 'friend', updatedAtMs: 3 }),
    ];
    const order = (focus) => [...list].sort((a, b) => L.compareResidents(a, b, focus)).map((x) => x.residentId);
    assert.deepEqual(order('v2'), ['me', 'ai', 'focus', 'y-new', 'friend', 'z-old', 'a-none', 'b-none']);
    assert.deepEqual(order(undefined), ['me', 'ai', 'y-new', 'friend', 'z-old', 'a-none', 'b-none', 'focus']);
    assert.ok(L.compareResidents(r('B'), r('a')) < 0); // code-unit order, which is ASCII order for these ids
    assert.equal(L.compareResidents(r('x'), r('x')), 0);
  });

  test('selectResidents keeps the top maxResidents placed residents; the rest are culled or unplaced', () => {
    const residents = [r('r1', { updatedAtMs: 10 }), r('lost', { spaceId: 'gone', role: 'self' }), r('r2', { updatedAtMs: 20 }), r('r3'), r('me', { role: 'self' })];
    const before = residents.map((x) => x.residentId);
    assert.deepEqual(L.selectResidents(residents, { maxResidents: 2, isPlaced: (id) => id !== 'gone' }),
      { shown: ['me', 'r2'], culled: ['r1', 'r3'], unplaced: ['lost'] });
    assert.deepEqual(residents.map((x) => x.residentId), before);
    assert.deepEqual(L.selectResidents([r('a'), r('b'), r('c', { spaceId: 'v' })], { maxResidents: 1, focusSpaceId: 'v' }),
      { shown: ['c'], culled: ['a', 'b'], unplaced: [] });
    assert.deepEqual(L.selectResidents([]), { shown: [], culled: [], unplaced: [] });
  });

  test('the default limit is maxResidents 8', () => {
    const out = L.selectResidents(Array.from({ length: 10 }, (_, i) => r(`r${i}`)));
    assert.equal(MAX_RESIDENTS, 8);
    assert.deepEqual(out.shown, ['r0', 'r1', 'r2', 'r3', 'r4', 'r5', 'r6', 'r7']);
    assert.deepEqual(out.culled, ['r8', 'r9']);
    assert.deepEqual(out.unplaced, []);
  });
});
