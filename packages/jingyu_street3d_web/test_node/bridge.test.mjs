// node --test for web/src/bridge.js, driven through a fake transport and checked against PROTOCOL.md sections 1-3.
import { describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { Bridge, QUEUE_LIMIT, hostTransport } from '../web/src/bridge.js';
import { validateHelloAck } from '../web/src/protocol.js';

const SPEC = readFileSync(new URL('../PROTOCOL.md', import.meta.url), 'utf8');
const section = (n) => SPEC.split(/^## /m).find((part) => part.startsWith(`${n}.`)) ?? '';

const TS = 1764057600000;
const env = (type, payload, id) => ({ v: 1, type, ts: TS, ...(id === undefined ? {} : { id }), payload: payload ?? {} });
const ACK = env('hello-ack', { v: '1.0', config: {} }, 'ack');
const ids = (msgs) => msgs.map((m) => m.id);

// The fake transport is a plain { postMessage(s), onmessage } like Android's Street3DBridge;
// the bridge installs onmessage, host() plays the host side.
function harness({ onMessage, now = () => 1000 } = {}) {
  const sent = [];
  const got = [];
  const transport = { postMessage(s) { sent.push(s); }, onmessage: null };
  const bridge = new Bridge(transport, { onMessage: onMessage ?? ((m) => got.push(m)), now });
  return {
    bridge, transport, sent, got,
    posted: () => sent.map((s) => JSON.parse(s)),
    host: (obj) => transport.onmessage({ data: typeof obj === 'string' ? obj : JSON.stringify(obj) }),
  };
}

describe('Bridge: page -> host', () => {
  test('installs onmessage and posts envelopes as JSON strings stamped by the injected clock', () => {
    const h = harness();
    assert.equal(typeof h.transport.onmessage, 'function');
    assert.equal(h.bridge.send('hello', { v: '1.0' }), true);
    assert.equal(typeof h.sent[0], 'string');
    assert.deepEqual(JSON.parse(h.sent[0]), { v: 1, type: 'hello', ts: 1000, payload: { v: '1.0' } });
    assert.equal(h.bridge.send('ready', undefined, { id: 'r-1', ts: 5 }), true);
    assert.deepEqual(h.posted()[1], { v: 1, type: 'ready', ts: 5, id: 'r-1', payload: {} });
    assert.equal(h.bridge.sent, 2);
  });

  test('send returns false when the transport throws', () => {
    const transport = { postMessage() { throw new Error('bridge gone'); }, onmessage: null };
    const bridge = new Bridge(transport);
    assert.equal(bridge.send('hello', {}), false);
    assert.equal(bridge.error('internal', 'x'), false);
    assert.equal(bridge.sent, 0);
    assert.equal(bridge.dead, false);
  });

  test('error() posts an error envelope; protocol_mismatch is fatal even when asked otherwise', () => {
    const h = harness();
    h.bridge.error('bad_payload', 'm', { ref: 'p-42' });
    assert.equal(h.bridge.dead, false);
    h.bridge.error('protocol_mismatch', 'host is 2.0', { fatal: false });
    assert.equal(h.bridge.dead, true);
    assert.deepEqual(h.posted().map((e) => [e.type, e.payload]), [
      ['error', { code: 'bad_payload', message: 'm', fatal: false, ref: 'p-42' }],
      ['error', { code: 'protocol_mismatch', message: 'host is 2.0', fatal: true }],
    ]);
  });
});

describe('Bridge: host -> page around hello-ack (PROTOCOL.md 3, item 3)', () => {
  test('the spec states the same queue limit', () => {
    const item = section(3).split(/\r?\n/).slice(1).find((l) => l.startsWith('3. ')) ?? '';
    assert.ok(item.includes(` ${QUEUE_LIMIT} `), item);
    assert.ok(item.includes('`hello-ack`') && item.includes('`presence`'), item);
    assert.equal(QUEUE_LIMIT, 64);
  });

  test('reads event.data or a bare string', () => {
    const h = harness();
    h.transport.onmessage({ data: JSON.stringify(ACK) });
    h.transport.onmessage(JSON.stringify(env('theme', { mode: 'dark' })));
    assert.deepEqual(h.got.map((m) => m.type), ['hello-ack', 'theme']);
    assert.deepEqual(h.got[1], { v: 1, type: 'theme', id: undefined, ts: TS, payload: { mode: 'dark' } });
  });

  test('queues until hello-ack, then delivers hello-ack first and the queue in arrival order', () => {
    const h = harness();
    h.host(env('layout', { spaces: [] }, 'l1'));
    h.host(env('theme', { mode: 'dark' }, 't1'));
    h.host(env('pause', {}, 'pa'));
    assert.equal(h.got.length, 0);
    assert.deepEqual(ids(h.bridge.queue), ['l1', 't1', 'pa']);
    h.host(ACK);
    assert.equal(h.bridge.acked, true);
    assert.deepEqual(ids(h.got), ['ack', 'l1', 't1', 'pa']);
    assert.equal(h.bridge.queue.length, 0);
    h.host(env('resume', {}, 'r1'));
    h.host(env('hello-ack', { v: '1.0' }, 'ack-2'));
    assert.deepEqual(ids(h.got).slice(4), ['r1', 'ack-2']);
    assert.equal(h.sent.length, 0);
  });

  test('holds at most 64 messages and drops the oldest', () => {
    const h = harness();
    for (let i = 0; i < 70; i++) h.host(env('layout', { spaces: [] }, `l${i}`));
    assert.equal(h.bridge.queue.length, QUEUE_LIMIT);
    assert.equal(h.bridge.dropped, 6);
    h.host(ACK);
    assert.deepEqual(ids(h.got), ['ack', ...Array.from({ length: 64 }, (_, i) => `l${i + 6}`)]);
  });

  test('keeps only the newest queued presence', () => {
    const h = harness();
    h.host(env('presence', { t: 1, residents: [] }, 'p1'));
    h.host(env('layout', { spaces: [] }, 'l1'));
    h.host(env('presence', { t: 2, residents: [] }, 'p2'));
    h.host(env('theme', { mode: 'dark' }, 't1'));
    h.host(env('presence', { t: 3, residents: [] }, 'p3'));
    assert.deepEqual(ids(h.bridge.queue), ['l1', 't1', 'p3']);
    assert.equal(h.bridge.dropped, 2);
    h.host(ACK);
    assert.deepEqual(ids(h.got), ['ack', 'l1', 't1', 'p3']);
    assert.equal(h.got[3].payload.t, 3);
  });

  test('a presence flood takes one slot; the limit can still drop that presence as the oldest', () => {
    const h = harness();
    for (let i = 0; i < 200; i++) h.host(env('presence', { t: i, residents: [] }, `p${i}`));
    assert.deepEqual(ids(h.bridge.queue), ['p199']);
    for (let i = 0; i < 64; i++) h.host(env('layout', { spaces: [] }, `l${i}`));
    assert.equal(h.bridge.queue.length, 64);
    assert.equal(h.bridge.queue[0].id, 'l0');
    assert.equal(h.bridge.queue.some((m) => m.type === 'presence'), false);
    assert.equal(h.bridge.dropped, 200);
  });

  test('malformed messages get an immediate non-fatal error and are not queued', () => {
    const h = harness();
    h.transport.onmessage({ data: 'not json' });
    h.host({ v: 2, type: 'layout', id: 'old', payload: {} });
    h.host({ v: 1, type: 'teleport', id: 'tp' });
    h.host({ v: 1, payload: {} });
    assert.deepEqual(h.posted().map((e) => [e.type, e.ts, e.payload.code, e.payload.fatal, e.payload.ref]), [
      ['error', 1000, 'bad_envelope', false, undefined],
      ['error', 1000, 'bad_envelope', false, 'old'],
      ['error', 1000, 'unknown_type', false, 'tp'],
      ['error', 1000, 'bad_envelope', false, undefined],
    ]);
    assert.equal(h.bridge.queue.length, 0);
    assert.equal(h.bridge.received, 4);
    h.host(ACK);
    h.host({ v: 1, type: 'nope' });
    assert.deepEqual(h.got.map((m) => m.type), ['hello-ack']);
    assert.equal(h.posted().at(-1).payload.code, 'unknown_type');
  });
});

describe('Bridge: fatal errors and handler failures', () => {
  test('a fatal error clears the queue, ignores the host and lets only errors out', () => {
    const h = harness();
    h.host(env('layout', { spaces: [] }, 'l1'));
    assert.equal(h.bridge.error('webgl_unavailable', 'no WebGL'), true);
    assert.equal(h.bridge.dead, true);
    assert.equal(h.bridge.queue.length, 0);
    assert.equal(h.bridge.send('hello', {}), false); // no hello after webgl_unavailable
    const received = h.bridge.received;
    h.host(ACK);
    h.transport.onmessage({ data: 'garbage' });
    assert.equal(h.got.length, 0);
    assert.equal(h.bridge.received, received);
    assert.equal(h.bridge.send('error', { code: 'internal', message: 'late', fatal: false }), true);
    assert.deepEqual(h.posted().map((e) => e.payload.code), ['webgl_unavailable', 'internal']);
    assert.deepEqual(h.posted()[0].payload, { code: 'webgl_unavailable', message: 'no WebGL', fatal: true });
  });

  test('protocol_mismatch raised while handling hello-ack drops the queued messages', () => {
    const seen = [];
    const h = harness({
      onMessage: (m) => {
        seen.push(m.id);
        if (m.type === 'hello-ack' && !validateHelloAck(m.payload).compatible) {
          h.bridge.error('protocol_mismatch', 'host speaks 2.0', { ref: m.id });
        }
      },
    });
    h.host(env('layout', { spaces: [] }, 'l1'));
    h.host(env('presence', { t: 1, residents: [] }, 'p1'));
    h.host(env('hello-ack', { v: '2.0' }, 'ack-2'));
    h.host(env('theme', { mode: 'dark' }, 't1'));
    assert.deepEqual(seen, ['ack-2']);
    assert.equal(h.bridge.dead, true);
    assert.deepEqual(h.posted().map((e) => e.payload), [{ code: 'protocol_mismatch', message: 'host speaks 2.0', fatal: true, ref: 'ack-2' }]);
  });

  test('a throwing handler becomes a non-fatal internal error and the rest still arrives', () => {
    const seen = [];
    const h = harness({
      onMessage: (m) => {
        if (m.type === 'layout') throw new Error('boom');
        seen.push(m.type);
      },
    });
    h.host(env('layout', { spaces: [] }, 'l1'));
    h.host(env('theme', { mode: 'dark' }, 't1'));
    h.host(ACK);
    assert.deepEqual(seen, ['hello-ack', 'theme']);
    assert.equal(h.bridge.dead, false);
    assert.deepEqual(h.posted().map((e) => e.payload), [{ code: 'internal', message: 'handling layout failed: boom', fatal: false, ref: 'l1' }]);
    const h2 = harness({ onMessage: () => { throw 'plain'; } });
    h2.host(ACK);
    assert.equal(h2.posted()[0].payload.message, 'handling hello-ack failed: plain');
  });
});

describe('hostTransport', () => {
  test('returns Street3DBridge only when it has postMessage', () => {
    assert.ok(section(1).includes('`Street3DBridge`'));
    const b = { postMessage() {} };
    assert.equal(hostTransport({ Street3DBridge: b }), b);
    for (const scope of [{}, { Street3DBridge: null }, { Street3DBridge: {} }, { Street3DBridge: { postMessage: 'x' } }]) {
      assert.equal(hostTransport(scope), null);
    }
    assert.equal(hostTransport(), null);
    globalThis.Street3DBridge = b;
    try {
      assert.equal(hostTransport(), b);
    } finally {
      delete globalThis.Street3DBridge;
    }
  });
});
