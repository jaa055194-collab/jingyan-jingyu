'use strict';

// Tests for web/live2d_pose.js; run with: node --test test/pose.test.cjs
// The pose3 JSON here is synthetic (no Live2D sample data). The expected
// numbers are derived by hand from findings.md 2.6; the derivation is in the
// comment above each concrete assertion.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const FILE = path.join(__dirname, '..', 'web', 'live2d_pose.js');
const Live2DPose = require(FILE);

function near(actual, expected, message, tolerance) {
  const limit = tolerance === undefined ? 1e-9 : tolerance;
  assert.ok(Math.abs(actual - expected) < limit,
    (message || 'value') + ': ' + actual + ' != ' + expected);
}

function entry(id, links) {
  return { Id: id, Link: links || [] };
}

function poseJson(groups, fade) {
  const json = { Type: 'Live2D Pose', Groups: groups };
  if (fade !== undefined) { json.FadeInTime = fade; }
  return json;
}

// A two-entry group A, B; both are model parameters. Default fade 1.
function twoPose(fade) {
  return Live2DPose.create(Live2DPose.parse(poseJson([
    [entry('A'), entry('B')]
  ], fade)), ['A', 'B'], ['A', 'B']);
}

test('exports parse/create on module.exports and window.Live2DPose', () => {
  assert.equal(typeof Live2DPose.parse, 'function');
  assert.equal(typeof Live2DPose.create, 'function');
  assert.ok(Object.isFrozen(Live2DPose));
  const sandbox = { window: {} };
  vm.runInNewContext(fs.readFileSync(FILE, 'utf8'), sandbox, { filename: FILE });
  assert.equal(typeof sandbox.window.Live2DPose.parse, 'function');
  assert.equal(typeof sandbox.window.Live2DPose.create, 'function');
});

test('parse() defaults FadeInTime to 0.5, keeps non-negative values and rejects bad shapes', () => {
  assert.deepEqual(Live2DPose.parse({ Type: 'Live2D Pose' }),
    { fadeInTime: 0.5, groups: [] });
  assert.equal(Live2DPose.parse({ Type: 'Live2D Pose', FadeInTime: 2 }).fadeInTime, 2);
  assert.equal(Live2DPose.parse({ Type: 'Live2D Pose', FadeInTime: 0 }).fadeInTime, 0);
  assert.equal(Live2DPose.parse({ Type: 'Live2D Pose', FadeInTime: -1 }).fadeInTime, 0.5);
  const parsed = Live2DPose.parse(poseJson([
    [entry('A', ['A2']), entry('B')]
  ], 1));
  assert.deepEqual(parsed.groups, [[{ id: 'A', links: ['A2'] }, { id: 'B', links: [] }]]);
  const bad = [null, undefined, 3, 'x', [], { Type: 'Other' },
    { Groups: 'x' }, { Groups: [null] }, { Groups: [[{ Id: 5 }]] },
    { Groups: [[{ Id: 'A', Link: [1] }]] }, { FadeInTime: NaN },
    { FadeInTime: Infinity }, { FadeInTime: '1' }];
  for (let i = 0; i < bad.length; i++) {
    assert.equal(Live2DPose.parse(bad[i]), null, 'bad shape ' + String(bad[i]));
  }
});

test('reset() shows the first entry and copies its opacity to links', () => {
  const pose = Live2DPose.create(Live2DPose.parse(poseJson([
    [entry('A', ['A2']), entry('B', ['B2']), entry('C')]
  ])), ['A', 'A2', 'B', 'B2', 'C'], ['A', 'B', 'C']);
  const values = [0.5, 0.5, 0.5];
  const opacities = [0, 0, 0, 0, 0];
  pose.reset(values, opacities);
  assert.deepEqual(values, [1, 0, 0]);
  assert.deepEqual(opacities, [1, 1, 0, 0, 0]);
});

test('the first entry with a value above 0.001 is the visible one', () => {
  const pose = twoPose(1);
  let values = [0.001, 0.5];
  let opacities = [1, 0];
  pose.evaluate(values, opacities, 0.5);
  near(opacities[1], 0.5, 'B fades in from 0');
  near(opacities[0], 0.7, 'A is capped by the 0.15 back rule');

  pose.reset(values, opacities);
  values = [0.0011, 0.5];
  opacities = [1, 0];
  pose.evaluate(values, opacities, 0.5);
  assert.equal(opacities[0], 1, 'A is visible');
  assert.equal(opacities[1], 0, 'B stays at 0');
});

test('the visible part fades in by dt / FadeInTime', () => {
  const pose = twoPose(1);
  const values = [0, 1];
  const opacities = [1, 0];
  // B fades in 0.25 per step; A is the back part, capped by the 0.15 rule:
  // newOpacity 0.25 -> 0.8, 0.5 -> 0.7, 0.75 -> 0.4, 1 -> 0.
  const expected = [[0.8, 0.25], [0.7, 0.5], [0.4, 0.75], [0, 1]];
  for (let i = 0; i < expected.length; i++) {
    pose.evaluate(values, opacities, 0.25);
    near(opacities[0], expected[i][0], 'A step ' + i);
    near(opacities[1], expected[i][1], 'B step ' + i);
  }
});

test('FadeInTime 0 makes the visible part fully visible at once', () => {
  const pose = twoPose(0);
  const values = [0, 1];
  const opacities = [1, 0];
  pose.evaluate(values, opacities, 0);
  assert.equal(opacities[1], 1);
  assert.equal(opacities[0], 0);
});

test('the back part is capped so at most 0.15 of it shows through', () => {
  // newOpacity 0.2 leaves the uncapped back target 0.8 and a back opacity of
  // 0.16; the cap makes it 1 - 0.15 / 0.8 = 0.8125 (back exactly 0.15).
  const pose = twoPose(1);
  const values = [0, 1];
  const opacities = [1, 0];
  pose.evaluate(values, opacities, 0.2);
  near(opacities[1], 0.2);
  near(opacities[0], 0.8125);
  near((1 - opacities[0]) * (1 - opacities[1]), 0.15, 'back opacity');
});

test('a non-visible part is only ever lowered, never raised', () => {
  const pose = twoPose(1);
  const values = [0, 1];
  const opacities = [0.1, 0];
  pose.evaluate(values, opacities, 0.2);
  near(opacities[1], 0.2);
  assert.equal(opacities[0], 0.1, '0.1 is below the 0.8125 target, so it stays');
});

test('links copy their entry opacity after each group update', () => {
  const pose = Live2DPose.create(Live2DPose.parse(poseJson([
    [entry('A', ['A2', 'A3']), entry('B')]
  ], 1)), ['A', 'A2', 'A3', 'B'], ['A', 'B']);
  const values = [0, 1];
  const opacities = [1, 0, 0, 0];
  pose.evaluate(values, opacities, 0.25);
  near(opacities[0], 0.8);
  near(opacities[1], 0.8);
  near(opacities[2], 0.8);
  near(opacities[3], 0.25);
});

test('extraParams holds part-id parameters missing from the model', () => {
  const pose = Live2DPose.create(Live2DPose.parse(poseJson([
    [entry('A'), entry('B')]
  ], 1)), ['A', 'B'], []);
  assert.deepEqual(Object.keys(pose.extraParams).sort(), ['A', 'B']);
  const values = [];
  const opacities = [0, 0];
  pose.reset(values, opacities);
  assert.equal(pose.extraParams.A, 1);
  assert.equal(pose.extraParams.B, 0);
  assert.deepEqual(opacities, [1, 0]);
  pose.extraParams.A = 0;
  pose.extraParams.B = 1;
  pose.evaluate(values, opacities, 0.25);
  near(opacities[1], 0.25, 'B fades in from extraParams');
  near(opacities[0], 0.8, 'A is the back part');
});

test('a part that is a model parameter uses values, not extraParams', () => {
  const pose = Live2DPose.create(Live2DPose.parse(poseJson([
    [entry('A'), entry('B')]
  ], 1)), ['A', 'B'], ['A', 'B']);
  assert.equal(Object.keys(pose.extraParams).length, 0);
  const values = [0, 0];
  const opacities = [0, 0];
  pose.reset(values, opacities);
  assert.deepEqual(values, [1, 0]);
  assert.deepEqual(opacities, [1, 0]);
  values[0] = 0;
  values[1] = 1;
  pose.evaluate(values, opacities, 0.25);
  near(opacities[1], 0.25, 'B is visible from values');
});

test('entries and links whose part id is not in partIds are dropped', () => {
  const pose = Live2DPose.create(Live2DPose.parse(poseJson([
    [entry('NOPE'), entry('A', ['NOPE2', 'A2']), entry('B')]
  ])), ['A', 'A2', 'B'], ['A', 'B']);
  const values = [0, 0];
  const opacities = [0, 0, 0];
  pose.reset(values, opacities);
  // NOPE is dropped, so A is the first entry: param 1 and opacity 1.
  assert.equal(values[0], 1);
  assert.equal(opacities[0], 1);
  assert.equal(opacities[1], 1, 'A2 link copied from A');
  assert.equal(values[1], 0);
  assert.equal(opacities[2], 0);
});

test('a group whose entries are all unknown is ignored', () => {
  const pose = Live2DPose.create(Live2DPose.parse(poseJson([
    [entry('NOPE')], [entry('A')]
  ])), ['A'], ['A']);
  const values = [0];
  const opacities = [0];
  pose.reset(values, opacities);
  assert.equal(values[0], 1);
  assert.equal(opacities[0], 1);
});

test('with no visible part the first entry is shown at full opacity', () => {
  const pose = twoPose(1);
  const values = [0, 0];
  const opacities = [0.2, 0.2];
  pose.evaluate(values, opacities, 0.5);
  assert.equal(opacities[0], 1, 'the first entry is forced to 1');
  assert.equal(opacities[1], 0, 'the other entry is lowered to 0');
});
