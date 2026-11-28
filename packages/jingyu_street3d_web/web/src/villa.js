// One villa per space, in plot-local coordinates: the 14 x 14 m plot is centred on the origin,
// +z points away from the street, the front door at (0, 0, 0.5) faces -z and the gate gap is at
// (0, 0, -7). Parts go through the kit's instancing batch, the way feiyu-room-template
// public/room/garden-world.js builds its garden structures (MIT, see CREDITS.md), so a villa
// costs one draw call per geometry + material pair whatever its size.
import * as THREE from 'three';
import { batch, disposeInstances, geometry, materialSet, tint } from './kit.js';
import { makeLabel } from './label.js';
import { GATE, PLOT_HALF, PLOT_SIZE, VILLA_BOX } from './lots.js';

export const FLOOR_HEIGHT = 2.9;
const PLINTH = 0.3;
const GATE_HALF = 1.1;
const EDGE = PLOT_HALF - 0.2;
const W = VILLA_BOX.xMax - VILLA_BOX.xMin;
const D = VILLA_BOX.zMax - VILLA_BOX.zMin;
const CZ = (VILLA_BOX.zMin + VILLA_BOX.zMax) / 2;
const FRONT = VILLA_BOX.zMin;

// Per style: the default main colour (used when mainColor is missing or invalid), the fixed
// colours around it and the kind of plot border.
export const STYLES = Object.freeze({
  seaside: Object.freeze({ main: 0x4f8fbf, wall: 0xf4f0e6, trim: 0xfdfcf8, base: 0xd9cdb4, border: 0xf7f5ef, fence: 'picket' }),
  forest: Object.freeze({ main: 0x5f7f45, wall: 0x8b5e3c, trim: 0x5a3b26, base: 0x8d8678, border: 0x7a5236, fence: 'rail' }),
  modern: Object.freeze({ main: 0x3f4b57, wall: 0xeceae5, trim: 0xb08458, base: 0x9a9890, border: 0x4f7a43, fence: 'hedge' }),
  cyber: Object.freeze({ main: 0x8a5cff, wall: 0x262a35, trim: 0x11131a, base: 0x1c1f27, border: 0x2b2f3a, fence: 'neon' }),
  chinese_courtyard: Object.freeze({ main: 0xb23a2e, wall: 0xebe3d2, trim: 0x4a4f55, base: 0x8e8a82, border: 0xd9d2c3, fence: 'wall' }),
});

// Name-tag outline per relation; other spaces get none.
export const ACCENTS = Object.freeze({ self: '#4f8fbf', own_ai: '#8a6fd1', friend: '#e0905a' });

// The plot border as straight runs [ax, az, bx, bz], split by the gate gap.
const RUNS = Object.freeze([
  [-EDGE, -EDGE, -GATE_HALF, -EDGE], [GATE_HALF, -EDGE, EDGE, -EDGE],
  [EDGE, -EDGE, EDGE, EDGE], [EDGE, EDGE, -EDGE, EDGE], [-EDGE, EDGE, -EDGE, -EDGE],
]);

// Shared by every pick box. Pick boxes are hidden: three.js ray casts ignore visibility.
const PICK_MATERIAL = new THREE.MeshBasicMaterial();

export function styleOf(style) {
  return Object.prototype.hasOwnProperty.call(STYLES, style) ? style : 'modern';
}

export function floorsFor(roomCount) {
  const n = Number.isFinite(roomCount) ? roomCount : 0;
  return n <= 2 ? 1 : n <= 5 ? 2 : 3;
}

export function mainColorOf(space) {
  const hex = space.mainColor;
  if (typeof hex === 'string' && /^#[0-9a-f]{6}$/i.test(hex)) return parseInt(hex.slice(1), 16);
  return STYLES[styleOf(space.style)].main;
}

function border(P, M, kind) {
  for (const [ax, az, bx, bz] of RUNS) {
    const len = Math.hypot(bx - ax, bz - az);
    const cx = (ax + bx) / 2;
    const cz = (az + bz) / 2;
    const alongX = az === bz;
    const bar = (m, y, h, t) => P('box', m, cx, y, cz, alongX ? len : t, h, alongX ? t : len);
    const posts = (m, step, w, h) => {
      const n = Math.max(1, Math.round(len / step));
      for (let i = 0; i <= n; i += 1) P('box', m, ax + ((bx - ax) * i) / n, h / 2, az + ((bz - az) * i) / n, w, h, w);
    };
    if (kind === 'picket') {
      posts(M.border, 0.45, 0.08, 0.95);
      bar(M.border, 0.32, 0.07, 0.04);
      bar(M.border, 0.72, 0.07, 0.04);
    } else if (kind === 'rail') {
      posts(M.trim, 1.8, 0.16, 1.05);
      bar(M.border, 0.45, 0.1, 0.08);
      bar(M.border, 0.88, 0.1, 0.08);
    } else if (kind === 'hedge') {
      bar(M.border, 0.4, 0.8, 0.6);
    } else if (kind === 'neon') {
      bar(M.border, 0.25, 0.5, 0.3);
      bar(M.neon, 0.53, 0.06, 0.1);
    } else {
      bar(M.border, 0.7, 1.4, 0.3);
      bar(M.trim, 1.46, 0.12, 0.44);
    }
  }
}

// A framed window on the front wall (face 0) or a side wall (face -1 or +1); u runs along the wall.
function windowAt(P, frame, glass, face, u, y, w, h) {
  if (face === 0) {
    P('box', frame, u, y, FRONT - 0.03, w + 0.2, h + 0.2, 0.06);
    P('box', glass, u, y, FRONT - 0.07, w, h, 0.04);
  } else {
    P('box', frame, face * (W / 2 + 0.03), y, u, 0.06, h + 0.2, w + 0.2);
    P('box', glass, face * (W / 2 + 0.07), y, u, 0.04, h, w);
  }
}

// space: a validated layout entry { spaceId, version, style, mainColor, slot, label, relation,
// roomCount }. The caller places group on the plot of its slot.
export function buildVilla(space, { theme = 'light' } = {}) {
  const style = styleOf(space.style);
  const S = STYLES[style];
  const main = mainColorOf(space);
  const floors = floorsFor(space.roomCount);
  const mats = materialSet();
  const M = {
    main: mats.get(main, { roughness: 0.7 }),
    wall: mats.get(S.wall, { roughness: 0.9 }),
    trim: mats.get(S.trim, { roughness: 0.75 }),
    base: mats.get(S.base, { roughness: 0.95 }),
    border: mats.get(S.border, { roughness: 0.9 }),
    door: mats.get(tint(main, 0x1a1410, 0.45), { roughness: 0.7 }),
    path: mats.get(0xc9bfa6, { roughness: 1 }),
    bush: mats.get(0x4f7a43, { roughness: 0.9 }),
    leaf: mats.get(0x588b40, { roughness: 0.85 }),
    wood: mats.get(0x6b4a32, { roughness: 0.95 }),
    glass: mats.get(0x9fc3d6, { roughness: 0.2, metalness: 0.2, emissive: 0xffc77a, emissiveIntensity: 0 }),
    neon: mats.get(main, { roughness: 0.4, emissive: main, emissiveIntensity: 0.8 }),
    lantern: style === 'chinese_courtyard' ? mats.get(0xd8432f, { roughness: 0.5, emissive: 0xff7a3d, emissiveIntensity: 0.4 }) : null,
  };
  const group = new THREE.Group();
  group.name = `villa:${space.spaceId}`;
  group.userData = { kind: 'villa', spaceId: space.spaceId };
  const parts = batch(group, { name: 'villa' });
  const ground = batch(group, { castShadow: false, name: 'villa-ground' });
  const P = parts.put;
  const bodyH = floors * FLOOR_HEIGHT;
  const top = PLINTH + bodyH;
  const frame = style === 'seaside' ? M.main : M.trim;

  // Path from the gate to the door step, the plot border and the gate posts.
  ground.put('box', M.path, 0, 0.012, (GATE.z + FRONT - 0.9) / 2, 1.5, 0.024, FRONT - 0.9 - GATE.z);
  border(P, M, S.fence);
  const gateH = S.fence === 'wall' ? 1.9 : 1.25;
  for (const x of [-GATE_HALF - 0.15, GATE_HALF + 0.15]) P('box', M.trim, x, gateH / 2, -EDGE, 0.3, gateH, 0.3);

  // Body: plinth, walls, a band between floors, the door and its step.
  P('box', M.base, 0, PLINTH / 2, CZ, W + 0.3, PLINTH, D + 0.3);
  P('box', M.wall, 0, PLINTH + bodyH / 2, CZ, W, bodyH, D);
  for (let f = 1; f < floors; f += 1) P('box', style === 'cyber' ? M.neon : M.trim, 0, PLINTH + f * FLOOR_HEIGHT, CZ, W + 0.12, 0.14, D + 0.12);
  P('box', frame, 0, PLINTH + 1.1, FRONT - 0.03, 1.5, 2.4, 0.06);
  P('box', M.door, 0, PLINTH + 1.05, FRONT - 0.07, 1.1, 2.1, 0.06);
  P('box', M.base, 0, 0.15, FRONT - 0.55, 2.2, 0.3, 1.0);

  // Windows on the front and both sides of every floor; modern and cyber get wide glass.
  const wide = style === 'modern' || style === 'cyber';
  const fronts = wide ? [-2.4, 2.4] : [-3.1, -1.7, 1.7, 3.1];
  for (let f = 0; f < floors; f += 1) {
    const y = PLINTH + f * FLOOR_HEIGHT + 1.55;
    for (const x of fronts) windowAt(P, frame, M.glass, 0, x, y, wide ? 2.3 : 1.0, 1.3);
    if (f > 0) windowAt(P, frame, M.glass, 0, 0, y, wide ? 1.6 : 1.0, 1.3);
    for (const face of [-1, 1]) for (const z of [CZ - 1.4, CZ + 1.4]) windowAt(P, frame, M.glass, face, z, y, 1.0, 1.3);
  }

  // Front yard.
  if (style === 'cyber') {
    for (const z of [-5.6, -3.6, -1.6]) for (const x of [-1.05, 1.05]) P('cyl', M.neon, x, 0.3, z, 0.06, 0.6, 0.06);
  } else {
    for (const x of [-1.9, 1.9]) P('ball', M.bush, x, 0.4, -3.4, 0.6, 0.45, 0.6);
  }

  // Roof and the style's own details.
  let roofTop = top;
  if (style === 'seaside') {
    P('box', M.trim, 0, top + 0.1, CZ, W + 0.6, 0.2, D + 0.6);
    P('hip', M.main, 0, top + 0.2, CZ, W + 1.4, 2.2, D + 1.4);
    roofTop = top + 2.4;
    for (const x of [-1.5, 1.5]) P('cyl', M.trim, x, PLINTH + 1.3, FRONT - 1.4, 0.1, 2.6, 0.1);
    P('box', M.trim, 0, PLINTH + 2.68, FRONT - 0.75, 3.8, 0.16, 1.7);
    P('cyl', M.wood, -5.2, 2.1, -4.4, 0.14, 4.2, 0.14, 0, 0, 0.06);
    P('cone', M.leaf, -5.32, 4.3, -4.4, 1.6, 0.7, 1.6);
  } else if (style === 'forest') {
    P('prism', M.main, 0, top, CZ, D + 1.2, 3.4, W + 1.0, 0, Math.PI / 2, 0);
    roofTop = top + 3.4;
    P('box', M.base, 2.7, top + 1.5, CZ + 1.4, 0.8, 3.6, 0.8);
    for (const x of [-W / 2, W / 2]) for (const z of [FRONT, VILLA_BOX.zMax]) P('cyl', M.trim, x, PLINTH + bodyH / 2, z, 0.2, bodyH, 0.2);
    for (const [x, z, s] of [[-5.7, -4.6, 1], [5.8, -3.6, 0.8]]) {
      P('cyl', M.wood, x, 0.5 * s, z, 0.14, s, 0.14);
      P('cone', M.leaf, x, 2.3 * s, z, 1.2 * s, 3.2 * s, 1.2 * s);
    }
  } else if (style === 'modern') {
    P('box', M.main, 0, top + 0.15, CZ, W + 0.8, 0.3, D + 0.8);
    roofTop = top + 0.3;
    P('box', M.main, -4.05, PLINTH + bodyH / 2, FRONT - 0.08, 0.7, bodyH, 0.1);
    ground.put('box', M.trim, 0, 0.08, FRONT - 1.4, W, 0.16, 1.8);
    for (const x of [-5.6, 5.6]) {
      P('box', M.base, x, 0.3, -4, 1.0, 0.6, 2.6);
      P('ball', M.bush, x, 0.75, -4, 0.55, 0.4, 1.2);
    }
  } else if (style === 'cyber') {
    P('box', M.trim, 0, top + 0.15, CZ, W + 0.4, 0.3, D + 0.4);
    roofTop = top + 0.3;
    P('box', M.neon, 0, top + 0.33, FRONT - 0.2, W + 0.4, 0.06, 0.06);
    for (const x of [-W / 2 - 0.04, W / 2 + 0.04]) P('box', M.neon, x, PLINTH + bodyH / 2, FRONT - 0.04, 0.08, bodyH, 0.08);
    P('cyl', M.trim, 3, top + 1.5, CZ + 1.5, 0.05, 3, 0.05);
    P('ball', M.neon, 3, top + 3.05, CZ + 1.5, 0.14, 0.14, 0.14);
  } else {
    P('box', M.base, 0, PLINTH / 2, FRONT - 0.85, W + 0.3, PLINTH, 1.7);
    P('hip', M.trim, 0, top, CZ - 0.9, W + 2.2, 2.4, D + 3.0);
    roofTop = top + 2.6;
    P('box', M.trim, 0, top + 2.45, CZ - 0.9, 3.6, 0.22, 0.5);
    for (const x of [-1.8, 1.8]) P('box', M.trim, x, top + 2.62, CZ - 0.9, 0.3, 0.36, 0.3);
    for (const x of [-3.6, -1.2, 1.2, 3.6]) P('cyl', M.main, x, PLINTH + bodyH / 2, FRONT - 1.5, 0.16, bodyH, 0.16);
    for (const x of [-2.4, 2.4]) P('ball', M.lantern, x, PLINTH + 2.3, FRONT - 1.5, 0.22, 0.28, 0.22);
    for (let i = 0; i < 6; i += 1) {
      const x = 5.3 + (i % 3) * 0.45;
      const z = -4.8 + Math.floor(i / 3) * 0.5;
      const h = 3.2 + (i % 4) * 0.35;
      P('cyl', M.leaf, x, h / 2, z, 0.05, h, 0.05);
      P('ball', M.bush, x, h, z, 0.35, 0.6, 0.35);
    }
  }
  parts.flush();
  ground.flush();
  for (const c of group.children) {
    c.matrixAutoUpdate = false;
    c.updateMatrix();
  }

  const height = roofTop;
  const pick = new THREE.Mesh(geometry('box'), PICK_MATERIAL);
  pick.visible = false;
  pick.position.set(0, (height + 1) / 2, 0);
  pick.scale.set(PLOT_SIZE, height + 1, PLOT_SIZE);
  pick.userData = { kind: 'villa', spaceId: space.spaceId };
  group.add(pick);

  let sprite = null;
  const villa = {
    spaceId: space.spaceId,
    version: space.version,
    style,
    floors,
    slot: space.slot ?? null,
    group,
    pick,
    height,
    label: null,
    relation: null,

    // Rebuilds the name tag only when its text or relation changed.
    setLabel(label, relation) {
      const text = typeof label === 'string' && label.trim() ? label.trim() : null;
      if (text === villa.label && relation === villa.relation && (sprite !== null) === (text !== null)) return;
      villa.label = text;
      villa.relation = relation;
      if (sprite) {
        group.remove(sprite);
        sprite.userData.dispose();
        sprite = null;
      }
      if (!text) return;
      sprite = makeLabel(text, { height: 1.3, accent: ACCENTS[relation] ?? null });
      sprite.position.set(0, height + 1.4, CZ);
      sprite.userData.kind = 'label';
      group.add(sprite);
    },

    // Windows light up at night; neon and lanterns glow brighter.
    setTheme(mode) {
      const dark = mode === 'dark';
      M.glass.emissiveIntensity = dark ? 1.4 : 0;
      M.neon.emissiveIntensity = dark ? 2.4 : 0.8;
      if (M.lantern) M.lantern.emissiveIntensity = dark ? 2 : 0.4;
    },

    dispose() {
      group.removeFromParent();
      if (sprite) sprite.userData.dispose();
      sprite = null;
      disposeInstances(group);
      mats.dispose();
    },
  };
  villa.setLabel(space.label, space.relation);
  villa.setTheme(theme);
  return villa;
}
