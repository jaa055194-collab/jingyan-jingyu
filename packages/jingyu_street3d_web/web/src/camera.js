// Camera framing and flights for the street. fitView() adapts the framing search of
// feiyu-room-template public/room/garden-camera.js (MIT, see CREDITS.md): binary-search the orbit
// radius at which a set of world points fits the viewport, then move the target so the points sit
// in the middle of the free area. CameraRig drives three.js OrbitControls set up like MapControls
// (one finger pans along the ground, two fingers zoom and turn) and animates flights between views.
import * as THREE from 'three';
import { OrbitControls } from '../vendor/OrbitControls.js';
import { PLOT_HALF, VILLA_BOX, localToStreet, plotOf } from './lots.js';

export const FLIGHT_MS = 800;
// Free viewport around the framed points, as fractions of the viewport per side. The top keeps
// room for the overview button.
export const DEFAULT_MARGIN = Object.freeze({ top: 0.12, bottom: 0.06, left: 0.06, right: 0.06 });

const probe = new THREE.PerspectiveCamera();
const v = new THREE.Vector3();

export function wrap(a) {
  return a - 2 * Math.PI * Math.floor((a + Math.PI) / (2 * Math.PI));
}

// Sets out to the camera position on a sphere around (tx, ty, tz): az turns around +Y (0 puts the
// camera on the +Z side, -PI/2 on the -X side), elev is the angle above the ground plane.
export function orbitPosition(out, tx, ty, tz, az, elev, radius) {
  const flat = Math.cos(elev) * radius;
  return out.set(tx + Math.sin(az) * flat, ty + Math.sin(elev) * radius, tz + Math.cos(az) * flat);
}

export function viewOf(position, target) {
  const dx = position.x - target.x;
  const dy = position.y - target.y;
  const dz = position.z - target.z;
  const radius = Math.max(1e-6, Math.hypot(dx, dy, dz));
  return {
    target: { x: target.x, y: target.y, z: target.z },
    radius,
    az: Math.atan2(dx, dz),
    elev: Math.asin(Math.max(-1, Math.min(1, dy / radius))),
  };
}

// The closest orbit view { target, radius, az, elev } in which every point [x, y, z] projects
// inside the viewport minus margin.
export function fitView(points, { az, elev, fov = 50, aspect = 1, margin = DEFAULT_MARGIN, minRadius = 6, maxRadius = 800 } = {}) {
  const m = { ...DEFAULT_MARGIN, ...margin };
  const box = { l: -1 + 2 * m.left, r: 1 - 2 * m.right, b: -1 + 2 * m.bottom, t: 1 - 2 * m.top };
  probe.fov = fov;
  probe.aspect = aspect;
  probe.near = 0.1;
  probe.far = 10000;
  probe.updateProjectionMatrix();
  const target = new THREE.Vector3();
  for (const p of points) {
    target.x += p[0] / points.length;
    target.z += p[2] / points.length;
  }
  const extent = (radius) => {
    orbitPosition(probe.position, target.x, target.y, target.z, az, elev, radius);
    probe.lookAt(target);
    probe.updateMatrixWorld(true);
    const e = { l: Infinity, r: -Infinity, b: Infinity, t: -Infinity, behind: false };
    for (const p of points) {
      v.set(p[0], p[1], p[2]).applyMatrix4(probe.matrixWorldInverse);
      if (v.z > -probe.near) e.behind = true;
      v.applyMatrix4(probe.projectionMatrix);
      e.l = Math.min(e.l, v.x);
      e.r = Math.max(e.r, v.x);
      e.b = Math.min(e.b, v.y);
      e.t = Math.max(e.t, v.y);
    }
    return e;
  };
  const fits = (e) => !e.behind && e.r - e.l <= box.r - box.l && e.t - e.b <= box.t - box.b;
  let radius = maxRadius;
  for (let pass = 0; pass < 3; pass += 1) {
    let lo = minRadius;
    let hi = maxRadius;
    if (fits(extent(lo))) hi = lo;
    else {
      for (let i = 0; i < 24; i += 1) {
        const mid = (lo + hi) / 2;
        if (fits(extent(mid))) hi = mid;
        else lo = mid;
      }
    }
    radius = hi;
    if (pass === 2) break;
    // Recentre along the ground: sideways for the horizontal offset, forward for the vertical one.
    const e = extent(radius);
    const halfH = radius * Math.tan(THREE.MathUtils.degToRad(fov) / 2);
    const side = ((e.l + e.r) / 2 - (box.l + box.r) / 2) * halfH * aspect;
    const ahead = (((e.b + e.t) / 2 - (box.b + box.t) / 2) * halfH) / Math.max(0.2, Math.sin(elev));
    target.x += Math.cos(az) * side - Math.sin(az) * ahead;
    target.z += -Math.sin(az) * side - Math.cos(az) * ahead;
  }
  return { target: { x: target.x, y: target.y, z: target.z }, radius, az, elev };
}

// The whole street: in portrait the camera looks down the street from its -X end, in landscape
// across it. Both stand on the -Z side, so the row with slot 0 shows its fronts.
export function overviewView(bounds, { fov = 50, aspect = 1, margin } = {}) {
  const portrait = aspect < 1;
  const points = [];
  for (const x of [bounds.minX, bounds.maxX]) {
    for (const z of [bounds.minZ, bounds.maxZ]) {
      for (const y of [0, 7]) points.push([x, y, z]);
    }
  }
  // Portrait looks nearly straight down the street from a little higher, so more of the screen
  // height shows the street instead of the field around it.
  const az = portrait ? -Math.PI / 2 - 0.18 : Math.PI - 0.35;
  return fitView(points, { az, elev: 0.85, fov, aspect, margin, minRadius: 20 });
}

// One plot seen three-quarters from the front.
export function villaView(slot, height, { fov = 50, aspect = 1, margin } = {}) {
  const points = [];
  for (const x of [-PLOT_HALF, PLOT_HALF]) {
    for (const z of [-PLOT_HALF, PLOT_HALF]) {
      const s = localToStreet(slot, x, 0, z);
      points.push([s.x, 0, s.z]);
    }
  }
  for (const x of [VILLA_BOX.xMin, VILLA_BOX.xMax]) {
    for (const z of [VILLA_BOX.zMin, VILLA_BOX.zMax]) {
      const s = localToStreet(slot, x, height, z);
      points.push([s.x, height, s.z]);
    }
  }
  const az = wrap(Math.PI + plotOf(slot).theta - 0.45);
  return fitView(points, { az, elev: aspect < 1 ? 0.55 : 0.48, fov, aspect, margin, minRadius: 8 });
}

// Close to one resident, keeping the current heading.
export function residentView(pos, az) {
  return { target: { x: pos.x, y: 0.9, z: pos.z }, radius: 11, az, elev: 0.42 };
}

export class CameraRig {
  constructor(camera, dom, { onArrive = () => {}, onChange = () => {}, onUserMove = () => {} } = {}) {
    this.camera = camera;
    this.onArrive = onArrive;
    this.onChange = onChange;
    this.flight = null;
    this.dragging = false;
    this.updating = false;
    this.mode = 'overview';
    this.spaceId = null;
    this.bounds = null;
    this.lastPos = new THREE.Vector3();
    this.lastQuat = new THREE.Quaternion();
    const c = new OrbitControls(camera, dom);
    c.enableDamping = true;
    c.dampingFactor = 0.14;
    c.screenSpacePanning = false;
    c.mouseButtons = { LEFT: THREE.MOUSE.PAN, MIDDLE: THREE.MOUSE.DOLLY, RIGHT: THREE.MOUSE.ROTATE };
    c.touches = { ONE: THREE.TOUCH.PAN, TWO: THREE.TOUCH.DOLLY_ROTATE };
    c.rotateSpeed = 0.6;
    c.minDistance = 4;
    c.maxDistance = 300;
    c.minPolarAngle = 0.12;
    c.maxPolarAngle = Math.PI / 2 - 0.08;
    c.addEventListener('start', () => {
      this.dragging = true;
      this.flight = null;
    });
    c.addEventListener('end', () => {
      this.dragging = false;
      onChange();
    });
    // Our own update() calls c.update() every frame while damping; only user input wakes the loop.
    c.addEventListener('change', () => {
      if (this.updating) return;
      if (this.dragging && this.mode !== 'free') {
        this.mode = 'free';
        this.spaceId = null;
        onUserMove();
      }
      onChange();
    });
    this.controls = c;
  }

  get view() {
    return viewOf(this.camera.position, this.controls.target);
  }

  // Keeps the orbit target over the street (plus margin) and the zoom within reach of it.
  setBounds(bounds, { margin = 12, maxDistance = 300 } = {}) {
    this.bounds = { minX: bounds.minX - margin, maxX: bounds.maxX + margin, minZ: bounds.minZ - margin, maxZ: bounds.maxZ + margin };
    this.controls.maxDistance = maxDistance;
  }

  // A quiet flight only re-frames after a resize or a layout change; main.js does not report it.
  flyTo(view, { mode = 'free', spaceId = null, id = null, quiet = false } = {}, ms = FLIGHT_MS) {
    this.settle();
    this.flight = { from: this.view, to: view, start: null, ms, mode, spaceId, id, quiet };
    this.onChange();
  }

  // Applies what is left of the damping at once, so a flight starts where the camera would have
  // stopped and nothing drifts after it arrives.
  settle() {
    const c = this.controls;
    c.enableDamping = false;
    this.updating = true;
    c.update();
    this.updating = false;
    c.enableDamping = true;
  }

  jumpTo(view, meta = {}) {
    this.flyTo(view, meta, 0);
  }

  // Advances a flight or the damping; true while the camera still moves.
  update(now) {
    const c = this.controls;
    const f = this.flight;
    if (f) {
      if (f.start === null) f.start = now;
      const k = f.ms > 0 ? Math.min(1, Math.max(0, (now - f.start) / f.ms)) : 1;
      const e = k < 0.5 ? 4 * k * k * k : 1 - ((2 - 2 * k) ** 3) / 2;
      const a = f.from;
      const b = f.to;
      c.target.set(
        a.target.x + (b.target.x - a.target.x) * e,
        a.target.y + (b.target.y - a.target.y) * e,
        a.target.z + (b.target.z - a.target.z) * e,
      );
      const radius = Math.exp(Math.log(a.radius) + (Math.log(b.radius) - Math.log(a.radius)) * e);
      orbitPosition(this.camera.position, c.target.x, c.target.y, c.target.z, a.az + wrap(b.az - a.az) * e, a.elev + (b.elev - a.elev) * e, radius);
      this.camera.lookAt(c.target);
      if (k >= 1) {
        this.flight = null;
        this.mode = f.mode;
        this.spaceId = f.spaceId;
        this.updating = true;
        c.update();
        this.updating = false;
        this.onArrive({ mode: f.mode, spaceId: f.spaceId, id: f.id, quiet: f.quiet });
      }
      this.remember();
      return true;
    }
    this.updating = true;
    const changed = c.update();
    this.updating = false;
    this.clamp();
    const moved = this.camera.position.distanceToSquared(this.lastPos) > 1e-6
      || 1 - Math.abs(this.camera.quaternion.dot(this.lastQuat)) > 1e-9;
    this.remember();
    return this.dragging || (changed && moved);
  }

  remember() {
    this.lastPos.copy(this.camera.position);
    this.lastQuat.copy(this.camera.quaternion);
  }

  clamp() {
    const b = this.bounds;
    if (!b) return;
    const t = this.controls.target;
    const x = Math.min(b.maxX, Math.max(b.minX, t.x));
    const z = Math.min(b.maxZ, Math.max(b.minZ, t.z));
    if (x === t.x && z === t.z) return;
    this.camera.position.x += x - t.x;
    this.camera.position.z += z - t.z;
    t.x = x;
    t.z = z;
  }

  dispose() {
    this.flight = null;
    this.controls.dispose();
  }
}
