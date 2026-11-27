// jingyu_street3d_web: page side of the bridge protocol v1.0 (see ../../PROTOCOL.md).
// Pure module: envelope parsing, payload validation and message builders.
// No DOM and no three.js, so node --test imports it directly. Written for this package.

export const PROTOCOL_VERSION = '1.0';
export const PROTOCOL_MAJOR = 1;
export const MAX_MESSAGE_BYTES = 256 * 1024;
export const MAX_ID_LENGTH = 64;
export const MAX_LABEL_LENGTH = 32;
export const MAX_SPACES = 12;
export const MAX_RESIDENTS = 8;
export const MAX_RESIDENTS_PER_MESSAGE = 32;
export const SLOT_COUNT = 12;
export const ID_RE = /^[A-Za-z0-9_-]{1,64}$/;

export const STYLES = Object.freeze(['seaside', 'forest', 'modern', 'cyber', 'chinese_courtyard']);
export const MOTIONS = Object.freeze(['idle', 'walk', 'sit', 'wave']);
export const RELATIONS = Object.freeze(['self', 'own_ai', 'friend', 'other']);
export const ROLES = Object.freeze(['self', 'own_ai', 'friend', 'visitor', 'other']);
export const CAPS = Object.freeze(['tap', 'camera', 'stats', 'focus', 'theme']);
export const HOST_TYPES = Object.freeze(['hello-ack', 'layout', 'presence', 'pause', 'resume', 'theme', 'focus']);
export const PAGE_TYPES = Object.freeze(['hello', 'ready', 'tap', 'camera', 'error', 'stats']);
export const ERROR_CODES = Object.freeze(['bad_envelope', 'unknown_type', 'bad_payload', 'protocol_mismatch', 'webgl_unavailable', 'context_lost', 'internal']);
const ALWAYS_FATAL = new Set(['protocol_mismatch', 'webgl_unavailable']);

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const isNum = (v) => typeof v === 'number' && Number.isFinite(v);
const has = (o, k) => o[k] !== undefined && o[k] !== null;

function show(v) {
  let s;
  try { s = JSON.stringify(v); } catch { s = undefined; }
  return String(s ?? v).slice(0, 40);
}

// Exact UTF-8 byte length of a JS string (a lone surrogate counts 3 bytes, like U+FFFD).
export function utf8Length(s) {
  let n = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c < 0x80) n += 1;
    else if (c < 0x800) n += 2;
    else if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length && (s.charCodeAt(i + 1) & 0xfc00) === 0xdc00) { n += 4; i++; }
    else n += 3;
  }
  return n;
}

// Cut text to at most max characters (code points, so emoji are not split).
export function clipText(s, max = MAX_LABEL_LENGTH) {
  const cps = Array.from(s);
  return cps.length > max ? cps.slice(0, max).join('') : s;
}

// Major part of a version such as '1.0' (a bare number is accepted too); null when unreadable.
export function parseMajor(v) {
  if (isNum(v)) return Math.trunc(v);
  if (typeof v !== 'string') return null;
  const m = /^([0-9]+)(?:[.][0-9]+)?$/.exec(v.trim());
  return m ? Number(m[1]) : null;
}

// '#RRGGBB' or '#RGB' -> lowercase '#rrggbb'; anything else -> null (the caller uses the style colour).
export function normalizeColor(v) {
  if (typeof v !== 'string') return null;
  const m = /^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/.exec(v.trim());
  if (!m) return null;
  const h = m[1].toLowerCase();
  return '#' + (h.length === 3 ? h[0] + h[0] + h[1] + h[1] + h[2] + h[2] : h);
}

export function summarizeErrors(errors) {
  if (!errors || errors.length === 0) return '';
  return errors.length === 1 ? errors[0] : `${errors[0]} (+${errors.length - 1} more)`;
}

function reject(code, message, ref) {
  return { ok: false, error: { code, message, ref } };
}

// Host -> page envelope. Returns { ok: true, msg } or { ok: false, error: { code, message, ref } }.
export function parseEnvelope(raw) {
  let obj = raw;
  if (typeof raw === 'string') {
    if (raw.length * 3 > MAX_MESSAGE_BYTES && utf8Length(raw) > MAX_MESSAGE_BYTES) {
      return reject('bad_envelope', `message is larger than ${MAX_MESSAGE_BYTES} bytes`);
    }
    try { obj = JSON.parse(raw); } catch { return reject('bad_envelope', 'message is not valid JSON'); }
  }
  if (!isObj(obj)) return reject('bad_envelope', 'message is not a JSON object');
  const ref = typeof obj.id === 'string' && obj.id.length > 0 && obj.id.length <= MAX_ID_LENGTH ? obj.id : undefined;
  if (obj.v !== PROTOCOL_MAJOR) return reject('bad_envelope', `envelope v must be 1, got ${show(obj.v)}`, ref);
  if (typeof obj.type !== 'string' || obj.type === '') return reject('bad_envelope', 'envelope type is missing', ref);
  if (!HOST_TYPES.includes(obj.type)) return reject('unknown_type', `unknown type ${show(obj.type)}`, ref);
  let payload = obj.payload;
  if (payload === undefined || payload === null) payload = {};
  else if (!isObj(payload)) return reject('bad_envelope', 'payload is not an object', ref);
  return { ok: true, msg: { v: PROTOCOL_MAJOR, type: obj.type, id: ref, ts: isNum(obj.ts) ? obj.ts : undefined, payload } };
}

// Page -> host envelope object; encodeEnvelope returns the JSON string that goes on the bridge.
export function makeEnvelope(type, payload = {}, { id, ts } = {}) {
  const env = { v: PROTOCOL_MAJOR, type, ts: Math.round(isNum(ts) ? ts : Date.now()), payload };
  if (typeof id === 'string' && id !== '') env.id = id.slice(0, MAX_ID_LENGTH);
  return env;
}

export function encodeEnvelope(type, payload, opts) {
  return JSON.stringify(makeEnvelope(type, payload, opts));
}

export function helloPayload({ webgl = 2 } = {}) {
  return {
    v: PROTOCOL_VERSION,
    caps: [...CAPS],
    limits: { maxSpaces: MAX_SPACES, maxResidents: MAX_RESIDENTS, maxResidentsPerMessage: MAX_RESIDENTS_PER_MESSAGE },
    renderer: { three: 'r160', webgl: webgl === 1 ? 1 : 2 },
  };
}

export function readyPayload({ restored = false, spaces = 0, residents = 0 } = {}) {
  return { restored: !!restored, spaces, residents };
}

export function errorPayload(code, message, { fatal = false, ref } = {}) {
  const p = { code, message: String(message ?? '').slice(0, 300), fatal: ALWAYS_FATAL.has(code) || !!fatal };
  if (typeof ref === 'string' && ref !== '') p.ref = ref;
  return p;
}

export function tapPayload(kind, id, spaceId) {
  const p = { kind, id };
  if (kind === 'resident' && spaceId) p.spaceId = spaceId;
  return p;
}

export function cameraPayload(mode, spaceId) {
  const p = { mode };
  if (mode === 'villa' && spaceId) p.spaceId = spaceId;
  return p;
}

export function statsPayload({ fps = 0, frameMs = 0, calls = 0, mode = 'idle', shown = 0, culled = 0, unplaced = 0 } = {}) {
  return {
    fps: Math.round(fps * 10) / 10,
    frameMs: Math.round(frameMs * 100) / 100,
    calls, mode,
    residents: { shown, culled, unplaced },
  };
}

// hello-ack payload -> { major, compatible, config, errors }. Bad config fields fall back to defaults.
export function validateHelloAck(payload) {
  const errors = [];
  const major = parseMajor(payload.v);
  const config = { theme: 'light', quality: 'high', maxResidents: MAX_RESIDENTS, statsIntervalMs: 0 };
  const c = payload.config;
  if (has(payload, 'config') && !isObj(c)) errors.push('hello-ack.config is not an object');
  if (isObj(c)) {
    if (has(c, 'theme')) {
      if (c.theme === 'light' || c.theme === 'dark') config.theme = c.theme;
      else errors.push('hello-ack.config.theme must be light or dark');
    }
    if (has(c, 'quality')) {
      if (c.quality === 'high' || c.quality === 'low') config.quality = c.quality;
      else errors.push('hello-ack.config.quality must be high or low');
    }
    if (has(c, 'maxResidents')) {
      if (Number.isInteger(c.maxResidents) && c.maxResidents >= 1 && c.maxResidents <= MAX_RESIDENTS) config.maxResidents = c.maxResidents;
      else errors.push(`hello-ack.config.maxResidents must be an integer 1-${MAX_RESIDENTS}`);
    }
    if (has(c, 'statsIntervalMs')) {
      if (c.statsIntervalMs === 0 || (Number.isInteger(c.statsIntervalMs) && c.statsIntervalMs >= 1000)) config.statsIntervalMs = c.statsIntervalMs;
      else errors.push('hello-ack.config.statsIntervalMs must be 0 or an integer >= 1000');
    }
  }
  return { major, compatible: major === PROTOCOL_MAJOR, config, errors };
}

function readLabel(o, at, errors) {
  if (!has(o, 'label')) return null;
  if (typeof o.label !== 'string') { errors.push(`${at}.label is not a string`); return null; }
  const label = clipText(o.label);
  if (label !== o.label) errors.push(`${at}.label is longer than ${MAX_LABEL_LENGTH} characters`);
  return label;
}

function readEnum(o, key, allowed, fallback, at, errors) {
  if (!has(o, key)) return fallback;
  if (allowed.includes(o[key])) return o[key];
  errors.push(`${at}.${key} is invalid`);
  return fallback;
}

// v1 checks the structure of rooms and furniture but does not draw them (FR-38/39 are out of scope).
function checkRooms(rooms, at, errors) {
  if (rooms === undefined || rooms === null) return 0;
  if (!Array.isArray(rooms)) { errors.push(`${at} is not an array`); return 0; }
  let n = 0;
  rooms.forEach((room, j) => {
    if (!isObj(room)) { errors.push(`${at}[${j}] is not an object`); return; }
    if (has(room, 'furniture') && !Array.isArray(room.furniture)) errors.push(`${at}[${j}].furniture is not an array`);
    n += 1;
  });
  return n;
}

// layout payload -> { spaces, errors }; spaces is null when the message cannot be used at all.
// Each space: { spaceId, version, style, mainColor, slot, label, relation, roomCount, index }.
export function validateLayout(payload) {
  const errors = [];
  if (!Array.isArray(payload.spaces)) return { spaces: null, errors: ['layout.spaces is not an array'] };
  let list = payload.spaces;
  if (list.length > MAX_SPACES) {
    errors.push(`layout.spaces has ${list.length} entries, only the first ${MAX_SPACES} are used`);
    list = list.slice(0, MAX_SPACES);
  }
  const spaces = [];
  const seen = new Set();
  list.forEach((s, i) => {
    const at = `layout.spaces[${i}]`;
    if (!isObj(s)) { errors.push(`${at} is not an object`); return; }
    if (typeof s.spaceId !== 'string' || !ID_RE.test(s.spaceId)) { errors.push(`${at}.spaceId is invalid`); return; }
    if (seen.has(s.spaceId)) { errors.push(`${at}.spaceId repeats an earlier space`); return; }
    if (!Number.isInteger(s.version) || s.version < 0) { errors.push(`${at}.version is not a non-negative integer`); return; }
    seen.add(s.spaceId);
    let slot = null;
    if (has(s, 'slot')) {
      if (Number.isInteger(s.slot) && s.slot >= 0 && s.slot < SLOT_COUNT) slot = s.slot;
      else errors.push(`${at}.slot must be an integer 0-${SLOT_COUNT - 1}`);
    }
    spaces.push({
      spaceId: s.spaceId,
      version: s.version,
      style: STYLES.includes(s.style) ? s.style : 'modern',
      mainColor: normalizeColor(s.mainColor),
      slot,
      label: readLabel(s, at, errors),
      relation: readEnum(s, 'relation', RELATIONS, 'other', at, errors),
      roomCount: checkRooms(s.rooms, `${at}.rooms`, errors),
      index: i,
    });
  });
  return { spaces, errors };
}

// presence payload -> { t, residents, errors }; residents is null when the message cannot be used.
// Each resident: { residentId, spaceId, x, y, z, motion, updatedAtMs, label, role }.
export function validatePresence(payload) {
  const errors = [];
  if (!isNum(payload.t)) return { t: null, residents: null, errors: ['presence.t is not a finite number'] };
  if (!Array.isArray(payload.residents)) return { t: payload.t, residents: null, errors: ['presence.residents is not an array'] };
  let list = payload.residents;
  if (list.length > MAX_RESIDENTS_PER_MESSAGE) {
    errors.push(`presence.residents has ${list.length} entries, only the first ${MAX_RESIDENTS_PER_MESSAGE} are used`);
    list = list.slice(0, MAX_RESIDENTS_PER_MESSAGE);
  }
  const residents = [];
  const seen = new Set();
  list.forEach((r, i) => {
    const at = `presence.residents[${i}]`;
    if (!isObj(r)) { errors.push(`${at} is not an object`); return; }
    if (typeof r.residentId !== 'string' || !ID_RE.test(r.residentId)) { errors.push(`${at}.residentId is invalid`); return; }
    if (seen.has(r.residentId)) { errors.push(`${at}.residentId repeats an earlier resident`); return; }
    if (typeof r.spaceId !== 'string' || !ID_RE.test(r.spaceId)) { errors.push(`${at}.spaceId is invalid`); return; }
    const bad = ['x', 'y', 'z'].find((k) => !isNum(r[k]));
    if (bad) { errors.push(`${at}.${bad} is not a finite number`); return; }
    seen.add(r.residentId);
    let updatedAtMs = null;
    if (has(r, 'updatedAt')) {
      const ms = typeof r.updatedAt === 'string' ? Date.parse(r.updatedAt) : NaN;
      if (Number.isFinite(ms)) updatedAtMs = ms;
      else errors.push(`${at}.updatedAt is not an ISO-8601 time`);
    }
    residents.push({
      residentId: r.residentId,
      spaceId: r.spaceId,
      x: r.x, y: r.y, z: r.z,
      motion: MOTIONS.includes(r.motion) ? r.motion : 'idle',
      updatedAtMs,
      label: readLabel(r, at, errors),
      role: readEnum(r, 'role', ROLES, 'other', at, errors),
    });
  });
  return { t: payload.t, residents, errors };
}

export function validateTheme(payload) {
  if (payload.mode === 'light' || payload.mode === 'dark') return { mode: payload.mode, errors: [] };
  return { mode: null, errors: ['theme.mode must be light or dark'] };
}

export function validateFocus(payload) {
  const kind = payload.kind;
  if (kind === 'overview') return { focus: { kind }, errors: [] };
  if (kind === 'villa' || kind === 'resident') {
    if (typeof payload.id === 'string' && ID_RE.test(payload.id)) return { focus: { kind, id: payload.id }, errors: [] };
    return { focus: null, errors: [`focus.id is missing or invalid for kind ${kind}`] };
  }
  return { focus: null, errors: ['focus.kind must be overview, villa or resident'] };
}
