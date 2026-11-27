// Synthetic host for ?demo=1 (PROTOCOL.md section 1). It has the shape of Android's Street3DBridge
// object (postMessage plus onmessage): it answers hello with hello-ack, then sends a layout and
// 4 Hz presence. Every id, name and position here is synthetic. Written for this package.
import { PROTOCOL_VERSION } from './protocol.js';

export const DEMO_HZ = 4;
export const DEMO_T0 = 100000;

export const DEMO_SPACES = Object.freeze([
  { spaceId: 'demo-home-1', version: 3, style: 'seaside', mainColor: '#4F8FBF', rooms: [], slot: 0, label: '我的别墅', relation: 'self' },
  { spaceId: 'demo-home-2', version: 1, style: 'forest', rooms: [], slot: 1, label: 'AI 的小屋', relation: 'own_ai' },
  { spaceId: 'demo-home-3', version: 2, style: 'modern', mainColor: '#E07A5F', rooms: [], slot: 2, label: '好友 阿青', relation: 'friend' },
  { spaceId: 'demo-home-4', version: 1, style: 'cyber', rooms: [], slot: 3, label: '霓虹公寓', relation: 'other' },
  { spaceId: 'demo-home-5', version: 1, style: 'chinese_courtyard', rooms: [], slot: 4, label: '青瓦小院', relation: 'friend' },
  { spaceId: 'demo-home-6', version: 1, style: 'seaside', mainColor: '#F2A541', rooms: [], slot: 5, label: '海边小筑', relation: 'other' },
  { spaceId: 'demo-home-7', version: 1, style: 'forest', mainColor: '#7A9E4F', rooms: [], slot: 6, label: '林间木屋', relation: 'other' },
  { spaceId: 'demo-home-8', version: 1, style: 'modern', rooms: [], slot: 7, label: '白色方盒', relation: 'friend' },
]);

// Paths in plot-local metres, all in the front yard (z < 0.5), about 1 m/s. loop: a circle;
// stroll: A to B, wait, back, wait; stay: a fixed point with the given motion. phase is in ms.
// demo-resident-9 has the oldest updatedAt, so with maxResidents 8 it is culled;
// demo-resident-10 lives in a space that is not on the street, so it is unplaced.
export const DEMO_RESIDENTS = Object.freeze([
  { residentId: 'demo-resident-1', spaceId: 'demo-home-1', role: 'self', label: '我', path: { kind: 'stroll', a: [-4, -5.5], b: [2.5, -1.5], period: 18000 } },
  { residentId: 'demo-resident-2', spaceId: 'demo-home-1', role: 'own_ai', label: '小鲸', path: { kind: 'loop', c: [3, -4.5], r: 1.5, period: 9500 } },
  { residentId: 'demo-resident-3', spaceId: 'demo-home-2', role: 'visitor', label: '访客', path: { kind: 'stroll', a: [-3, -2], b: [3.5, -5], period: 17000, phase: 5000 } },
  { residentId: 'demo-resident-4', spaceId: 'demo-home-3', role: 'friend', label: '阿青', path: { kind: 'stay', p: [-1.8, -2.4], motion: 'wave' } },
  { residentId: 'demo-resident-5', spaceId: 'demo-home-4', role: 'other', label: '夜猫', path: { kind: 'loop', c: [-2.5, -3.5], r: 2, period: 12500, phase: 3000 } },
  { residentId: 'demo-resident-6', spaceId: 'demo-home-5', role: 'friend', label: '小满', path: { kind: 'stay', p: [2.6, -2.2], motion: 'sit' } },
  { residentId: 'demo-resident-7', spaceId: 'demo-home-6', role: 'other', label: '阿海', path: { kind: 'stroll', a: [-4.5, -4], b: [1, -6], period: 15000, phase: 9000 } },
  { residentId: 'demo-resident-8', spaceId: 'demo-home-7', role: 'other', label: '松果', path: { kind: 'loop', c: [1.5, -3.5], r: 1.8, period: 11500, phase: 6000 } },
  { residentId: 'demo-resident-9', spaceId: 'demo-home-8', role: 'other', label: '路人', path: { kind: 'stay', p: [0, -4], motion: 'idle' } },
  { residentId: 'demo-resident-10', spaceId: 'demo-home-99', role: 'other', label: '远方', path: { kind: 'stay', p: [0, 0], motion: 'idle' } },
]);

export function pathAt(path, ms) {
  if (path.kind === 'stay') return { x: path.p[0], z: path.p[1], motion: path.motion };
  const u = ((((ms + (path.phase || 0)) % path.period) + path.period) % path.period) / path.period;
  if (path.kind === 'loop') {
    const a = u * Math.PI * 2;
    return { x: path.c[0] + Math.cos(a) * path.r, z: path.c[1] + Math.sin(a) * path.r, motion: 'walk' };
  }
  let k = 0;
  let motion = 'walk';
  if (u < 0.4) k = u / 0.4;
  else if (u < 0.5) { k = 1; motion = 'idle'; }
  else if (u < 0.9) k = 1 - (u - 0.5) / 0.4;
  else motion = 'idle';
  return { x: path.a[0] + (path.b[0] - path.a[0]) * k, z: path.a[1] + (path.b[1] - path.a[1]) * k, motion };
}

const round3 = (v) => Math.round(v * 1000) / 1000;

// ms: time since the demo started; t: the host's monotonic counter for this message.
export function presencePayload(ms, t, startWallMs) {
  return {
    t,
    residents: DEMO_RESIDENTS.map((r, i) => {
      const p = pathAt(r.path, ms);
      return {
        residentId: r.residentId, spaceId: r.spaceId,
        x: round3(p.x), y: 0, z: round3(p.z), motion: p.motion,
        updatedAt: new Date(startWallMs - i * 60000).toISOString(),
        label: r.label, role: r.role,
      };
    }),
  };
}

// The returned object stands in for Street3DBridge. host.received keeps the last 200 page
// messages (the smoke test reads it); host.send / pause / resume let tests act as the host.
export function createDemoHost({
  hz = DEMO_HZ, config = {}, now = () => performance.now(), wallNow = () => Date.now(),
  every = (fn, ms) => setInterval(fn, ms), cancel = (id) => clearInterval(id),
  deliver = (fn) => queueMicrotask(fn),
} = {}) {
  const t0 = now();
  const startWall = wallNow();
  let timer = null;
  let seq = 0;
  let lastT = 0;
  const host = {
    onmessage: null,
    received: [],
    postMessage(json) {
      let msg = null;
      try { msg = JSON.parse(json); } catch { return; }
      host.received.push(msg);
      if (host.received.length > 200) host.received.shift();
      if (msg && msg.type === 'hello') start();
    },
    send(type, payload = {}) { emit(type, payload); },
    pause() { stop(); emit('pause', {}); },
    resume() { emit('resume', {}); presence(); run(); },
    stop,
  };
  function emit(type, payload) {
    seq += 1;
    const json = JSON.stringify({ v: 1, type, id: `demo-${seq}`, ts: Math.round(wallNow()), payload });
    deliver(() => { if (typeof host.onmessage === 'function') host.onmessage({ data: json }); });
  }
  function hostT() {
    lastT = Math.max(lastT + 1, Math.round(DEMO_T0 + now() - t0));
    return lastT;
  }
  function presence() {
    const t = hostT();
    emit('presence', presencePayload(t - DEMO_T0, t, startWall));
  }
  function stop() {
    if (timer !== null) { cancel(timer); timer = null; }
  }
  function run() {
    stop();
    timer = every(presence, Math.round(1000 / hz));
  }
  function start() {
    stop();
    emit('hello-ack', { v: PROTOCOL_VERSION, config: { theme: 'light', quality: 'high', maxResidents: 8, statsIntervalMs: 0, ...config } });
    emit('layout', { spaces: DEMO_SPACES });
    presence();
    run();
  }
  return host;
}
