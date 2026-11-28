// Street layout maths (PROTOCOL.md section 6): slot -> plot transform, slot collisions,
// clamping, overview bounds and the on-screen resident limit (section 7).
// Pure module: no DOM, no three.js. Written for this package.
import { SLOT_COUNT } from './protocol.js';

export const PLOT_SIZE = 14;
export const PLOT_HALF = 7;
export const COLUMN_SPACING = 16;
export const PLOT_OFFSET = 12;
export const COLUMN_COUNT = SLOT_COUNT / 2;
export const LANE_HALF = 3.5;
export const SIDEWALK_OUTER = 5;
export const VILLA_BOX = Object.freeze({ xMin: -4.5, xMax: 4.5, zMin: 0.5, zMax: 6.5 });
export const GATE = Object.freeze({ x: 0, z: -7 });
export const DOOR = Object.freeze({ x: 0, z: 0.5 });

// Column, side and pose of a slot's plot in street coordinates.
export function plotOf(slot) {
  const column = Math.floor(slot / 2);
  const side = slot % 2 === 0 ? 1 : -1;
  return { slot, column, side, x: COLUMN_SPACING * column, z: PLOT_OFFSET * side, theta: side === 1 ? 0 : Math.PI };
}

// s = +1: X = 16c + x, Z = 12 + z.  s = -1: X = 16c - x, Z = -12 - z.  y is unchanged.
export function localToStreet(slot, x, y, z) {
  const p = plotOf(slot);
  return { x: p.x + p.side * x, y, z: p.z + p.side * z };
}

export function streetToLocal(slot, X, Y, Z) {
  const p = plotOf(slot);
  return { x: p.side * (X - p.x), y: Y, z: p.side * (Z - p.z) };
}

// A direction or velocity from plot-local axes to street axes.
export function localDirToStreet(slot, dx, dz) {
  const s = plotOf(slot).side;
  return { x: s * dx, z: s * dz };
}

export function clampToPlot(x, z) {
  const cx = Math.min(PLOT_HALF, Math.max(-PLOT_HALF, x));
  const cz = Math.min(PLOT_HALF, Math.max(-PLOT_HALF, z));
  return { x: cx, z: cz, clamped: cx !== x || cz !== z };
}

// spaces: [{ spaceId, slot (0-11 or null), index }] in message order -> Map spaceId -> slot.
// A missing slot uses the array index; a later space on a taken slot moves on to the next free slot.
export function assignSlots(spaces) {
  const taken = new Set();
  const out = new Map();
  for (const s of spaces) {
    const fallback = Number.isInteger(s.index) && s.index >= 0 ? s.index % SLOT_COUNT : 0;
    let slot = Number.isInteger(s.slot) && s.slot >= 0 && s.slot < SLOT_COUNT ? s.slot : fallback;
    for (let k = 0; k < SLOT_COUNT && taken.has(slot); k++) slot = (slot + 1) % SLOT_COUNT;
    if (taken.has(slot)) continue;
    taken.add(slot);
    out.set(s.spaceId, slot);
  }
  return out;
}

// Street rectangle that the overview camera frames: the occupied columns, at least two of them.
export function streetBounds(slots) {
  let minCol = Infinity;
  let maxCol = -Infinity;
  for (const s of slots) {
    const c = Math.floor(s / 2);
    minCol = Math.min(minCol, c);
    maxCol = Math.max(maxCol, c);
  }
  if (!Number.isFinite(minCol)) { minCol = 0; maxCol = 1; }
  if (maxCol - minCol < 1) maxCol = Math.min(COLUMN_COUNT - 1, minCol + 1);
  if (maxCol - minCol < 1) minCol = Math.max(0, maxCol - 1);
  return {
    minX: minCol * COLUMN_SPACING - PLOT_HALF,
    maxX: maxCol * COLUMN_SPACING + PLOT_HALF,
    minZ: -(PLOT_OFFSET + PLOT_HALF),
    maxZ: PLOT_OFFSET + PLOT_HALF,
  };
}

function tier(r, focusSpaceId) {
  if (r.role === 'self') return 0;
  if (r.role === 'own_ai') return 1;
  if (focusSpaceId && r.spaceId === focusSpaceId) return 2;
  return 3;
}

// Priority for the on-screen limit: role self, then own_ai, then residents of the villa the camera
// is at, then newer updatedAt, then residentId in lexical order.
export function compareResidents(a, b, focusSpaceId = null) {
  const d = tier(a, focusSpaceId) - tier(b, focusSpaceId);
  if (d !== 0) return d;
  const ua = Number.isFinite(a.updatedAtMs) ? a.updatedAtMs : -Infinity;
  const ub = Number.isFinite(b.updatedAtMs) ? b.updatedAtMs : -Infinity;
  if (ua !== ub) return ub > ua ? 1 : -1;
  if (a.residentId < b.residentId) return -1;
  return a.residentId > b.residentId ? 1 : 0;
}

// residents: [{ residentId, spaceId, role, updatedAtMs }]; isPlaced(spaceId) says whether the space
// is on the street. Returns residentId lists { shown, culled, unplaced }.
export function selectResidents(residents, { maxResidents = 8, isPlaced = () => true, focusSpaceId = null } = {}) {
  const placed = [];
  const unplaced = [];
  for (const r of residents) {
    if (isPlaced(r.spaceId)) placed.push(r);
    else unplaced.push(r);
  }
  placed.sort((a, b) => compareResidents(a, b, focusSpaceId));
  return {
    shown: placed.slice(0, maxResidents).map((r) => r.residentId),
    culled: placed.slice(maxResidents).map((r) => r.residentId),
    unplaced: unplaced.map((r) => r.residentId),
  };
}
