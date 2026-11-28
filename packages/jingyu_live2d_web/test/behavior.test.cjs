'use strict';

// Tests for web/live2d_behavior.js; run with: node --test test/behavior.test.cjs
// Every test injects random() and passes explicit frame times, so all timings are exact.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const FILE = path.join(__dirname, '..', 'web', 'live2d_behavior.js');
const Live2DBehavior = require(FILE);

// Parameter rows: [id, minimum, maximum, default].
const EYES = [['ParamEyeLOpen', 0, 1, 1], ['ParamEyeROpen', 0, 1, 1]];
const FOCUS = [
  ['ParamEyeBallX', -1, 1, 0], ['ParamEyeBallY', -1, 1, 0], ['ParamAngleX', -30, 30, 0],
  ['ParamAngleY', -30, 30, 0], ['ParamAngleZ', -30, 30, 0], ['ParamBodyAngleX', -10, 10, 0]
];
const BREATH = [['ParamBreath', 0, 1, 0]];
const MOUTH = [['ParamMouthOpenY', 0, 1, 0]];
const BOTH_EYES = ['ParamEyeLOpen', 'ParamEyeROpen'];

// model.parameters as PurismCore exposes it; { min: false } or { max: false } drops a range.
function makeParams(rows, ranges) {
  const keep = ranges || {};
  const params = {
    count: rows.length,
    ids: rows.map((row) => row[0]),
    defaultValues: Float32Array.from(rows, (row) => row[3])
  };
  if (keep.min !== false) { params.minimumValues = Float32Array.from(rows, (row) => row[1]); }
  if (keep.max !== false) { params.maximumValues = Float32Array.from(rows, (row) => row[2]); }
  return params;
}

// A random() that returns the given values in order, then `rest` from then on.
function sequence(values, rest) {
  let next = 0;
  return () => (next < values.length ? values[next++] : rest);
}

// One viewer frame: the parameters start from `incoming`, then update() runs on them.
function step(behavior, incoming, dtMs, frame) {
  const values = Float64Array.from(incoming);
  behavior.update(values, dtMs, frame);
  return values;
}

// Runs frames of dtMs until totalMs has passed and returns the last frame's values.
function run(behavior, incoming, totalMs, dtMs, frame) {
  let values = null;
  for (let t = 0; t < totalMs; t += dtMs) { values = step(behavior, incoming, dtMs, frame); }
  return values;
}

function near(actual, expected, message, tolerance) {
  const limit = tolerance === undefined ? 1e-6 : tolerance;
  assert.ok(Math.abs(actual - expected) < limit, `${message || 'value'}: ${actual} != ${expected}`);
}

test('exports create() on module.exports and on window.Live2DBehavior', () => {
  assert.equal(typeof Live2DBehavior.create, 'function');
  assert.ok(Object.isFrozen(Live2DBehavior));
  const sandbox = { window: {} };
  vm.runInNewContext(fs.readFileSync(FILE, 'utf8'), sandbox, { filename: FILE });
  assert.equal(typeof sandbox.window.Live2DBehavior.create, 'function');
});

test('create() and update() reject malformed arguments', () => {
  assert.throws(() => Live2DBehavior.create(), TypeError);
  assert.throws(() => Live2DBehavior.create({ count: 1.5, ids: ['A', 'B'] }), TypeError);
  assert.throws(() => Live2DBehavior.create({ count: 2, ids: ['A'] }), TypeError);
  assert.throws(() => Live2DBehavior.create({ count: 1, ids: [7] }), TypeError);
  assert.throws(() => Live2DBehavior.create({ count: 1, ids: ['A'], minimumValues: [] }),
    TypeError);
  assert.throws(() => Live2DBehavior.create(makeParams(EYES), { random: 0.5 }), TypeError);
  const behavior = Live2DBehavior.create(makeParams(EYES), { random: () => 0 });
  assert.throws(() => behavior.update([1], 16), TypeError);
  for (const dt of [-1, NaN, Infinity, '16']) {
    assert.throws(() => behavior.update([1, 1], dt), RangeError);
  }
  assert.throws(() => behavior.update([1, 1], 16, { driven: new Uint8Array(1) }), TypeError);
  behavior.update(new Float32Array(2), 0, { idle: true, driven: null });
});

test('blink waits U(3000, 8000) ms, closes in 75 ms and opens in U(150, 300) ms', () => {
  for (const r of [0, 0.5]) {
    const delay = 3000 + 5000 * r;
    const opening = 150 + 150 * r;
    const behavior = Live2DBehavior.create(makeParams(EYES), { random: () => r });
    behavior.setBlinkIds(BOTH_EYES);
    assert.deepEqual(Array.from(step(behavior, [1, 1], delay - 1)), [1, 1]);
    assert.deepEqual(Array.from(step(behavior, [1, 1], 1)), [1, 1], 'the delay ends open');
    near(step(behavior, [1, 1], 37.5)[0], 0.25, 'closing: 1 - easeOutQuad(0.5)');
    assert.deepEqual(Array.from(step(behavior, [1, 1], 37.5)), [0, 0], 'closed at 75 ms');
    near(step(behavior, [1, 1], opening / 2)[1], 0.25, 'opening: easeInQuad(0.5)');
    assert.deepEqual(Array.from(step(behavior, [1, 1], opening / 2)), [1, 1], 'open again');
    assert.deepEqual(Array.from(step(behavior, [1, 1], delay)), [1, 1], 'a new delay');
    assert.deepEqual(Array.from(step(behavior, [1, 1], 75)), [0, 0]);
  }
});

test('blink closes each eye toward its own minimum', () => {
  const rows = [['ParamEyeLOpen', 0.25, 2, 1.25], ['ParamEyeROpen', -1, 1, 1]];
  const behavior = Live2DBehavior.create(makeParams(rows), { random: () => 0 });
  behavior.setBlinkIds(BOTH_EYES);
  behavior.blinkNow();
  const half = step(behavior, [1.25, 1], 37.5); // factor 0.25
  near(half[0], 0.25 + (1.25 - 0.25) * 0.25);
  near(half[1], -1 + (1 + 1) * 0.25);
  assert.deepEqual(Array.from(step(behavior, [1.25, 1], 37.5)), [0.25, -1]);
});

test('blink yields to a non-idle motion that drives a blink ID', () => {
  const behavior = Live2DBehavior.create(makeParams(EYES), { random: () => 0 }); // 3000 ms
  behavior.setBlinkIds(BOTH_EYES);
  const busy = { idle: false, driven: Uint8Array.of(0, 1) };
  assert.deepEqual(Array.from(step(behavior, [0.75, 0.75], 4000, busy)), [0.75, 0.75]);
  assert.deepEqual(Array.from(step(behavior, [0.75, 0.75], 75, busy)), [0.75, 0.75]);
  behavior.blinkNow();
  near(step(behavior, [1, 1], 37.5)[0], 0.25, 'a blink is running');
  assert.deepEqual(Array.from(step(behavior, [0.75, 0.75], 16, busy)), [0.75, 0.75]);
  assert.deepEqual(Array.from(step(behavior, [1, 1], 37.5)), [1, 1], 'the blink was dropped');
  behavior.blinkNow();
  const eyesFree = { idle: false, driven: Uint8Array.of(0, 0) };
  assert.deepEqual(Array.from(step(behavior, [1, 1], 75, eyesFree)), [0, 0]);
});

test('blink writes nothing while every blink ID is within 0.15 of its minimum', () => {
  const behavior = Live2DBehavior.create(makeParams(EYES), { random: () => 0 });
  behavior.setBlinkIds(BOTH_EYES);
  behavior.blinkNow();
  assert.deepEqual(Array.from(step(behavior, [0.125, 0.0625], 37.5)), [0.125, 0.0625]);
  const mixed = step(behavior, [0.125, 1], 18.75); // progress 0.75: factor 1 / 16
  assert.deepEqual(Array.from(mixed), [0.125 / 16, 1 / 16]);
});

test('blinkNow() starts closing at once and leaves a running blink alone', () => {
  const behavior = Live2DBehavior.create(makeParams(EYES), { random: () => 0 });
  behavior.setBlinkIds(['ParamEyeLOpen']);
  behavior.blinkNow();
  assert.deepEqual(Array.from(step(behavior, [1, 1], 37.5)), [0.25, 1]);
  behavior.blinkNow();
  assert.deepEqual(Array.from(step(behavior, [1, 1], 37.5)), [0, 1], 'not restarted');
});

test('blink writes nothing without blink IDs', () => {
  const behavior = Live2DBehavior.create(makeParams(EYES), { random: () => 0 });
  behavior.blinkNow();
  for (let t = 0; t < 10000; t += 25) {
    assert.deepEqual(Array.from(step(behavior, [1, 1], 25)), [1, 1]);
  }
});

test('setBlinkIds() and setMouthIds() reject unknown or repeated IDs, keeping the old list', () => {
  const behavior = Live2DBehavior.create(makeParams(EYES.concat(MOUTH)), { random: () => 0 });
  behavior.setBlinkIds(['ParamEyeLOpen']);
  behavior.setMouthIds(['ParamMouthOpenY']);
  for (const setIds of [behavior.setBlinkIds, behavior.setMouthIds]) {
    assert.throws(() => setIds(['ParamEyeROpen', 'ParamNope']), Error);
    assert.throws(() => setIds(['ParamEyeROpen', 'ParamEyeROpen']), Error);
    assert.throws(() => setIds('ParamEyeROpen'), TypeError);
  }
  behavior.blinkNow();
  behavior.speak([1], 50);
  const values = step(behavior, [1, 1, 0], 75);
  assert.deepEqual(Array.from(values.subarray(0, 2)), [0, 1], 'blink IDs unchanged');
  near(values[2], 1 - Math.exp(-0.25 * 0.075 * 60), 'mouth IDs unchanged');
});

test('focus adds x, y, 30x, 30y, -30xy and 10x to the incoming values', () => {
  // random() = 0: the first saccade comes after 800 ms and aims at (-0.5, -0.5).
  const behavior = Live2DBehavior.create(makeParams(FOCUS), { random: () => 0 });
  const values = run(behavior, [0, 0, 5, -5, 1, 2], 1000, 20);
  const x = values[0];
  const y = values[1];
  assert.ok(x < -0.05 && y < -0.05, 'the focus has moved toward the target');
  near(values[2], 5 + 30 * x);
  near(values[3], -5 + 30 * y);
  near(values[4], 1 - 30 * x * y);
  near(values[5], 2 + 10 * x);
});

test('focus eases to the sampled saccade target, and to the centre when not idle', () => {
  // Draws: blink delay, then bucket 0.9 and jitter 0.5 (first saccade at 4600 ms); 0.75
  // afterwards aims every saccade at (0.25, 0.1375) and spaces them 4700 ms apart.
  const random = sequence([0, 0.9, 0.5], 0.75);
  const behavior = Live2DBehavior.create(makeParams(FOCUS), { random: random });
  const zero = [0, 0, 0, 0, 0, 0];
  for (let t = 20; t < 4600; t += 20) {
    assert.deepEqual(Array.from(step(behavior, zero, 20)), zero, `no saccade at ${t} ms`);
  }
  const first = step(behavior, zero, 20);
  assert.ok(first[0] > 0 && first[0] < 0.05 && first[1] > 0, 'the saccade starts gradually');
  const settled = run(behavior, zero, 2000, 20);
  near(settled[0], 0.25, 'x', 0.011);
  near(settled[1], 0.1375, 'y', 0.011);
  const centred = run(behavior, zero, 2000, 20, { idle: false, driven: null });
  near(centred[0], 0, 'x', 0.011);
  near(centred[1], 0, 'y', 0.011);
});

test('no saccade starts while a non-idle motion plays', () => {
  const behavior = Live2DBehavior.create(makeParams(FOCUS), { random: () => 0 });
  const zero = [0, 0, 0, 0, 0, 0];
  const busy = { idle: false, driven: new Uint8Array(6) };
  for (let t = 0; t < 5000; t += 20) {
    assert.deepEqual(Array.from(step(behavior, zero, 20, busy)), zero);
  }
});

test('breath follows the airi curve: 0.5 at 0.8 s, 0 from 2 s, a new cycle at 3.2 s', () => {
  const behavior = Live2DBehavior.create(makeParams(BREATH), { random: () => 0 });
  const timeline = [[0, 0], [400, 0.25], [400, 0.5], [600, 0.25], [600, 0], [600, 0],
    [600, 0], [800, 0.5]];
  let time = 0;
  for (const [dt, expected] of timeline) {
    time += dt;
    near(step(behavior, [0.875], dt)[0], expected, `ParamBreath at ${time} ms`);
  }
});

test('breath leaves ParamBreath to a motion that drives it, while its clock runs on', () => {
  const behavior = Live2DBehavior.create(makeParams(BREATH), { random: () => 0 });
  const busy = { idle: false, driven: Uint8Array.of(1) };
  assert.equal(step(behavior, [0.875], 1600, busy)[0], 0.875);
  near(step(behavior, [0.875], 0)[0], 0.125, 'sampled at 1.6 s');
});

test('speak() eases the mouth toward each level with the Kokoro EMA from the next update', () => {
  const behavior = Live2DBehavior.create(makeParams(MOUTH), { random: () => 0 });
  behavior.setMouthIds(['ParamMouthOpenY']);
  behavior.speak([0, 1, 0.5], 50);
  assert.equal(step(behavior, [0], 1000)[0], 0, 'the first update plays level 0, whatever dt');
  const factor = 1 - Math.exp(-0.25 * 0.025 * 60); // 25 ms frames
  let level = 0;
  for (const target of [0, 1, 1, 0.5, 0.5]) {
    level += (target - level) * factor;
    near(step(behavior, [0], 25)[0], level);
  }
});

test('the mouth value is min + level * (max - min), or min + level without a maximum', () => {
  const factor = 1 - Math.exp(-0.25 * 0.1 * 60); // one 100 ms frame toward level 1
  const rows = [['ParamMouthOpenY', 0.5, 2.5, 0]];
  const cases = [[{}, 0.5 + 2 * factor], [{ max: false }, 0.5 + factor],
    [{ min: false, max: false }, factor]];
  for (const [ranges, expected] of cases) {
    const behavior = Live2DBehavior.create(makeParams(rows, ranges), { random: () => 0 });
    behavior.setMouthIds(['ParamMouthOpenY']);
    behavior.speak([1], 100);
    near(step(behavior, [0], 100)[0], expected, JSON.stringify(ranges));
  }
});

test('after the last level the mouth returns to the incoming value within 200 ms', () => {
  const behavior = Live2DBehavior.create(makeParams(MOUTH), { random: () => 0 });
  behavior.setMouthIds(['ParamMouthOpenY']);
  behavior.speak([1, 1], 50);
  step(behavior, [0.25], 50);
  const last = step(behavior, [0.25], 50)[0];
  // smoothstep(t) = 3t^2 - 2t^3, from the last written value to the incoming one.
  for (const [elapsed, blend] of [[50, 0.15625], [100, 0.5], [150, 0.84375]]) {
    near(step(behavior, [0.25], 50)[0], last * (1 - blend) + 0.25 * blend, `${elapsed} ms`);
  }
  assert.equal(step(behavior, [0.25], 50)[0], 0.25, 'released after 200 ms');
  assert.equal(step(behavior, [0.75], 50)[0], 0.75, 'nothing is written afterwards');
});

test('speak([]) stops the envelope and releases the mouth over 200 ms', () => {
  const behavior = Live2DBehavior.create(makeParams(MOUTH), { random: () => 0 });
  behavior.setMouthIds(['ParamMouthOpenY']);
  behavior.speak(new Array(100).fill(1), 20);
  step(behavior, [0], 100);
  const last = step(behavior, [0], 100)[0];
  behavior.speak([]);
  near(step(behavior, [0], 100)[0], last / 2, 'smoothstep(0.5) = 0.5');
  assert.equal(step(behavior, [0], 100)[0], 0);
  assert.equal(step(behavior, [0.5], 100)[0], 0.5);
});

test('speak() rejects bad levels or step sizes and keeps the current envelope', () => {
  const behavior = Live2DBehavior.create(makeParams(MOUTH), { random: () => 0 });
  behavior.setMouthIds(['ParamMouthOpenY']);
  behavior.speak([1, 1, 1], 100);
  const factor = 1 - Math.exp(-0.25 * 0.1 * 60);
  near(step(behavior, [0], 100)[0], factor);
  for (const levels of ['loud', null, { length: 1, 0: 1 }]) {
    assert.throws(() => behavior.speak(levels, 50), TypeError);
  }
  const badCalls = [[new Array(3001).fill(0), 50], [[0.5], 9], [[0.5], 101], [[0.5], 12.5],
    [[0.5], '50'], [[0.5]], [[NaN], 50], [[-0.25], 50], [[1.25], 50], [[Infinity], 50],
    [['0.5'], 50]];
  for (const args of badCalls) {
    assert.throws(() => behavior.speak(...args), RangeError, JSON.stringify(args));
  }
  near(step(behavior, [0], 100)[0], 1 - (1 - factor) * (1 - factor), 'the first envelope');
  assert.doesNotThrow(() => behavior.speak(new Array(3000).fill(0), 10));
  assert.doesNotThrow(() => behavior.speak(Float32Array.of(0, 1), 100));
  assert.doesNotThrow(() => behavior.speak([]));
});

test('update() clamps the parameters it wrote to [min, max] and leaves the others alone', () => {
  const rows = FOCUS.concat([['ParamOther', 0, 1, 0]]);
  const behavior = Live2DBehavior.create(makeParams(rows), { random: () => 0 }); // (-0.5, -0.5)
  const values = run(behavior, [-0.75, 0, -29, 0, 0, 0, 5], 3000, 20);
  assert.equal(values[0], -1, 'ParamEyeBallX: -0.75 - 0.5');
  assert.equal(values[2], -30, 'ParamAngleX: -29 - 15');
  assert.equal(values[6], 5, 'ParamOther is not written, so not clamped');
});

test('without range arrays blink and mouth use 0 as the minimum and nothing is clamped', () => {
  const rows = EYES.concat(MOUTH, FOCUS);
  const params = makeParams(rows, { min: false, max: false });
  const behavior = Live2DBehavior.create(params, { random: () => 0 });
  behavior.setBlinkIds(BOTH_EYES);
  behavior.setMouthIds(['ParamMouthOpenY']);
  behavior.blinkNow();
  behavior.speak([1], 100);
  const incoming = [2, 2, 0, 0, 0, 100, 0, 0, 0];
  const first = step(behavior, incoming, 37.5);
  assert.deepEqual(Array.from(first.subarray(0, 2)), [0.5, 0.5], 'eyes: 0 + 2 * 0.25');
  near(first[2], 1 - Math.exp(-0.25 * 0.0375 * 60), 'mouth: 0 + level');
  const later = run(behavior, incoming, 2000, 20);
  assert.equal(later[0], 2, 'an open eye above 1 stays');
  assert.ok(later[5] > 80 && later[5] < 90, 'ParamAngleX is 100 + 30x, not clamped');
});

test('nothing is written when the model has none of the parameters', () => {
  const params = makeParams([['ParamOther', 0, 1, 0.5]]);
  const behavior = Live2DBehavior.create(params, { random: () => 0 });
  behavior.setBlinkIds([]);
  behavior.setMouthIds([]);
  behavior.blinkNow();
  behavior.speak([1, 0.5, 1], 10);
  const busy = { idle: false, driven: Uint8Array.of(0) };
  for (let t = 0; t < 10000; t += 50) {
    assert.equal(step(behavior, [7], 50)[0], 7);
    assert.equal(step(behavior, [7], 50, busy)[0], 7);
  }
});

test('reset() drops the blink, centres the focus, stops speech and restarts the clocks', () => {
  const rows = EYES.concat(MOUTH, BREATH, FOCUS);
  const behavior = Live2DBehavior.create(makeParams(rows), { random: () => 0 });
  behavior.setBlinkIds(BOTH_EYES);
  behavior.setMouthIds(['ParamMouthOpenY']);
  const incoming = [1, 1, 0.25, 0.875, 0, 0, 0, 0, 0, 0];
  run(behavior, incoming, 1200, 20); // a saccade started at 800 ms
  behavior.blinkNow();
  behavior.speak([1, 1, 1], 100);
  step(behavior, incoming, 20);
  behavior.reset();
  assert.deepEqual(Array.from(step(behavior, incoming, 0)), [1, 1, 0.25, 0, 0, 0, 0, 0, 0, 0]);
  for (let t = 20; t < 800; t += 20) {
    const values = step(behavior, incoming, 20);
    assert.deepEqual(Array.from(values.subarray(0, 3)), [1, 1, 0.25], `${t} ms`);
    assert.deepEqual(Array.from(values.subarray(4)), [0, 0, 0, 0, 0, 0], `${t} ms`);
  }
  assert.notEqual(step(behavior, incoming, 20)[4], 0, 'the resampled saccade comes at 800 ms');
});
