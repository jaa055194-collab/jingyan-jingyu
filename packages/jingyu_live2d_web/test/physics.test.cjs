'use strict';

// Tests for web/live2d_physics.js; run with: node --test test/physics.test.cjs
// The physics3 JSON here is synthetic (no Live2D sample data). The expected
// numbers are derived by hand from findings.md 2.2-2.5; the derivation is in
// the comment above each concrete assertion.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const FILE = path.join(__dirname, '..', 'web', 'live2d_physics.js');
const Live2DPhysics = require(FILE);
const PI = Math.PI;

function near(actual, expected, message, tolerance) {
  const limit = tolerance === undefined ? 1e-6 : tolerance;
  assert.ok(Math.abs(actual - expected) < limit,
    (message || 'value') + ': ' + actual + ' != ' + expected);
}

function vertex(radius, options) {
  const o = options || {};
  return {
    Position: { X: 0, Y: 0 },
    Mobility: o.mobility === undefined ? 1 : o.mobility,
    Delay: o.delay === undefined ? 0 : o.delay,
    Acceleration: o.acceleration === undefined ? 1 : o.acceleration,
    Radius: radius
  };
}

function norm(minimum, def, maximum) {
  return { Minimum: minimum, Default: def, Maximum: maximum };
}

function input(id, type, weight, reflect) {
  return {
    Source: { Target: 'Parameter', Id: id },
    Weight: weight === undefined ? 100 : weight,
    Type: type,
    Reflect: reflect === true
  };
}

function output(id, vertexIndex, type, options) {
  const o = options || {};
  return {
    Destination: { Target: 'Parameter', Id: id },
    VertexIndex: vertexIndex,
    Scale: o.scale === undefined ? 1 : o.scale,
    Weight: o.weight === undefined ? 100 : o.weight,
    Type: type,
    Reflect: o.reflect === true
  };
}

function setting(options) {
  const o = options || {};
  return {
    Id: o.id || 'S',
    Input: o.inputs || [],
    Output: o.outputs || [],
    Vertices: o.vertices || [vertex(1), vertex(1)],
    Normalization: {
      Position: o.position || norm(-1, 0, 1),
      Angle: o.angle || norm(-30, 0, 30)
    }
  };
}

function physicsJson(settings, meta) {
  return {
    Version: 3,
    Meta: meta || { PhysicsSettingCount: settings.length },
    PhysicsSettings: settings
  };
}

// One setting: an Angle input PA tilts the strand; an X output writes PX.
// PA range [-30, 30] (default 0), PX range [-1, 1] (default 0).
function tiltJson(options) {
  const o = options || {};
  return physicsJson([
    setting({
      inputs: [input('PA', 'Angle', 100, true)],
      outputs: [output('PX', 1, 'X', { weight: o.weight })],
      vertices: [vertex(1), vertex(1)]
    })
  ], { PhysicsSettingCount: 1, Fps: o.fps || 0 });
}

function tiltPhysics(options) {
  const rig = Live2DPhysics.parse(tiltJson(options));
  return Live2DPhysics.create(rig, ['PA', 'PX'], [-30, -1], [30, 1], [0, 0]);
}

// The strand starts vertical at (0, 0), (0, 1). On the first step gravity is
// at -angle (the input is reflected) so the direction is rotated by -angle/5:
//   r = -a/5, dx = -sin(r), dy = sin(r) * dx + cos(r)  (the rotated-x quirk)
// and the root-to-vertex segment is (dx, dy) normalised times the radius (1).
// The X output is therefore dx / hypot(dx, dy). For a = 30 deg this is
// 0.10567671318818914; for a = 0 it is 0.
const X_30 = 0.10567671318818914;
// Changing the input from 30 to 0 also changes gravity, so the strand turns
// back by 6 deg on the next step instead of snapping to vertical:
// 0.0011673993138701247. A half step between the two outputs is their mean.
const X_BACK = 0.0011673993138701247;
const X_HALF_STEP = 0.053422056251029616;

test('exports parse/create/helpers on module.exports and window.Live2DPhysics', () => {
  assert.equal(typeof Live2DPhysics.parse, 'function');
  assert.equal(typeof Live2DPhysics.create, 'function');
  assert.equal(typeof Live2DPhysics.normalizeParameter, 'function');
  assert.equal(typeof Live2DPhysics.directionToRadian, 'function');
  assert.ok(Object.isFrozen(Live2DPhysics));
  const sandbox = { window: {} };
  vm.runInNewContext(fs.readFileSync(FILE, 'utf8'), sandbox, { filename: FILE });
  assert.equal(typeof sandbox.window.Live2DPhysics.parse, 'function');
  assert.equal(typeof sandbox.window.Live2DPhysics.create, 'function');
  assert.equal(typeof sandbox.window.Live2DPhysics.normalizeParameter, 'function');
});

test('normalizeParameter maps both sides and negates unless Reflect', () => {
  const param = { minimum: -1, maximum: 1, default: 0 };
  const normalized = { minimum: -1, maximum: 1, default: 0 };
  // middle = 0; +1 -> +1 -> negated; -1 -> -1 -> negated to +1; 0 -> default.
  assert.equal(Live2DPhysics.normalizeParameter(1, param, normalized, false), -1);
  assert.equal(Live2DPhysics.normalizeParameter(-1, param, normalized, false), 1);
  assert.equal(Live2DPhysics.normalizeParameter(0, param, normalized, false), 0);
  assert.equal(Live2DPhysics.normalizeParameter(1, param, normalized, true), 1);
  assert.equal(Live2DPhysics.normalizeParameter(-1, param, normalized, true), -1);
  // Values are clamped to the parameter range first.
  assert.equal(Live2DPhysics.normalizeParameter(2, param, normalized, true), 1);
  assert.equal(Live2DPhysics.normalizeParameter(-2, param, normalized, true), -1);
});

test('normalizeParameter returns 0 when the normalized side has zero length', () => {
  const param = { minimum: -10, maximum: 10, default: 0 };
  const flat = { minimum: 0, maximum: 0, default: 0 };
  assert.equal(Live2DPhysics.normalizeParameter(1, param, flat, false), 0);
  assert.equal(Live2DPhysics.normalizeParameter(-1, param, flat, false), 0);
  assert.equal(Live2DPhysics.normalizeParameter(1, param, flat, true), 0);
});

test('normalizeParameter splits at the parameter midpoint and maps to the normalized default', () => {
  // parameter [0, 10] -> middle 5; normalization [-1, 1] with default 0.5.
  // 7.5: +2.5 * (1 - 0.5) / (10 - 5) + 0.5 = 0.75, negated -> -0.75.
  // 2.5: -2.5 * (-1 - 0.5) / (0 - 5) + 0.5 = -0.25, negated -> 0.25.
  // 5:   exactly the middle -> default 0.5, negated -> -0.5.
  const param = { minimum: 0, maximum: 10, default: 0 };
  const normalized = { minimum: -1, maximum: 1, default: 0.5 };
  near(Live2DPhysics.normalizeParameter(7.5, param, normalized, false), -0.75);
  near(Live2DPhysics.normalizeParameter(2.5, param, normalized, false), 0.25);
  near(Live2DPhysics.normalizeParameter(5, param, normalized, false), -0.5);
});

test('directionToRadian returns the signed angle and wraps into [-PI, PI]', () => {
  const down = { x: 0, y: 1 };
  const right = { x: 1, y: 0 };
  near(Live2DPhysics.directionToRadian(down, right), -PI / 2);
  near(Live2DPhysics.directionToRadian(right, down), PI / 2);
  // (-1, 0) is PI; (1, -1) is -PI/4; PI/4 - PI = -5PI/4 wraps to +3PI/4.
  near(Live2DPhysics.directionToRadian({ x: -1, y: 0 }, { x: 1, y: -1 }), 3 * PI / 4);
  near(Live2DPhysics.directionToRadian({ x: 1, y: -1 }, { x: -1, y: 0 }), -3 * PI / 4);
  near(Live2DPhysics.directionToRadian(down, { x: 0, y: 2 }), 0);
});

test('without Fps the output lags one frame', () => {
  const phys = tiltPhysics();
  const values = Float64Array.from([30, 0]);
  phys.evaluate(values, 1 / 30);
  assert.equal(values[1], 0, 'the first frame writes the previous (zero) output');
  phys.evaluate(values, 1 / 30);
  near(values[1], X_30, 'the second frame writes the first frame output');
  phys.evaluate(values, 1 / 30);
  near(values[1], X_30, 'the output is stable afterwards');
});

test('with Fps the outputs interpolate by the remaining fraction of a step', () => {
  const phys = tiltPhysics({ fps: 30 });
  const h = 1 / 30;
  const values = Float64Array.from([30, 0]);
  phys.evaluate(values, h); // one step, alpha 0 -> writes 0
  assert.equal(values[1], 0);
  values[0] = 0; // change the input; the next full step turns the strand back
  phys.evaluate(values, h); // previous = X_30, current = X_BACK, alpha 0
  near(values[1], X_30);
  phys.evaluate(values, h / 2); // no step: alpha 0.5, previous X_30, current X_BACK
  near(values[1], X_HALF_STEP, 'the mean of the previous and current outputs');
  phys.evaluate(values, h / 2); // the pending half step runs
  near(values[1], X_BACK, 'the output catches up');
});

test('remain above 5 s is discarded, so no step runs', () => {
  const phys = tiltPhysics({ fps: 30 });
  const values = Float64Array.from([30, 0]);
  phys.evaluate(values, 5); // 5 s is not above the cap: 150 steps run
  near(values[1], X_30);
  phys.reset();
  const dropped = Float64Array.from([30, 0]);
  phys.evaluate(dropped, 6); // 6 s > 5 s: remain is reset, nothing runs
  assert.equal(dropped[1], 0);
});

test('output weight blends into the existing parameter value', () => {
  // stabilize makes the raw X output 0.5 (the strand hangs at 30 deg).
  // PX starts at 0.8; the write is 0.8 * (1 - w) + 0.5 * w.
  const cases = [[100, 0.5], [50, 0.65], [0, 0.8]];
  for (let i = 0; i < cases.length; i++) {
    const phys = tiltPhysics({ weight: cases[i][0] });
    const values = Float64Array.from([30, 0.8]);
    phys.stabilize(values);
    near(values[1], cases[i][1], 'weight ' + cases[i][0]);
  }
});

test('chained settings see the earlier setting output in the same step', () => {
  // A: Angle PA -> X P1. With PA 30 the first step turns the strand by 6 deg,
  // so P1 = X_30 = 0.10567671318818914 (after the one-frame lag).
  // B: Angle P1 -> X P2. P1 is in [-1, 1] and the angle normalization is
  // [-30, 30], so P1 maps to P1 * 30 = 3.1703013956456743 deg; the same
  // first-step rotation gives P2 = 0.011067568914540579. If B read the old P1
  // (zero) instead of A's output in the cache, P2 would be 0.
  const json = physicsJson([
    setting({
      id: 'A',
      inputs: [input('PA', 'Angle', 100, true)],
      outputs: [output('P1', 1, 'X')]
    }),
    setting({
      id: 'B',
      inputs: [input('P1', 'Angle', 100, true)],
      outputs: [output('P2', 1, 'X')]
    })
  ], { PhysicsSettingCount: 2 });
  const rig = Live2DPhysics.parse(json);
  const phys = Live2DPhysics.create(rig, ['PA', 'P1', 'P2'],
    [-30, -1, -1], [30, 1, 1], [0, 0, 0]);
  const values = Float64Array.from([30, 0, 0]);
  phys.evaluate(values, 1 / 30);
  phys.evaluate(values, 1 / 30);
  near(values[1], X_30, 'P1');
  near(values[2], 0.011067568914540579, 'P2 follows P1 in the same step');
});

test('stabilize() hangs the strand along gravity, removing the first-frame swing', () => {
  const phys = tiltPhysics();
  const stable = Float64Array.from([30, 0]);
  phys.stabilize(stable);
  near(stable[1], 0.5, 'at rest along gravity: X = sin(30 deg)');
  phys.reset();
  const swinging = Float64Array.from([30, 0]);
  phys.evaluate(swinging, 1 / 30);
  phys.evaluate(swinging, 1 / 30);
  near(swinging[1], X_30, 'without stabilize the first frame turns by angle/5');
});

test('setOptions() changes gravity (angle parent) and wind (particle force)', () => {
  // An Angle output at vertex 1 uses -gravity as its parent. With no inputs the
  // strand is vertical (0, 1), so the default gravity (0, -1) gives 0; gravity
  // (1, 0) gives directionToRadian((-1, 0), (0, 1)) = -PI/2.
  const angleJson = physicsJson([setting({
    inputs: [],
    outputs: [output('PA', 1, 'Angle')],
    vertices: [vertex(1), vertex(1)],
    position: norm(-1, 0, 1),
    angle: norm(-10, 0, 10)
  })]);
  const anglePhys = Live2DPhysics.create(Live2DPhysics.parse(angleJson),
    ['PA'], [-10], [10], [0]);
  const plain = Float64Array.from([0]);
  anglePhys.evaluate(plain, 1 / 30);
  anglePhys.evaluate(plain, 1 / 30);
  near(plain[0], 0, 'default gravity');
  anglePhys.reset();
  anglePhys.setOptions({ gravity: { x: 1, y: 0 } });
  const turned = Float64Array.from([0]);
  anglePhys.evaluate(turned, 1 / 30);
  anglePhys.evaluate(turned, 1 / 30);
  near(turned[0], -PI / 2, 'gravity (1, 0)');

  // With acceleration 0, delay 1 and dt 1/30 the force term is wind * 1.
  // Wind (1, 0): position becomes (1, 1), normalised to (1, 1)/sqrt(2), and
  // the Y output is 1/sqrt(2) = 0.7071067811865476. Without wind it is 1.
  function windPhysics(wind) {
    const json = physicsJson([setting({
      inputs: [],
      outputs: [output('PY', 1, 'Y')],
      vertices: [vertex(1, { acceleration: 0 }),
        vertex(1, { acceleration: 0, delay: 1, mobility: 1 })],
      position: norm(-1, 0, 1),
      angle: norm(-10, 0, 10)
    })]);
    const phys = Live2DPhysics.create(Live2DPhysics.parse(json),
      ['PY'], [-1], [1], [0]);
    phys.setOptions({ wind: wind });
    return phys;
  }
  const calm = windPhysics({ x: 0, y: 0 });
  const calmValues = Float64Array.from([0]);
  calm.evaluate(calmValues, 1 / 30);
  calm.evaluate(calmValues, 1 / 30);
  near(calmValues[0], 1, 'no wind');
  const windy = windPhysics({ x: 1, y: 0 });
  const windyValues = Float64Array.from([0]);
  windy.evaluate(windyValues, 1 / 30);
  windy.evaluate(windyValues, 1 / 30);
  near(windyValues[0], 1 / Math.sqrt(2), 'wind pushes the vertex to (1, 1)');
});

test('create() drops unknown ids and skips settings with no usable output', () => {
  const json = physicsJson([
    setting({
      id: 'A',
      inputs: [input('PA', 'Angle', 100, true)],
      outputs: [output('PX', 1, 'X')]
    }),
    setting({
      id: 'B',
      inputs: [input('NOPE', 'X')],
      outputs: [output('NOPE2', 1, 'X')]
    }),
    setting({
      id: 'C',
      inputs: [input('NOPE', 'X')],
      outputs: [output('PY', 1, 'Y')]
    })
  ]);
  const rig = Live2DPhysics.parse(json);
  const phys = Live2DPhysics.create(rig, ['PA', 'PX', 'PY'],
    [-30, -1, -1], [30, 1, 1], [0, 0, 0]);
  const values = Float64Array.from([30, 0, 0]);
  phys.evaluate(values, 1 / 30);
  phys.evaluate(values, 1 / 30);
  near(values[1], X_30, 'PX from the kept setting');
  near(values[2], 1, 'a setting with only a dropped input still runs at rest');

  const onlyUnknown = physicsJson([setting({
    inputs: [input('PA', 'Angle', 100, true)],
    outputs: [output('NOPE', 1, 'X')]
  })]);
  const skipped = Live2DPhysics.create(Live2DPhysics.parse(onlyUnknown),
    ['PA', 'PX'], [-30, -1], [30, 1], [0, 0]);
  const untouched = Float64Array.from([30, 0.5]);
  skipped.evaluate(untouched, 1 / 30);
  skipped.evaluate(untouched, 1 / 30);
  assert.equal(untouched[1], 0.5, 'a setting whose only output is dropped is skipped');
});

test('parse() returns null for wrong shapes and non-finite numbers without throwing', () => {
  const good = tiltJson();
  assert.ok(Live2DPhysics.parse(good));
  const badShapes = [null, undefined, 3, 'x', [], {}, { PhysicsSettings: [] },
    { PhysicsSettings: {} }, { PhysicsSettings: [null] }, { PhysicsSettings: [{}] }];
  for (let i = 0; i < badShapes.length; i++) {
    assert.equal(Live2DPhysics.parse(badShapes[i]), null,
      'bad shape ' + String(badShapes[i]));
  }
  const cases = [
    function (json) { json.Version = 4; },
    function (json) { json.PhysicsSettings[0].Input[0].Weight = NaN; },
    function (json) { json.PhysicsSettings[0].Output[0].Scale = Infinity; },
    function (json) { json.PhysicsSettings[0].Vertices[1].Radius = NaN; },
    function (json) { json.PhysicsSettings[0].Normalization.Position.Default = Infinity; },
    function (json) { json.PhysicsSettings[0].Output[0].VertexIndex = 1.5; },
    function (json) { json.PhysicsSettings[0].Output[0].Type = 'Z'; },
    function (json) { json.PhysicsSettings[0].Input[0].Source.Target = 'Other'; }
  ];
  for (let i = 0; i < cases.length; i++) {
    const json = structuredClone(good);
    cases[i](json);
    assert.equal(Live2DPhysics.parse(json), null, 'case ' + i);
  }
});
