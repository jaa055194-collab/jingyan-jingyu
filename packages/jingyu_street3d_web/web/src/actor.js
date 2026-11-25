// Procedural chibi resident for the 3D street (one per shown resident, at most 8 on screen).
// Adapted from feiyu-src public/room/actor3d.js (ChibiActor; dafiyu-house-template 3.0.0, MIT, see CREDITS.md).
// Kept: toon shading (MeshToonMaterial with a stepped gradient map), chibi proportions (big head on a
// short body), the soft canvas blob shadow, and the walk bob |sin(8t)| * 0.025 with swinging limbs.
// Changed: far fewer parts, geometries and materials shared by every resident, colours picked from the
// resident id (blue shirt for "self"), a name label, idle poses that stay still so the page can render
// on demand, and positions fed by the snapshot interpolator instead of the template's own walk state.
import * as THREE from 'three';
import { makeLabel } from './label.js';

export const ACTOR_HEIGHT = 1.3; // top of the head in actor units, before scaling
const WALK_SPEED_MIN = 0.05; // units per second; slower counts as standing still
const TELEPORT_STEP = 2.5; // a bigger jump between two frames snaps instead of walking
const TURN_RATE = 10; // per second, exponential approach to the walking direction

const SKIN = [0xf6d7c3, 0xf1c7a6, 0xe0ac87, 0xc68b62];
const HAIR = [0x3a2b25, 0x5b3a29, 0x2c2c34, 0x8a5a3c, 0xd9b26f];
const SHIRT = [0xe0905a, 0x6fae7a, 0xd96c7f, 0x8f7cc8, 0x5fa8c9, 0xe2b84f, 0x7d8fa6];
const PANTS = [0x4a5568, 0x3f5f7f, 0x6b5b4b, 0x2f3e46];
const ROLE_SHIRT = { self: 0x4f8fbf };
const ROLE_RING = { self: 0x4f8fbf, friend: 0xe0905a, family: 0xd96c7f };

export function hashString(text) {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

export function paletteFor(id, role) {
  const h = hashString(String(id));
  return {
    skin: SKIN[h % SKIN.length],
    hair: HAIR[(h >>> 5) % HAIR.length],
    shirt: ROLE_SHIRT[role] ?? SHIRT[(h >>> 10) % SHIRT.length],
    pants: PANTS[(h >>> 15) % PANTS.length],
    ring: ROLE_RING[role] ?? null,
  };
}

/** Pose for a resident that is not walking. Unknown motions stand. */
export function staticPose(motion) {
  switch (motion) {
    case 'sit':
    case 'rest':
      return 'sit';
    case 'sleep':
    case 'lie':
      return 'lie';
    case 'wave':
    case 'greet':
    case 'talk':
    case 'chat':
      return 'wave';
    default:
      return 'stand';
  }
}

export function wrapAngle(a) {
  return a - Math.PI * 2 * Math.round(a / (Math.PI * 2));
}

let shared = null;

function blobShadowTexture() {
  const canvas = document.createElement('canvas');
  canvas.width = canvas.height = 64;
  const ctx = canvas.getContext('2d');
  const g = ctx.createRadialGradient(32, 32, 2, 32, 32, 31);
  g.addColorStop(0, 'rgba(20,30,40,0.36)');
  g.addColorStop(0.6, 'rgba(20,30,40,0.16)');
  g.addColorStop(1, 'rgba(20,30,40,0)');
  ctx.fillStyle = g;
  ctx.fillRect(0, 0, 64, 64);
  const map = new THREE.CanvasTexture(canvas);
  map.colorSpace = THREE.SRGBColorSpace;
  return map;
}

function parts() {
  if (shared) return shared;
  // RGBA rather than RedFormat so the gradient also works if three falls back to WebGL1.
  const grad = new THREE.DataTexture(new Uint8Array([96, 96, 96, 255, 178, 178, 178, 255, 255, 255, 255, 255]), 3, 1, THREE.RGBAFormat);
  grad.minFilter = THREE.NearestFilter;
  grad.magFilter = THREE.NearestFilter;
  grad.generateMipmaps = false;
  grad.needsUpdate = true;
  shared = {
    grad,
    materials: new Map(),
    shadowMaterial: new THREE.MeshBasicMaterial({ map: blobShadowTexture(), transparent: true, depthWrite: false }),
    leg: new THREE.CylinderGeometry(0.055, 0.06, 0.26, 10).translate(0, -0.13, 0),
    shoe: new THREE.BoxGeometry(0.12, 0.06, 0.19).translate(0, -0.27, 0.03),
    body: new THREE.CapsuleGeometry(0.17, 0.14, 4, 12),
    arm: new THREE.CylinderGeometry(0.045, 0.045, 0.26, 8).translate(0, -0.13, 0),
    hand: new THREE.SphereGeometry(0.055, 10, 8).translate(0, -0.27, 0),
    head: new THREE.SphereGeometry(0.3, 22, 16),
    hair: new THREE.SphereGeometry(0.318, 22, 12, 0, Math.PI * 2, 0, Math.PI * 0.55),
    eye: new THREE.SphereGeometry(0.038, 10, 8),
    cheek: new THREE.SphereGeometry(0.045, 10, 6),
    shadow: new THREE.PlaneGeometry(0.85, 0.55).rotateX(-Math.PI / 2),
    ring: new THREE.RingGeometry(0.34, 0.42, 32).rotateX(-Math.PI / 2),
  };
  return shared;
}

function toon(color) {
  const p = parts();
  const key = `t${color}`;
  let m = p.materials.get(key);
  if (!m) {
    m = new THREE.MeshToonMaterial({ color, gradientMap: p.grad });
    p.materials.set(key, m);
  }
  return m;
}

function flat(color, opacity) {
  const p = parts();
  const key = `f${color}:${opacity}`;
  let m = p.materials.get(key);
  if (!m) {
    m = new THREE.MeshBasicMaterial({ color, transparent: true, opacity, depthWrite: false });
    p.materials.set(key, m);
  }
  return m;
}

/** Frees the geometries, materials and textures shared by all residents (call after the last one is gone). */
export function disposeActorResources() {
  if (!shared) return;
  for (const value of Object.values(shared)) if (value && typeof value.dispose === 'function') value.dispose();
  for (const m of shared.materials.values()) m.dispose();
  shared.shadowMaterial.map?.dispose();
  shared = null;
}

export class ResidentActor {
  constructor({ id, spaceId = null, role = 'other', label = '', scale = 1 } = {}) {
    const p = parts();
    const pal = paletteFor(id, role);
    this.id = id;
    this.role = role;
    this.labelText = label;
    this.group = new THREE.Group();
    this.group.name = `resident:${id}`;
    this.group.userData = { kind: 'resident', id, spaceId };
    this.group.scale.setScalar(scale);

    const add = (geometry, material, parent, x = 0, y = 0, z = 0) => {
      const m = new THREE.Mesh(geometry, material);
      m.position.set(x, y, z);
      parent.add(m);
      return m;
    };
    add(p.shadow, p.shadowMaterial, this.group, 0, 0.012, 0).renderOrder = 1;
    if (pal.ring !== null) add(p.ring, flat(pal.ring, 0.85), this.group, 0, 0.016, 0).renderOrder = 2;

    const inner = (this.inner = new THREE.Group());
    this.group.add(inner);
    // Index 0 is the resident's right side (-x, because a resident faces +z).
    this.hips = [-1, 1].map((side) => {
      const hip = new THREE.Group();
      hip.position.set(0.085 * side, 0.3, 0);
      inner.add(hip);
      add(p.leg, toon(pal.pants), hip);
      add(p.shoe, toon(0x3b3b44), hip);
      return hip;
    });
    add(p.body, toon(pal.shirt), inner, 0, 0.5, 0);
    this.shoulders = [-1, 1].map((side) => {
      const shoulder = new THREE.Group();
      shoulder.position.set(0.2 * side, 0.66, 0);
      inner.add(shoulder);
      add(p.arm, toon(pal.shirt), shoulder);
      add(p.hand, toon(pal.skin), shoulder);
      return shoulder;
    });
    const head = new THREE.Group();
    head.position.y = 1.0;
    inner.add(head);
    add(p.head, toon(pal.skin), head);
    add(p.hair, toon(pal.hair), head).rotation.x = -0.32;
    for (const side of [-1, 1]) {
      add(p.eye, toon(0x2b2b33), head, 0.105 * side, -0.02, 0.268).scale.y = 1.3;
      add(p.cheek, toon(0xf4a3a8), head, 0.17 * side, -0.1, 0.236).scale.set(1, 0.6, 0.35);
    }
    if (label) {
      const accent = pal.ring !== null ? `#${pal.ring.toString(16).padStart(6, '0')}` : null;
      this.label = makeLabel(label, { height: 0.26, accent });
      this.label.position.y = ACTOR_HEIGHT + 0.25;
      this.group.add(this.label);
    }

    this.heading = 0;
    this.targetHeading = 0;
    this.phase = 0;
    this.pose = '';
    this.lastX = NaN;
    this.lastZ = NaN;
    this.setPose('stand');
  }

  /** True while this actor still shows `meta` {role, label}; otherwise rebuild it. */
  matches(meta) {
    return meta.role === this.role && (meta.label ?? '') === this.labelText;
  }

  setPose(pose) {
    if (pose === this.pose) return;
    this.pose = pose;
    const { inner, hips, shoulders } = this;
    inner.position.set(0, 0, 0);
    inner.rotation.set(0, 0, 0);
    for (const hip of hips) hip.rotation.set(0, 0, 0);
    shoulders[0].rotation.set(0, 0, -0.12);
    shoulders[1].rotation.set(0, 0, 0.12);
    if (pose === 'sit') {
      inner.position.y = -0.16;
      for (const hip of hips) hip.rotation.x = -1.4;
      for (const shoulder of shoulders) shoulder.rotation.x = -0.45;
    } else if (pose === 'lie') {
      inner.rotation.x = -Math.PI / 2;
      inner.position.set(0, 0.3, 0.5);
    } else if (pose === 'wave') {
      shoulders[0].rotation.z = -2.5;
    }
  }

  /**
   * Moves the actor to a street-space sample {x, y, z, motion} and advances its animation by dt seconds.
   * Returns true while it still needs frames (walking or turning).
   */
  update(sample, dt) {
    let speed = 0;
    if (Number.isFinite(this.lastX)) {
      const dx = sample.x - this.lastX;
      const dz = sample.z - this.lastZ;
      const step = Math.hypot(dx, dz);
      if (step <= TELEPORT_STEP) {
        if (dt > 0) speed = step / dt;
        if (step > 1e-4) this.targetHeading = Math.atan2(dx, dz);
      }
    }
    this.lastX = sample.x;
    this.lastZ = sample.z;
    this.group.position.set(sample.x, Number.isFinite(sample.y) ? sample.y : 0, sample.z);

    const walking = speed > WALK_SPEED_MIN;
    this.setPose(walking ? 'walk' : staticPose(sample.motion));
    let busy = walking;
    const diff = wrapAngle(this.targetHeading - this.heading);
    if (Math.abs(diff) > 0.01) {
      this.heading = wrapAngle(this.heading + diff * Math.min(1, dt * TURN_RATE));
      busy = true;
    } else {
      this.heading = this.targetHeading;
    }
    this.group.rotation.y = this.heading;
    if (walking) {
      this.phase += dt * 8;
      const swing = Math.sin(this.phase);
      this.hips[0].rotation.x = swing * 0.6;
      this.hips[1].rotation.x = -swing * 0.6;
      this.shoulders[0].rotation.x = -swing * 0.5;
      this.shoulders[1].rotation.x = swing * 0.5;
      this.inner.position.y = Math.abs(swing) * 0.025; // the template's walk bob
    }
    return busy;
  }

  dispose() {
    this.group.removeFromParent();
    this.label?.userData.dispose?.();
  }
}
