// Snapshot interpolation for residents (PROTOCOL.md section 7). Pure module: no DOM, no three.js.
// Snapshots are stamped with the page's receive time; the scene is drawn at now - delay.
// Positions stay in plot-local metres; the caller maps them to street coordinates.
// Written for this package; the technique (buffered entity interpolation) is credited in CREDITS.md.

export const DELAY_MIN_MS = 300;
export const DELAY_MAX_MS = 750;
export const DELAY_FACTOR = 1.5;
export const DEFAULT_INTERVAL_MS = 250;
export const EXTRAPOLATE_MAX_MS = 250;
export const TELEPORT_DISTANCE = 8;
export const INTERVAL_WINDOW = 7;
export const SNAPSHOTS_KEPT = 6;
const EPS = 1e-4;

export function median(values) {
  if (!values.length) return NaN;
  const s = [...values].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

// delay = 1.5 x median of the recent snapshot intervals, clamped to 300..750 ms.
export function interpolationDelay(intervals) {
  const med = intervals.length ? median(intervals) : DEFAULT_INTERVAL_MS;
  return Math.min(DELAY_MAX_MS, Math.max(DELAY_MIN_MS, DELAY_FACTOR * med));
}

function sameState(a, b) {
  return a.spaceId === b.spaceId && a.motion === b.motion &&
    Math.abs(a.x - b.x) < EPS && Math.abs(a.y - b.y) < EPS && Math.abs(a.z - b.z) < EPS;
}

function isStatic(snaps) {
  const last = snaps[snaps.length - 1];
  return snaps.every((s) => sameState(s, last));
}

function hold(s, settled) {
  return { x: s.x, y: s.y, z: s.z, vx: 0, vy: 0, vz: 0, spaceId: s.spaceId, motion: s.motion, settled };
}

export class SnapshotInterpolator {
  constructor() {
    this.tracks = new Map();
    this.intervals = [];
    this.lastRecv = null;
    this.maxT = -Infinity;
  }

  get delay() { return interpolationDelay(this.intervals); }
  get size() { return this.tracks.size; }
  ids() { return [...this.tracks.keys()]; }
  meta(id) { return this.tracks.get(id)?.meta ?? null; }
  metas() { return [...this.tracks.values()].map((tr) => tr.meta); }

  // One validated presence message. Returns null when t is not newer than every t seen so far
  // (the whole message is dropped), otherwise { added, removed, changed, metaChanged }.
  ingest(t, residents, recvMs) {
    if (!(t > this.maxT)) return null;
    this.maxT = t;
    if (this.lastRecv !== null) {
      const gap = recvMs - this.lastRecv;
      if (gap > 0) {
        this.intervals.push(gap);
        if (this.intervals.length > INTERVAL_WINDOW) this.intervals.shift();
      }
    }
    this.lastRecv = recvMs;
    const added = [];
    const removed = [];
    const metaChanged = [];
    const seen = new Set();
    let changed = false;
    for (const r of residents) {
      seen.add(r.residentId);
      let tr = this.tracks.get(r.residentId);
      if (!tr) {
        tr = { id: r.residentId, snaps: [], meta: null, reset: false };
        this.tracks.set(r.residentId, tr);
        added.push(r.residentId);
      }
      const snap = { recv: recvMs, x: r.x, y: r.y, z: r.z, spaceId: r.spaceId, motion: r.motion, jump: false };
      const prev = tr.snaps[tr.snaps.length - 1];
      if (!prev || tr.reset) {
        tr.snaps = [snap];
        tr.reset = false;
        changed = true;
      } else {
        const d = Math.hypot(snap.x - prev.x, snap.y - prev.y, snap.z - prev.z);
        snap.jump = prev.spaceId !== snap.spaceId || d > TELEPORT_DISTANCE;
        if (!sameState(prev, snap)) changed = true;
        tr.snaps.push(snap);
        if (tr.snaps.length > SNAPSHOTS_KEPT) tr.snaps.shift();
      }
      const old = tr.meta;
      tr.meta = { residentId: r.residentId, spaceId: r.spaceId, role: r.role, label: r.label, updatedAtMs: r.updatedAtMs };
      if (old && (old.role !== r.role || old.label !== r.label)) metaChanged.push(r.residentId);
    }
    for (const id of [...this.tracks.keys()]) {
      if (!seen.has(id)) { this.tracks.delete(id); removed.push(id); }
    }
    if (added.length || removed.length || metaChanged.length) changed = true;
    return { added, removed, changed, metaChanged };
  }

  // pause: forget the timing history and freeze everyone where they are now;
  // after resume the first snapshot of each resident lands directly (no interpolation across the pause).
  clear(nowMs) {
    for (const tr of this.tracks.values()) {
      const s = this.sample(tr.id, nowMs);
      tr.snaps = s ? [{ recv: -Infinity, x: s.x, y: s.y, z: s.z, spaceId: s.spaceId, motion: s.motion, jump: false }] : [];
      tr.reset = true;
    }
    this.intervals = [];
    this.lastRecv = null;
  }

  // State at render time nowMs - delay: { x, y, z, vx, vy, vz (m/s), spaceId, motion, settled }.
  // settled means the state will not change again until new data arrives.
  sample(id, nowMs) {
    const tr = this.tracks.get(id);
    if (!tr || tr.snaps.length === 0) return null;
    const snaps = tr.snaps;
    const rt = nowMs - this.delay;
    const last = snaps[snaps.length - 1];
    if (rt >= last.recv) {
      // Extrapolate along the last velocity for at most EXTRAPOLATE_MAX_MS, then stop in place.
      const prev = snaps.length > 1 ? snaps[snaps.length - 2] : null;
      let vx = 0; let vy = 0; let vz = 0;
      if (prev && !last.jump && last.recv > prev.recv) {
        const dt = (last.recv - prev.recv) / 1000;
        vx = (last.x - prev.x) / dt; vy = (last.y - prev.y) / dt; vz = (last.z - prev.z) / dt;
      }
      const moving = Math.abs(vx) + Math.abs(vy) + Math.abs(vz) > EPS;
      const ahead = Math.min(rt - last.recv, EXTRAPOLATE_MAX_MS);
      const stopped = !moving || ahead >= EXTRAPOLATE_MAX_MS;
      const k = ahead / 1000;
      return {
        x: last.x + vx * k, y: last.y + vy * k, z: last.z + vz * k,
        vx: stopped ? 0 : vx, vy: stopped ? 0 : vy, vz: stopped ? 0 : vz,
        spaceId: last.spaceId, motion: last.motion, settled: stopped,
      };
    }
    if (rt <= snaps[0].recv) return hold(snaps[0], isStatic(snaps));
    let i = 0;
    while (i < snaps.length - 2 && snaps[i + 1].recv <= rt) i++;
    const a = snaps[i];
    const b = snaps[i + 1];
    if (b.jump) return hold(a, false);
    const span = b.recv - a.recv;
    const k = span > 0 ? (rt - a.recv) / span : 1;
    const dt = span / 1000;
    const vx = dt > 0 ? (b.x - a.x) / dt : 0;
    const vy = dt > 0 ? (b.y - a.y) / dt : 0;
    const vz = dt > 0 ? (b.z - a.z) / dt : 0;
    return {
      x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k, z: a.z + (b.z - a.z) * k,
      vx, vy, vz, spaceId: a.spaceId, motion: a.motion, settled: isStatic(snaps),
    };
  }

  // True when the sample of every listed resident at nowMs is settled (unknown ids count as
  // settled): drawing again before new data arrives would show the same picture.
  settledAt(ids, nowMs) {
    for (const id of ids) {
      const s = this.sample(id, nowMs);
      if (s && !s.settled) return false;
    }
    return true;
  }
}
