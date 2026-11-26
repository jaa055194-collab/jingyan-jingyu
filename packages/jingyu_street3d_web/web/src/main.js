// Page entry (PROTOCOL.md): connects the host bridge to the three.js street and draws on demand.
// A frame is drawn only while something moves (a camera flight or its damping, residents between
// two presence snapshots, a changed layout), at most 30 per second, and never while paused, hidden
// or without a WebGL context. Written for this package; the renderer, lights, instancing and
// camera framing it drives are adapted from feiyu-room-template (MIT, see CREDITS.md).
import * as THREE from 'three';
import { ACTOR_HEIGHT, ResidentActor } from './actor.js';
import { Bridge, hostTransport } from './bridge.js';
import { CameraRig, overviewView, residentView, villaView, wrap } from './camera.js';
import { createDemoHost } from './demo-host.js';
import { SnapshotInterpolator } from './interp.js';
import { assignSlots, clampToPlot, localToStreet, plotOf, selectResidents, streetBounds } from './lots.js';
import {
  cameraPayload, helloPayload, readyPayload, statsPayload, summarizeErrors, tapPayload,
  validateFocus, validateHelloAck, validateLayout, validatePresence, validateTheme,
} from './protocol.js';
import { createStage } from './stage.js';
import { buildStreet } from './street.js';
import { buildVilla } from './villa.js';

const FRAME_MIN_MS = 1000 / 30;
const TAP_SLOP_PX = 10;
const TAP_MAX_MS = 300;
const RESIDENT_TAP_PX = 28;
const SHADOW_HEIGHT = 13;

const NOTICE = Object.freeze({
  waiting: '等待宿主',
  webgl: '这台设备无法显示 3D 街区（WebGL 不可用）',
  mismatch: '3D 街区和应用的版本不一致，请更新应用',
  lost: '画面恢复中…',
  failed: '3D 街区出错了，请返回后重试',
});

const container = document.getElementById('stage');
const notice = document.getElementById('notice');
const overviewButton = document.getElementById('overview');
const params = new URLSearchParams(location.search);

const config = { theme: 'light', quality: 'high', maxResidents: 8, statsIntervalMs: 0 };
const flags = { acked: false, laidOut: false, paused: false, readyPending: false, restoredPending: false };
const villas = new Map(); // spaceId -> { villa, space }; space is the applied layout entry with its slot
const actors = new Map(); // residentId -> ResidentActor, only the residents on screen
const interp = new SnapshotInterpolator();
const perf = { frames: 0, cpuMs: 0, calls: 0, since: 0 };
const raycaster = new THREE.Raycaster();
const ndc = new THREE.Vector2();
const tmp = new THREE.Vector3();

let bridge = null;
let stage = null;
let street = null;
let rig = null;
let bounds = streetBounds([]);
let counts = { shown: 0, culled: 0, unplaced: 0 };
let raf = 0;
let lastFrame = 0;
let statsTimer = null;

function errorText(e) {
  return e && typeof e.message === 'string' ? e.message : String(e);
}

function showNotice(text) {
  notice.textContent = text || '';
  notice.hidden = !text;
}

function lens() {
  return { fov: stage.camera.fov, aspect: stage.camera.aspect };
}

// ?demo=1 runs the synthetic host; ?theme= and ?quality= go into its hello-ack.
function demoConfig() {
  const c = {};
  const theme = params.get('theme');
  const quality = params.get('quality');
  if (theme === 'light' || theme === 'dark') c.theme = theme;
  if (quality === 'high' || quality === 'low') c.quality = quality;
  return c;
}

function boot() {
  const transport = hostTransport(window) ?? (params.get('demo') === '1' ? createDemoHost({ config: demoConfig() }) : null);
  if (!transport) {
    showNotice(NOTICE.waiting);
    return;
  }
  bridge = new Bridge(transport, { onMessage: handle });
  try {
    stage = createStage(container, { onContextLost, onContextRestored });
  } catch (e) {
    bridge.error('webgl_unavailable', `cannot create a WebGL context: ${errorText(e)}`, { fatal: true });
    showNotice(NOTICE.webgl);
    return;
  }
  try {
    street = buildStreet(stage.scene, { theme: config.theme });
    stage.camera.position.set(-60, 60, -40);
    rig = new CameraRig(stage.camera, stage.canvas, { onArrive, onChange: requestRender, onUserMove });
    updateLimits();
    fitShadow();
    bindTaps(stage.canvas);
    overviewButton.addEventListener('click', flyOverview);
    window.addEventListener('resize', onResize);
    document.addEventListener('visibilitychange', onVisibility);
  } catch (e) {
    bridge.error('internal', `page setup failed: ${errorText(e)}`, { fatal: true });
    showNotice(NOTICE.failed);
    return;
  }
  bridge.send('hello', helloPayload({ webgl: stage.webgl }));
}

// ---- host messages ----

function handle(msg) {
  const p = msg.payload ?? {};
  if (msg.type === 'hello-ack') onHelloAck(p, msg.id);
  else if (msg.type === 'layout') onLayout(p, msg.id);
  else if (msg.type === 'presence') onPresence(p, msg.id);
  else if (msg.type === 'pause') onPause();
  else if (msg.type === 'resume') onResume();
  else if (msg.type === 'theme') onTheme(p, msg.id);
  else if (msg.type === 'focus') onFocus(p, msg.id);
}

function reportErrors(errors, ref) {
  if (errors.length > 0) bridge.error('bad_payload', summarizeErrors(errors), { ref });
}

function onHelloAck(p, ref) {
  const r = validateHelloAck(p);
  if (!r.compatible) {
    bridge.error('protocol_mismatch', `host protocol ${String(p.v)} is not 1.x`, { fatal: true, ref });
    stopFrames();
    startStats(0);
    stage.canvas.style.visibility = 'hidden';
    overviewButton.hidden = true;
    showNotice(NOTICE.mismatch);
    return;
  }
  reportErrors(r.errors, ref);
  Object.assign(config, r.config);
  flags.acked = true;
  stage.setQuality(config.quality);
  applyTheme(config.theme);
  startStats(config.statsIntervalMs);
  refreshResidents();
  reframe(true);
  requestRender();
}

function onLayout(p, ref) {
  const r = validateLayout(p);
  if (r.spaces) applyLayout(r.spaces);
  reportErrors(r.errors, ref);
}

// The layout is the whole street: spaces missing from it are removed. A higher version rebuilds a
// villa, the same version only moves and relabels it, and a lower version is ignored.
function applyLayout(spaces) {
  const entries = spaces.map((s) => {
    const rec = villas.get(s.spaceId);
    return rec && s.version < rec.space.version ? { ...rec.space, index: s.index, stale: true } : s;
  });
  const slots = assignSlots(entries);
  const keep = new Set();
  for (const e of entries) {
    const slot = slots.get(e.spaceId);
    if (slot === undefined) continue;
    keep.add(e.spaceId);
    let rec = villas.get(e.spaceId);
    if (!rec || (!e.stale && e.version > rec.space.version)) {
      rec?.villa.dispose();
      const villa = buildVilla({ ...e, slot }, { theme: config.theme });
      stage.scene.add(villa.group);
      rec = { villa, space: null };
      villas.set(e.spaceId, rec);
    } else if (!e.stale) {
      rec.villa.setLabel(e.label, e.relation);
    }
    rec.space = { ...(e.stale ? rec.space : e), slot };
    place(rec.villa, slot);
  }
  for (const [id, rec] of villas) {
    if (keep.has(id)) continue;
    rec.villa.dispose();
    villas.delete(id);
  }
  bounds = streetBounds([...villas.values()].map((r) => r.space.slot));
  rig.setBounds(bounds);
  fitShadow();
  const first = !flags.laidOut;
  flags.laidOut = true;
  if (first) flags.readyPending = true;
  refreshResidents();
  reframe(first);
  syncButton();
  requestRender();
}

function place(villa, slot) {
  const p = plotOf(slot);
  villa.slot = slot;
  villa.group.position.set(p.x, 0, p.z);
  villa.group.rotation.y = p.theta;
}

// The orbit target may wander 12 m past the street, and the zoom out to 1.5 times the overview.
function updateLimits() {
  rig.setBounds(bounds, { maxDistance: Math.max(150, overviewView(bounds, lens()).radius * 1.5) });
}

function fitShadow() {
  stage.fitShadow({ minX: bounds.minX - 3, maxX: bounds.maxX + 3, minZ: bounds.minZ, maxZ: bounds.maxZ }, SHADOW_HEIGHT);
}

function onPresence(p, ref) {
  const r = validatePresence(p);
  if (!r.residents) {
    reportErrors(r.errors, ref);
    return;
  }
  const now = performance.now();
  const changes = interp.ingest(r.t, r.residents, now);
  reportErrors(r.errors, ref);
  if (!changes) return; // t did not increase: the whole message is dropped
  const swapped = refreshResidents();
  // The host repeats presence at its poll rate even when nobody moves. Draw only when this
  // message can change the picture, so an idle street draws no frames.
  if (changes.changed || swapped || !interp.settledAt(actors.keys(), now)) requestRender();
}

// Keeps an actor for each resident that fits the on-screen limit (PROTOCOL.md section 6).
// Returns whether any actor was added or removed.
function refreshResidents() {
  if (!rig) return false;
  let swapped = false;
  const focusSpaceId = rig.mode === 'villa' || rig.mode === 'resident' ? rig.spaceId : null;
  const sel = selectResidents(interp.metas(), {
    maxResidents: config.maxResidents,
    isPlaced: (spaceId) => villas.has(spaceId),
    focusSpaceId,
  });
  counts = { shown: sel.shown.length, culled: sel.culled.length, unplaced: sel.unplaced.length };
  const shown = new Set(sel.shown);
  for (const [id, actor] of actors) {
    const meta = interp.meta(id);
    if (shown.has(id) && meta && actor.matches(meta)) continue;
    actor.dispose();
    actors.delete(id);
    swapped = true;
  }
  for (const id of sel.shown) {
    if (actors.has(id)) continue;
    const meta = interp.meta(id);
    const actor = new ResidentActor({ id, spaceId: meta.spaceId, role: meta.role, label: meta.label ?? '' });
    actors.set(id, actor);
    stage.scene.add(actor.group);
    swapped = true;
  }
  return swapped;
}

function onPause() {
  flags.paused = true;
  stopFrames();
  interp.clear(performance.now());
}

function onResume() {
  flags.paused = false;
  lastFrame = 0;
  requestRender();
}

function onTheme(p, ref) {
  const r = validateTheme(p);
  if (!r.mode) {
    reportErrors(r.errors, ref);
    return;
  }
  config.theme = r.mode;
  applyTheme(r.mode);
  requestRender();
}

function applyTheme(mode) {
  stage.setTheme(mode);
  street.setTheme(mode);
  for (const { villa } of villas.values()) villa.setTheme(mode);
  document.body.classList.toggle('theme-dark', mode === 'dark');
}

function onFocus(p, ref) {
  const r = validateFocus(p);
  if (!r.focus) {
    reportErrors(r.errors, ref);
    return;
  }
  const { kind, id } = r.focus;
  if (kind === 'overview') {
    flyOverview();
  } else if (kind === 'villa') {
    if (!flyVilla(id)) bridge.error('bad_payload', `focus: space ${id} is not on the street`, { ref });
  } else {
    const actor = actors.get(id);
    if (!actor) {
      bridge.error('bad_payload', `focus: resident ${id} is not on screen`, { ref });
      return;
    }
    rig.flyTo(residentView(actor.group.position, rig.view.az), { mode: 'resident', spaceId: actor.group.userData.spaceId, id });
    syncButton();
    requestRender();
  }
}

// ---- camera ----

function flyOverview() {
  if (!rig) return;
  rig.flyTo(overviewView(bounds, lens()), { mode: 'overview' });
  syncButton();
  requestRender();
}

function flyVilla(spaceId) {
  const rec = villas.get(spaceId);
  if (!rec) return false;
  rig.flyTo(villaView(rec.space.slot, rec.villa.height, lens()), { mode: 'villa', spaceId });
  syncButton();
  requestRender();
  return true;
}

// The host hears about every finished flight it can act on, never about re-framing.
function onArrive({ mode, spaceId, quiet }) {
  syncButton();
  refreshResidents();
  if (quiet) return;
  if (mode === 'overview') bridge.send('camera', cameraPayload('overview'));
  // camera knows only overview and villa: a resident focus reports the villa the resident is at.
  else if (spaceId) bridge.send('camera', cameraPayload('villa', spaceId));
}

function onUserMove() {
  syncButton();
  refreshResidents();
}

function syncButton() {
  const mode = rig.flight ? rig.flight.mode : rig.mode;
  overviewButton.hidden = !flags.laidOut || bridge.dead || mode === 'overview';
}

function sameView(a, b) {
  return Math.hypot(a.target.x - b.target.x, a.target.z - b.target.z) < 0.05
    && Math.abs(Math.log(a.radius / b.radius)) < 0.005
    && Math.abs(wrap(a.az - b.az)) < 0.005
    && Math.abs(a.elev - b.elev) < 0.005;
}

// After a layout change or a resize, keeps the overview or the focused villa framed. A flight the
// host or the user asked for finishes first; a dragged camera stays where it is.
function reframe(jump) {
  if (!rig || rig.dragging) return;
  const f = rig.flight;
  if (f && !f.quiet) return;
  const mode = f ? f.mode : rig.mode;
  const spaceId = f ? f.spaceId : rig.spaceId;
  let view = null;
  if (mode === 'overview') {
    view = overviewView(bounds, lens());
  } else if (mode === 'villa') {
    const rec = villas.get(spaceId);
    if (!rec) {
      flyOverview();
      return;
    }
    view = villaView(rec.space.slot, rec.villa.height, lens());
  }
  if (!view || sameView(view, f ? f.to : rig.view)) return;
  const meta = { mode, spaceId, quiet: true };
  if (jump) rig.jumpTo(view, meta);
  else rig.flyTo(view, meta);
}

// ---- frames ----

function canRender() {
  return flags.acked && !flags.paused && !document.hidden && !stage.lost && !bridge.dead;
}

function requestRender() {
  if (raf === 0 && stage && canRender()) raf = requestAnimationFrame(drawFrame);
}

function stopFrames() {
  if (raf !== 0) cancelAnimationFrame(raf);
  raf = 0;
}

function drawFrame(now) {
  raf = 0;
  if (!canRender()) return;
  if (lastFrame !== 0 && now - lastFrame < FRAME_MIN_MS - 3) {
    raf = requestAnimationFrame(drawFrame);
    return;
  }
  let busy = false;
  try {
    busy = step(now);
  } catch (e) {
    bridge.error('internal', `drawing a frame failed: ${errorText(e)}`);
  }
  if (busy) requestRender();
}

// Advances the camera and the residents, draws one frame and says whether another one is needed.
function step(now) {
  const dt = lastFrame === 0 ? 0 : Math.min(0.1, (now - lastFrame) / 1000);
  lastFrame = now;
  const t0 = performance.now();
  let busy = rig.update(now);
  for (const [id, actor] of actors) {
    const s = interp.sample(id, now);
    if (!s) continue;
    const rec = villas.get(s.spaceId);
    if (!rec) continue;
    const c = clampToPlot(s.x, s.z);
    const w = localToStreet(rec.space.slot, c.x, s.y, c.z);
    actor.group.userData.spaceId = s.spaceId;
    if (actor.update({ x: w.x, y: w.y, z: w.z, motion: s.motion }, dt)) busy = true;
    if (!s.settled) busy = true;
  }
  stage.setViewDistance(rig.view.radius);
  perf.calls = stage.render();
  perf.frames += 1;
  perf.cpuMs += performance.now() - t0;
  if (flags.readyPending) {
    flags.readyPending = false;
    bridge.send('ready', readyPayload({ restored: false, spaces: villas.size, residents: actors.size }));
  }
  if (flags.restoredPending) {
    flags.restoredPending = false;
    bridge.send('ready', readyPayload({ restored: true, spaces: villas.size, residents: actors.size }));
  }
  return busy;
}

function onResize() {
  if (!stage || stage.lost) return;
  stage.resize();
  updateLimits();
  reframe(true);
  requestRender();
}

function onVisibility() {
  if (document.hidden) {
    stopFrames();
  } else {
    lastFrame = 0;
    requestRender();
  }
}

// three.js keeps every geometry, material and texture in memory and uploads them again after a
// restore, so the next frame redraws the street from the layout and presence already held here.
function onContextLost() {
  stopFrames();
  bridge.error('context_lost', 'WebGL context lost, waiting for it to be restored');
  if (!bridge.dead) showNotice(NOTICE.lost);
}

function onContextRestored() {
  showNotice(null);
  if (flags.laidOut && !flags.readyPending) flags.restoredPending = true;
  lastFrame = 0;
  requestRender();
}

// ---- taps ----

// One finger, moving less than 10 px and lifted within 300 ms; anything else belongs to the camera.
function bindTaps(canvas) {
  const down = new Map();
  let multi = false;
  canvas.addEventListener('pointerdown', (e) => {
    if (down.size > 0) multi = true;
    down.set(e.pointerId, { x: e.clientX, y: e.clientY, t: performance.now(), far: false, button: e.button });
  });
  canvas.addEventListener('pointermove', (e) => {
    const d = down.get(e.pointerId);
    if (d && Math.hypot(e.clientX - d.x, e.clientY - d.y) >= TAP_SLOP_PX) d.far = true;
  });
  const end = (e, cancelled) => {
    const d = down.get(e.pointerId);
    down.delete(e.pointerId);
    const single = !multi;
    if (down.size === 0) multi = false;
    if (!d || cancelled || !single || d.far || d.button > 0) return;
    if (performance.now() - d.t >= TAP_MAX_MS) return;
    if (Math.hypot(e.clientX - d.x, e.clientY - d.y) >= TAP_SLOP_PX) return;
    tapAt(e.clientX, e.clientY);
  };
  canvas.addEventListener('pointerup', (e) => end(e, false));
  canvas.addEventListener('pointercancel', (e) => end(e, true));
}

// Residents win within 28 px of their middle on screen; otherwise the ray picks a villa's plot.
// Taps on the road or the field are not reported.
function tapAt(clientX, clientY) {
  if (!flags.laidOut || bridge.dead) return;
  const rect = stage.canvas.getBoundingClientRect();
  const x = clientX - rect.left;
  const y = clientY - rect.top;
  const camera = stage.camera;
  camera.updateMatrixWorld();
  let best = null;
  let bestD = RESIDENT_TAP_PX;
  for (const actor of actors.values()) {
    tmp.set(0, ACTOR_HEIGHT * 0.5, 0);
    actor.group.localToWorld(tmp);
    tmp.project(camera);
    if (tmp.z < -1 || tmp.z > 1) continue;
    const d = Math.hypot(((tmp.x + 1) / 2) * rect.width - x, ((1 - tmp.y) / 2) * rect.height - y);
    if (d < bestD) {
      bestD = d;
      best = actor;
    }
  }
  if (best) {
    bridge.send('tap', tapPayload('resident', best.id, best.group.userData.spaceId));
    return;
  }
  ndc.set((x / rect.width) * 2 - 1, 1 - (y / rect.height) * 2);
  raycaster.setFromCamera(ndc, camera);
  const hit = raycaster.intersectObjects([...villas.values()].map((r) => r.villa.pick), false)[0];
  if (!hit) return;
  const spaceId = hit.object.userData.spaceId;
  bridge.send('tap', tapPayload('villa', spaceId));
  flyVilla(spaceId);
}

// ---- stats ----

function startStats(ms) {
  if (statsTimer !== null) clearInterval(statsTimer);
  statsTimer = null;
  perf.frames = 0;
  perf.cpuMs = 0;
  perf.since = performance.now();
  if (ms >= 1000) statsTimer = setInterval(sendStats, ms);
}

function sendStats() {
  if (bridge.dead) {
    startStats(0);
    return;
  }
  const now = performance.now();
  const secs = Math.max(0.001, (now - perf.since) / 1000);
  const mode = flags.paused ? 'paused' : document.hidden ? 'hidden' : raf !== 0 ? 'running' : 'idle';
  bridge.send('stats', statsPayload({
    fps: perf.frames / secs,
    frameMs: perf.frames > 0 ? perf.cpuMs / perf.frames : 0,
    calls: perf.calls,
    mode,
    ...counts,
  }));
  perf.frames = 0;
  perf.cpuMs = 0;
  perf.since = now;
}

boot();
