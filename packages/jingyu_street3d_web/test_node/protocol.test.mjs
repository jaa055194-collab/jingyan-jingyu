// node --test for web/src/protocol.js, checked against PROTOCOL.md (bridge protocol v1.0).
import { describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import * as P from '../web/src/protocol.js';

const SPEC = readFileSync(new URL('../PROTOCOL.md', import.meta.url), 'utf8');
const YES = '\u662f'; // "yes" in the fatal column of the error.code table
const NO = '\u5426'; // "no"

// Text of the numbered section "## n." of PROTOCOL.md.
function section(n) {
  const s = SPEC.split(/^## /m).find((part) => part.startsWith(`${n}.`));
  assert.ok(s, `PROTOCOL.md has section ${n}`);
  return s;
}
const lineWith = (text, needle) => text.split(/\r?\n/).find((l) => l.includes(needle)) ?? '';
// Markdown code spans of a line, without surrounding double quotes.
const ticks = (line) => line.split('`').filter((_, i) => i % 2 === 1).map((s) => s.replace(/^"(.*)"$/, '$1'));
// The section 8 example envelopes, keyed by type.
function examples() {
  const block = /```json\r?\n([\s\S]*?)```/.exec(section(8));
  assert.ok(block, 'section 8 has a json block');
  return Object.fromEntries(block[1].split(/\r?\n/).filter((l) => l.trim()).map((l) => {
    const e = JSON.parse(l);
    return [e.type, e];
  }));
}

describe('protocol.js agrees with PROTOCOL.md', () => {
  test('error codes and the fatal column of the error.code table (section 4)', () => {
    const s4 = section(4);
    const at = s4.indexOf('| error.code |');
    assert.ok(at >= 0);
    const rows = [...s4.slice(at).matchAll(/^\| `([a-z_]+)` \| ([^|]+?) \|/gm)].map((m) => [m[1], m[2].trim()]);
    assert.deepEqual(rows.map(([code]) => code), [...P.ERROR_CODES]);
    for (const [code, col] of rows) {
      assert.equal(P.errorPayload(code, 'x').fatal, col === YES, `${code}: default fatal flag`);
      if (col !== YES && col !== NO) assert.equal(P.errorPayload(code, 'x', { fatal: true }).fatal, true, `${code}: may be fatal`);
    }
    assert.deepEqual(rows.filter(([, col]) => col === YES).map(([code]) => code), ['protocol_mismatch', 'webgl_unavailable']);
  });

  test('message types: section 4 rows are the page types, section 5 headings the host types', () => {
    const s4 = section(4);
    const pageRows = s4.slice(0, s4.indexOf('| error.code |'));
    assert.deepEqual([...pageRows.matchAll(/^\| `([a-z-]+)` \|/gm)].map((m) => m[1]), [...P.PAGE_TYPES]);
    const hostTypes = [...section(5).matchAll(/^### (.*)$/gm)].flatMap((m) => ticks(m[1]));
    assert.deepEqual(hostTypes, [...P.HOST_TYPES]);
  });

  test('limits, id pattern, size limit and enumerations', () => {
    const hello = examples().hello.payload;
    assert.deepEqual(hello.limits, { maxSpaces: P.MAX_SPACES, maxResidents: P.MAX_RESIDENTS, maxResidentsPerMessage: P.MAX_RESIDENTS_PER_MESSAGE });
    assert.deepEqual([P.MAX_SPACES, P.SLOT_COUNT, P.MAX_RESIDENTS, P.MAX_RESIDENTS_PER_MESSAGE], [12, 12, 8, 32]);
    assert.ok(section(5).includes('`' + P.ID_RE.source + '`'), 'spaceId pattern is the one in section 5');
    assert.equal(Number(/(\d+) KiB/.exec(section(1))[1]) * 1024, P.MAX_MESSAGE_BYTES);
    const s4 = section(4);
    const s5 = section(5);
    for (const [values, line] of [
      [P.CAPS, lineWith(s4, '`caps`')],
      [P.STYLES, lineWith(s5, '- `style`')],
      [P.RELATIONS, lineWith(s5, '`relation?`')],
      [P.MOTIONS, lineWith(s5, '- `motion`')],
      [P.ROLES, lineWith(s5, '`role`')],
    ]) {
      for (const v of values) assert.ok(ticks(line).includes(v), `${v} is listed in: ${line.trim()}`);
    }
  });

  test('section 8 examples round-trip through the builders and validators', () => {
    const ex = examples();
    assert.deepEqual(P.makeEnvelope('hello', P.helloPayload({ webgl: 2 }), { ts: ex.hello.ts }), ex.hello);
    assert.deepEqual(P.makeEnvelope('tap', P.tapPayload('villa', 'demo-home-1'), { ts: ex.tap.ts }), ex.tap);
    const text = 'presence.residents[3].x is not a finite number';
    assert.deepEqual(P.makeEnvelope('error', P.errorPayload('bad_payload', text, { ref: 'p-42' }), { ts: ex.error.ts }), ex.error);

    const parsed = (e) => {
      const r = P.parseEnvelope(JSON.stringify(e));
      assert.equal(r.ok, true, e.type);
      return r.msg;
    };
    assert.deepEqual(P.validateHelloAck(parsed(ex['hello-ack']).payload),
      { major: 1, compatible: true, config: { theme: 'light', quality: 'high', maxResidents: 8, statsIntervalMs: 0 }, errors: [] });
    assert.deepEqual(P.validateLayout(parsed(ex.layout).payload), {
      spaces: [{ spaceId: 'demo-home-1', version: 3, style: 'seaside', mainColor: '#4f8fbf', slot: 0, label: ex.layout.payload.spaces[0].label, relation: 'self', roomCount: 0, index: 0 }],
      errors: [],
    });
    const presence = parsed(ex.presence);
    assert.equal(presence.id, 'p-42');
    assert.deepEqual(P.validatePresence(presence.payload), {
      t: 125000,
      residents: [{ residentId: 'demo-resident-1', spaceId: 'demo-home-1', x: -1.5, y: 0, z: -3, motion: 'walk', updatedAtMs: Date.UTC(2026, 10, 25, 8), label: null, role: 'self' }],
      errors: [],
    });
    // The example error text is exactly what validatePresence reports for a bad x at index 3.
    const residents = [0, 1, 2, 3].map((i) => ({ residentId: `r${i}`, spaceId: 's', x: i === 3 ? '1' : 0, y: 0, z: 0 }));
    assert.deepEqual(P.validatePresence({ t: 1, residents }).errors, [ex.error.payload.message]);
  });
});

describe('helpers', () => {
  test('utf8Length equals Buffer.byteLength; a lone surrogate counts 3 bytes', () => {
    for (const s of ['', 'abc', '\u00e9', '\u4e2d\u6587', '\u{1F600}', 'a\u{1F600}b', '\ud800', '\udc00x', '\ud800\ud800']) {
      assert.equal(P.utf8Length(s), Buffer.byteLength(s, 'utf8'), JSON.stringify(s));
    }
    assert.equal(P.utf8Length('\ud800'), 3);
  });

  test('clipText cuts by code points (32 by default)', () => {
    assert.equal(P.clipText('a'.repeat(40)), 'a'.repeat(32));
    assert.equal(P.clipText('\u{1F600}'.repeat(40)), '\u{1F600}'.repeat(32));
    assert.equal(P.clipText('short'), 'short');
    assert.equal(P.clipText('abcdef', 3), 'abc');
  });

  test('parseMajor reads "major.minor" or a bare number', () => {
    for (const [v, want] of [['1.0', 1], ['1', 1], [' 1.9 ', 1], ['2.3', 2], [1, 1], [1.5, 1], ['1.0.0', null], ['v1', null], ['', null], [null, null], [undefined, null], [NaN, null]]) {
      assert.equal(P.parseMajor(v), want, String(v));
    }
  });

  test('normalizeColor accepts #RRGGBB and #RGB only', () => {
    assert.equal(P.normalizeColor('#4F8FBF'), '#4f8fbf');
    assert.equal(P.normalizeColor('#AbC'), '#aabbcc');
    for (const v of ['4F8FBF', '#12345', '#1234567', '#ggg', 'red', '', null, 0x4f8fbf]) assert.equal(P.normalizeColor(v), null, String(v));
  });

  test('summarizeErrors', () => {
    assert.equal(P.summarizeErrors([]), '');
    assert.equal(P.summarizeErrors(undefined), '');
    assert.equal(P.summarizeErrors(['a']), 'a');
    assert.equal(P.summarizeErrors(['a', 'b', 'c']), 'a (+2 more)');
  });
});

describe('parseEnvelope (host -> page)', () => {
  const codeOf = (raw) => {
    const r = P.parseEnvelope(raw);
    assert.equal(r.ok, false, JSON.stringify(raw));
    return r.error.code;
  };

  test('accepts a host envelope string or an already parsed object', () => {
    assert.deepEqual(P.parseEnvelope('{"v":1,"type":"presence","id":"p-42","ts":1764057600000,"payload":{}}'),
      { ok: true, msg: { v: 1, type: 'presence', id: 'p-42', ts: 1764057600000, payload: {} } });
    assert.deepEqual(P.parseEnvelope({ v: 1, type: 'theme', payload: { mode: 'dark' } }),
      { ok: true, msg: { v: 1, type: 'theme', id: undefined, ts: undefined, payload: { mode: 'dark' } } });
  });

  test('every host type is accepted; a missing or null payload becomes {}', () => {
    for (const type of P.HOST_TYPES) {
      for (const payload of [undefined, null]) {
        const r = P.parseEnvelope(JSON.stringify({ v: 1, type, ts: 1, payload }));
        assert.equal(r.ok, true, type);
        assert.deepEqual(r.msg.payload, {});
      }
    }
  });

  test('bad_envelope: not JSON, not an object, v not 1, type missing, payload not an object', () => {
    for (const raw of ['', '{', 'not json', '[]', '"text"', '42', 'null', 'true', null, 7, []]) assert.equal(codeOf(raw), 'bad_envelope');
    for (const v of [0, 2, '1', 1.0001, null, undefined]) assert.equal(codeOf({ v, type: 'pause' }), 'bad_envelope', String(v));
    for (const type of [undefined, '', 5, null]) assert.equal(codeOf({ v: 1, type }), 'bad_envelope', String(type));
    for (const payload of [[], 'x', 3, true]) assert.equal(codeOf({ v: 1, type: 'pause', payload }), 'bad_envelope');
  });

  test('unknown_type for anything that is not a host type', () => {
    for (const type of ['nope', 'hello', 'ready', 'HELLO-ACK']) {
      const r = P.parseEnvelope({ v: 1, type, id: 'm-1' });
      assert.equal(r.ok, false);
      assert.equal(r.error.code, 'unknown_type', type);
      assert.equal(r.error.ref, 'm-1');
    }
  });

  test('error.ref echoes the id only when it is a 1-64 character string', () => {
    const refOf = (id) => P.parseEnvelope({ v: 2, type: 'pause', id }).error.ref;
    assert.equal(refOf('p-42'), 'p-42');
    assert.equal(refOf('x'.repeat(64)), 'x'.repeat(64));
    assert.equal(refOf('x'.repeat(65)), undefined);
    assert.equal(refOf(''), undefined);
    assert.equal(refOf(42), undefined);
    assert.equal(P.parseEnvelope({ v: 1, type: 'pause', id: 'x'.repeat(65) }).msg.id, undefined);
  });

  test('messages over 256 KiB of UTF-8 are rejected as bad_envelope', () => {
    const MAX = P.MAX_MESSAGE_BYTES;
    const head = '{"v":1,"type":"pause","payload":{"pad":"';
    const tail = '"}}';
    const ascii = (bytes) => head + 'a'.repeat(bytes - head.length - tail.length) + tail;
    assert.equal(Buffer.byteLength(ascii(MAX)), MAX);
    assert.equal(P.parseEnvelope(ascii(MAX)).ok, true);
    const over = P.parseEnvelope(ascii(MAX + 1));
    assert.equal(over.ok, false);
    assert.equal(over.error.code, 'bad_envelope');
    assert.match(over.error.message, /larger than 262144 bytes/);
    // 3-byte characters: under the limit in UTF-16 units, over it in UTF-8 bytes.
    const cjk = head + '\u4e2d'.repeat(Math.ceil(MAX / 3)) + tail;
    assert.ok(cjk.length < MAX && Buffer.byteLength(cjk) > MAX);
    assert.match(P.parseEnvelope(cjk).error.message, /larger than/);
  });

  test('ts is kept only when it is a finite number', () => {
    assert.equal(P.parseEnvelope({ v: 1, type: 'pause', ts: 5 }).msg.ts, 5);
    assert.equal(P.parseEnvelope({ v: 1, type: 'pause', ts: '5' }).msg.ts, undefined);
  });
});

describe('page -> host builders', () => {
  test('makeEnvelope and encodeEnvelope', () => {
    assert.deepEqual(P.makeEnvelope('ready', { restored: false, spaces: 1, residents: 0 }, { ts: 1764057600000.6, id: 'r-1' }),
      { v: 1, type: 'ready', ts: 1764057600001, payload: { restored: false, spaces: 1, residents: 0 }, id: 'r-1' });
    assert.deepEqual(P.makeEnvelope('stats', undefined, { ts: 1 }), { v: 1, type: 'stats', ts: 1, payload: {} });
    assert.equal(P.makeEnvelope('tap', {}, { ts: 1, id: 'y'.repeat(70) }).id, 'y'.repeat(64));
    assert.equal('id' in P.makeEnvelope('tap', {}, { ts: 1, id: '' }), false);
    const before = Date.now();
    const env = P.makeEnvelope('hello');
    assert.ok(Number.isInteger(env.ts) && env.ts >= before && env.ts <= Date.now());
    const s = P.encodeEnvelope('camera', P.cameraPayload('overview'), { ts: 9 });
    assert.equal(typeof s, 'string');
    assert.deepEqual(JSON.parse(s), { v: 1, type: 'camera', ts: 9, payload: { mode: 'overview' } });
  });

  test('helloPayload advertises v1.0, all caps, the limits and the renderer', () => {
    assert.deepEqual(P.helloPayload(), {
      v: '1.0',
      caps: ['tap', 'camera', 'stats', 'focus', 'theme'],
      limits: { maxSpaces: 12, maxResidents: 8, maxResidentsPerMessage: 32 },
      renderer: { three: 'r160', webgl: 2 },
    });
    assert.equal(P.helloPayload({ webgl: 1 }).renderer.webgl, 1);
    assert.equal(P.helloPayload({ webgl: 3 }).renderer.webgl, 2);
    P.helloPayload().caps.push('x');
    assert.equal(P.helloPayload().caps.length, 5);
  });

  test('readyPayload, tapPayload and cameraPayload', () => {
    assert.deepEqual(P.readyPayload(), { restored: false, spaces: 0, residents: 0 });
    assert.deepEqual(P.readyPayload({ restored: 1, spaces: 3, residents: 2 }), { restored: true, spaces: 3, residents: 2 });
    assert.deepEqual(P.tapPayload('villa', 's1', 'ignored'), { kind: 'villa', id: 's1' });
    assert.deepEqual(P.tapPayload('resident', 'r1', 's1'), { kind: 'resident', id: 'r1', spaceId: 's1' });
    assert.deepEqual(P.cameraPayload('overview', 's1'), { mode: 'overview' });
    assert.deepEqual(P.cameraPayload('villa', 's1'), { mode: 'villa', spaceId: 's1' });
  });

  test('errorPayload: always-fatal codes, message cap, ref', () => {
    assert.deepEqual(P.errorPayload('bad_payload', 'm', { ref: 'p-42' }), { code: 'bad_payload', message: 'm', fatal: false, ref: 'p-42' });
    assert.equal(P.errorPayload('protocol_mismatch', 'm', { fatal: false }).fatal, true);
    assert.equal(P.errorPayload('webgl_unavailable', 'm').fatal, true);
    assert.equal(P.errorPayload('internal', 'm', { fatal: true }).fatal, true);
    assert.equal(P.errorPayload('internal', 'x'.repeat(500)).message.length, 300);
    assert.equal(P.errorPayload('internal', undefined).message, '');
    assert.equal('ref' in P.errorPayload('internal', 'm', { ref: '' }), false);
  });

  test('statsPayload has the section 4 shape and rounds', () => {
    assert.deepEqual(P.statsPayload({ fps: 29.96, frameMs: 3.14159, calls: 12, mode: 'running', shown: 3, culled: 1, unplaced: 2 }),
      { fps: 30, frameMs: 3.14, calls: 12, mode: 'running', residents: { shown: 3, culled: 1, unplaced: 2 } });
    assert.deepEqual(P.statsPayload(), { fps: 0, frameMs: 0, calls: 0, mode: 'idle', residents: { shown: 0, culled: 0, unplaced: 0 } });
  });
});

describe('validateHelloAck', () => {
  const DEFAULTS = { theme: 'light', quality: 'high', maxResidents: 8, statsIntervalMs: 0 };

  test('the major version decides compatibility; minor upgrades stay compatible', () => {
    for (const [v, major, ok] of [['1.0', 1, true], ['1.9', 1, true], [1, 1, true], ['2.0', 2, false], ['0.9', 0, false], [undefined, null, false], ['one', null, false]]) {
      const r = P.validateHelloAck({ v });
      assert.equal(r.major, major, String(v));
      assert.equal(r.compatible, ok, String(v));
    }
  });

  test('a missing config gives the defaults', () => {
    assert.deepEqual(P.validateHelloAck({ v: '1.0' }), { major: 1, compatible: true, config: DEFAULTS, errors: [] });
    assert.deepEqual(P.validateHelloAck({ v: '1.0', config: null }).errors, []);
  });

  test('valid config values are applied; unknown fields are ignored', () => {
    const r = P.validateHelloAck({ v: '1.0', config: { theme: 'dark', quality: 'low', maxResidents: 1, statsIntervalMs: 1000, future: true } });
    assert.deepEqual(r.config, { theme: 'dark', quality: 'low', maxResidents: 1, statsIntervalMs: 1000 });
    assert.deepEqual(r.errors, []);
    assert.deepEqual(P.validateHelloAck({ v: '1.0', config: { maxResidents: 8, statsIntervalMs: 0 } }).errors, []);
  });

  test('each invalid config value falls back to its default with one error', () => {
    for (const bad of [{ theme: 'blue' }, { quality: 'ultra' }, { maxResidents: 0 }, { maxResidents: 9 }, { maxResidents: 2.5 }, { maxResidents: '4' },
      { statsIntervalMs: 999 }, { statsIntervalMs: 1500.5 }, { statsIntervalMs: -1 }]) {
      const r = P.validateHelloAck({ v: '1.0', config: bad });
      assert.deepEqual(r.config, DEFAULTS, JSON.stringify(bad));
      assert.equal(r.errors.length, 1, JSON.stringify(bad));
    }
    for (const config of ['x', 3, []]) assert.deepEqual(P.validateHelloAck({ v: '1.0', config }).errors, ['hello-ack.config is not an object']);
  });
});

describe('validateLayout', () => {
  const sp = (id, extra = {}) => ({ spaceId: id, version: 1, style: 'modern', rooms: [], ...extra });

  test('spaces must be an array', () => {
    for (const payload of [{}, { spaces: 'x' }, { spaces: {} }]) {
      assert.deepEqual(P.validateLayout(payload), { spaces: null, errors: ['layout.spaces is not an array'] });
    }
    assert.deepEqual(P.validateLayout({ spaces: [] }), { spaces: [], errors: [] });
  });

  test('at most 12 spaces: extras are dropped and reported', () => {
    const r = P.validateLayout({ spaces: Array.from({ length: 13 }, (_, i) => sp(`s${i}`)) });
    assert.equal(r.spaces.length, 12);
    assert.equal(r.spaces.at(-1).spaceId, 's11');
    assert.equal(r.errors.length, 1);
    assert.match(r.errors[0], /13 entries.*first 12/);
    assert.deepEqual(P.validateLayout({ spaces: Array.from({ length: 12 }, (_, i) => sp(`s${i}`)) }).errors, []);
  });

  test('spaceId pattern, duplicates and version', () => {
    const ok = ['a', 'A_b-9', 'x'.repeat(64)];
    const bad = [undefined, '', 'has space', 'x'.repeat(65), 'a/b', 7];
    const r = P.validateLayout({ spaces: [...ok.map((id) => sp(id)), ...bad.map((id) => sp(id))] });
    assert.deepEqual(r.spaces.map((s) => s.spaceId), ok);
    assert.equal(r.errors.length, bad.length);
    const dup = P.validateLayout({ spaces: [sp('a', { label: 'first' }), sp('a', { label: 'second' })] });
    assert.deepEqual(dup.spaces.map((s) => s.label), ['first']);
    assert.match(dup.errors[0], /repeats/);
    const versions = P.validateLayout({ spaces: [sp('v0', { version: 0 }), sp('v1', { version: -1 }), sp('v2', { version: 1.5 }), sp('v3', { version: '3' }), sp('v4', { version: undefined })] });
    assert.deepEqual(versions.spaces.map((s) => s.spaceId), ['v0']);
    assert.equal(versions.errors.length, 4);
  });

  test('slot is 0-11 or null; a bad slot is reported and treated as missing', () => {
    const r = P.validateLayout({ spaces: [sp('a', { slot: 0 }), sp('b', { slot: 11 }), sp('c'), sp('d', { slot: 12 }), sp('e', { slot: -1 }),
      sp('f', { slot: 1.5 }), sp('g', { slot: '3' }), sp('h', { slot: null })] });
    assert.deepEqual(r.spaces.map((s) => s.slot), [0, 11, null, null, null, null, null, null]);
    assert.equal(r.errors.length, 4);
    assert.deepEqual(r.spaces.map((s) => s.index), [0, 1, 2, 3, 4, 5, 6, 7]);
  });

  test('index is the position in the original array, also after drops', () => {
    assert.equal(P.validateLayout({ spaces: [sp('bad id'), sp('b')] }).spaces[0].index, 1);
  });

  test('style, mainColor, label and relation', () => {
    const r = P.validateLayout({ spaces: [
      sp('a', { style: 'chinese_courtyard', mainColor: '#ABC', label: 'L'.repeat(32), relation: 'friend' }),
      sp('b', { style: 'gothic', mainColor: 'blue', label: 'L'.repeat(33), relation: 'enemy' }),
      sp('c', { style: undefined, mainColor: undefined, label: 5 }),
    ] });
    const [a, b, c] = r.spaces;
    assert.deepEqual([a.style, a.mainColor, a.label, a.relation], ['chinese_courtyard', '#aabbcc', 'L'.repeat(32), 'friend']);
    assert.deepEqual([b.style, b.mainColor, b.label, b.relation], ['modern', null, 'L'.repeat(32), 'other']);
    assert.deepEqual([c.style, c.mainColor, c.label, c.relation], ['modern', null, null, 'other']);
    assert.equal(r.errors.length, 3); // b.label too long, b.relation invalid, c.label not a string
    for (const style of P.STYLES) assert.equal(P.validateLayout({ spaces: [sp('s', { style })] }).spaces[0].style, style);
  });

  test('rooms and furniture: only the structure is checked', () => {
    const one = (rooms) => P.validateLayout({ spaces: [sp('a', { rooms })] });
    let r = one([{ id: 'r1' }, { furniture: [{ kind: 'sofa' }] }]);
    assert.equal(r.spaces[0].roomCount, 2);
    assert.deepEqual(r.errors, []);
    r = one('x');
    assert.equal(r.spaces[0].roomCount, 0);
    assert.deepEqual(r.errors, ['layout.spaces[0].rooms is not an array']);
    r = one([1, { furniture: 'x' }]);
    assert.equal(r.spaces[0].roomCount, 1);
    assert.deepEqual(r.errors, ['layout.spaces[0].rooms[0] is not an object', 'layout.spaces[0].rooms[1].furniture is not an array']);
    assert.equal(one(undefined).spaces[0].roomCount, 0);
  });
});

describe('validatePresence', () => {
  const res = (id, extra = {}) => ({ residentId: id, spaceId: 'home', x: 1, y: 0, z: -2, motion: 'walk', ...extra });

  test('t must be a finite number and residents an array', () => {
    for (const t of [undefined, '5', null]) {
      assert.deepEqual(P.validatePresence({ t, residents: [] }), { t: null, residents: null, errors: ['presence.t is not a finite number'] });
    }
    assert.deepEqual(P.validatePresence({ t: 5, residents: {} }), { t: 5, residents: null, errors: ['presence.residents is not an array'] });
    assert.deepEqual(P.validatePresence({ t: 5, residents: [] }), { t: 5, residents: [], errors: [] });
  });

  test('at most 32 residents per message', () => {
    const r = P.validatePresence({ t: 1, residents: Array.from({ length: 33 }, (_, i) => res(`r${i}`)) });
    assert.equal(r.residents.length, 32);
    assert.equal(r.residents.at(-1).residentId, 'r31');
    assert.equal(r.errors.length, 1);
    assert.match(r.errors[0], /33 entries.*first 32/);
  });

  test('bad entries are dropped and reported, good ones kept', () => {
    const r = P.validatePresence({ t: 1, residents: [
      res('ok'), 'x', res('bad id'), res('ok'), res('s', { spaceId: 'a b' }), res('nx', { x: '1' }), res('ny', { y: null }), res('nz', { z: undefined }), res('ok2'),
    ] });
    assert.deepEqual(r.residents.map((x) => x.residentId), ['ok', 'ok2']);
    assert.deepEqual(r.errors, [
      'presence.residents[1] is not an object',
      'presence.residents[2].residentId is invalid',
      'presence.residents[3].residentId repeats an earlier resident',
      'presence.residents[4].spaceId is invalid',
      'presence.residents[5].x is not a finite number',
      'presence.residents[6].y is not a finite number',
      'presence.residents[7].z is not a finite number',
    ]);
  });

  test('motion, role, label and updatedAt', () => {
    const r = P.validatePresence({ t: 1, residents: [
      res('a', { motion: 'sit', role: 'visitor', label: 'Ann', updatedAt: '2026-11-25T08:00:00Z' }),
      res('b', { motion: 'dance', role: 'boss', label: 'L'.repeat(33), updatedAt: 'yesterday' }),
      res('c', { motion: undefined }),
    ] });
    const [a, b, c] = r.residents;
    assert.deepEqual([a.motion, a.role, a.label, a.updatedAtMs], ['sit', 'visitor', 'Ann', Date.UTC(2026, 10, 25, 8)]);
    assert.deepEqual([b.motion, b.role, b.label, b.updatedAtMs], ['idle', 'other', 'L'.repeat(32), null]);
    assert.deepEqual([c.motion, c.role, c.label, c.updatedAtMs], ['idle', 'other', null, null]);
    assert.equal(r.errors.length, 3); // b: updatedAt, label, role
    for (const motion of P.MOTIONS) assert.equal(P.validatePresence({ t: 1, residents: [res('m', { motion })] }).residents[0].motion, motion);
    assert.equal(P.validatePresence({ t: 1, residents: [res('n', { updatedAt: 1764057600000 })] }).errors.length, 1);
  });
});

describe('validateTheme and validateFocus', () => {
  test('theme', () => {
    assert.deepEqual(P.validateTheme({ mode: 'dark' }), { mode: 'dark', errors: [] });
    assert.deepEqual(P.validateTheme({ mode: 'light' }), { mode: 'light', errors: [] });
    for (const mode of [undefined, 'sepia', 1]) assert.equal(P.validateTheme({ mode }).mode, null);
  });

  test('focus', () => {
    assert.deepEqual(P.validateFocus({ kind: 'overview', id: 'ignored' }), { focus: { kind: 'overview' }, errors: [] });
    assert.deepEqual(P.validateFocus({ kind: 'villa', id: 'demo-home-1' }), { focus: { kind: 'villa', id: 'demo-home-1' }, errors: [] });
    assert.deepEqual(P.validateFocus({ kind: 'resident', id: 'demo-resident-1' }).focus, { kind: 'resident', id: 'demo-resident-1' });
    for (const p of [{ kind: 'villa' }, { kind: 'resident', id: 'a b' }, { kind: 'zoom', id: 'a' }, {}]) {
      const r = P.validateFocus(p);
      assert.equal(r.focus, null, JSON.stringify(p));
      assert.equal(r.errors.length, 1);
    }
  });
});
