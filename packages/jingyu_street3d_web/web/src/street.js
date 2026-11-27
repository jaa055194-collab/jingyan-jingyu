// The street every villa stands on: a base field, a two-lane road along +X, sidewalks with curbs,
// a lawn for each of the 12 plots, and street lamps and trees between the plots. It is built once
// with the kit's instancing batch, the pattern of feiyu-room-template public/room/garden-world.js
// (MIT, see CREDITS.md), so the whole street costs about a dozen draw calls on a phone.
import * as THREE from 'three';
import { batch, disposeInstances } from './kit.js';
import { COLUMN_COUNT, COLUMN_SPACING, LANE_HALF, PLOT_HALF, PLOT_SIZE, SIDEWALK_OUTER, plotOf } from './lots.js';

// The road runs 9 m past the outer plots on both ends.
export const STREET_MIN_X = -PLOT_HALF - 9;
export const STREET_MAX_X = COLUMN_SPACING * (COLUMN_COUNT - 1) + PLOT_HALF + 9;

const PALETTE = Object.freeze({
  field: 0x6d8151, verge: 0x7a8c58, lawn: 0x8f9d6a,
  asphalt: 0x575b61, mark: 0xeeeae0, sidewalk: 0xd0c4a6, curb: 0xbdb49e,
  iron: 0x3b3f45, glow: 0xffd9a0,
  trunk: 0x6b4a32, leaf: 0x588b40, leafLight: 0x80a84d, leafDark: 0x386840,
});

// Deterministic 0..1 noise, so every phone draws the same trees.
function rand(i) {
  const s = Math.sin((i + 1) * 12.9898) * 43758.5453;
  return s - Math.floor(s);
}

export function buildStreet(scene, { theme = 'light' } = {}) {
  const group = new THREE.Group();
  group.name = 'street';
  const mats = [];
  const mat = (color, roughness = 0.9, extra = {}) => {
    const m = new THREE.MeshStandardMaterial({ color, roughness, metalness: 0, ...extra });
    mats.push(m);
    return m;
  };
  const M = {
    field: mat(PALETTE.field, 1), verge: mat(PALETTE.verge, 1), lawn: mat(PALETTE.lawn, 1),
    asphalt: mat(PALETTE.asphalt, 0.95), mark: mat(PALETTE.mark, 0.8),
    sidewalk: mat(PALETTE.sidewalk, 0.95), curb: mat(PALETTE.curb, 0.9),
    iron: mat(PALETTE.iron, 0.6, { metalness: 0.4 }),
    glow: mat(PALETTE.glow, 0.5, { emissive: PALETTE.glow, emissiveIntensity: 0.15 }),
    trunk: mat(PALETTE.trunk, 0.95), leaf: mat(PALETTE.leaf, 0.85),
    leafLight: mat(PALETTE.leafLight, 0.85), leafDark: mat(PALETTE.leafDark, 0.9),
  };
  const length = STREET_MAX_X - STREET_MIN_X;
  const cx = (STREET_MIN_X + STREET_MAX_X) / 2;

  // Flat surfaces only receive shadows. Heights: field top -0.15, road top -0.12, verge top
  // -0.02, sidewalks and lawns top 0 (the plot ground residents stand on), curbs top 0.01.
  const ground = batch(group, { castShadow: false, name: 'street-ground' });
  const F = ground.put;
  F('box', M.field, cx, -0.25, 0, 800, 0.2, 800);
  F('box', M.asphalt, cx, -0.15, 0, length, 0.06, LANE_HALF * 2);
  for (const side of [1, -1]) {
    F('box', M.sidewalk, cx, -0.1, side * (LANE_HALF + SIDEWALK_OUTER) / 2, length, 0.2, SIDEWALK_OUTER - LANE_HALF);
    F('box', M.curb, cx, -0.09, side * (LANE_HALF + 0.09), length, 0.2, 0.18);
    F('box', M.verge, cx, -0.12, side * (SIDEWALK_OUTER + 40) / 2, length, 0.2, 40 - SIDEWALK_OUTER);
    F('box', M.mark, cx, -0.115, side * (LANE_HALF - 0.35), length, 0.012, 0.12);
  }
  for (let x = STREET_MIN_X + 2; x < STREET_MAX_X - 2; x += 4) F('box', M.mark, x, -0.115, 0, 2, 0.012, 0.14);
  for (let slot = 0; slot < COLUMN_COUNT * 2; slot += 1) {
    const p = plotOf(slot);
    F('box', M.lawn, p.x, -0.05, p.z, PLOT_SIZE, 0.1, PLOT_SIZE);
  }

  const props = batch(group, { name: 'street-props' });
  const P = props.put;
  const tree = (x, z, i) => {
    const h = 0.85 + rand(i) * 0.35;
    if (i % 3 === 2) {
      P('cyl', M.trunk, x, 0.5 * h, z, 0.12, h, 0.12);
      P('cone', M.leafDark, x, 2.3 * h, z, 1.05 * h, 3 * h, 1.05 * h);
    } else {
      P('cyl', M.trunk, x, 0.8 * h, z, 0.14, 1.6 * h, 0.14);
      P('ball', i % 2 ? M.leaf : M.leafLight, x, 2.5 * h, z, 1.35 * h, 1.2 * h, 1.35 * h);
      P('ball', M.leafDark, x + 0.45, 3.15 * h, z - 0.25, 0.8 * h, 0.75 * h, 0.8 * h);
    }
  };
  // Lamps on both sidewalks and a tree in every 2 m gap between plots (X = 16c + 8).
  for (let c = -1; c < COLUMN_COUNT; c += 1) {
    const x = COLUMN_SPACING * c + COLUMN_SPACING / 2;
    for (const side of [1, -1]) {
      const z = side * (SIDEWALK_OUTER - 0.35);
      P('cyl', M.iron, x, 0.15, z, 0.13, 0.3, 0.13);
      P('cyl', M.iron, x, 1.9, z, 0.06, 3.8, 0.06);
      props.rod(M.iron, [x, 3.7, z], [x, 3.85, z - side * 0.75], 0.035);
      P('box', M.glow, x, 3.8, z - side * 0.85, 0.28, 0.1, 0.42);
      tree(x, side * (PLOT_HALF + 5.5), (c + 1) * 2 + (side > 0 ? 0 : 1));
    }
  }
  // A loose row of trees behind the plots gives the street a backdrop.
  let k = 100;
  for (const side of [1, -1]) {
    for (let x = STREET_MIN_X + 2; x < STREET_MAX_X - 2; x += 5, k += 1) {
      tree(x + (rand(k + 7) - 0.5) * 2.4, side * (23 + rand(k) * 5), k);
    }
  }
  ground.flush();
  props.flush();
  group.traverse((o) => {
    o.matrixAutoUpdate = false;
    o.updateMatrix();
  });
  scene.add(group);

  const street = {
    group,
    // Lamps glow at night only.
    setTheme(mode) {
      M.glow.emissiveIntensity = mode === 'dark' ? 2.2 : 0.15;
    },
    dispose() {
      scene.remove(group);
      disposeInstances(group);
      for (const m of mats) m.dispose();
    },
  };
  street.setTheme(theme);
  return street;
}
