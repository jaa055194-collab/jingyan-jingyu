const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const Live2DMotion = require(path.join(
  __dirname, '..', 'web', 'live2d_motion.js'));

const Priority = Live2DMotion.Priority;

function parse(meta, curves, overrides) {
  return Live2DMotion.parseMotion({ Meta: meta, Curves: curves }, overrides);
}

function constant(id, value, target, extra) {
  return Object.assign({
    Target: target || 'Parameter',
    Id: id,
    Segments: [0, value]
  }, extra);
}

function resolver(parameters, parts, blinks, mouths) {
  return {
    parameterIndex: id => Object.prototype.hasOwnProperty.call(parameters, id) ?
      parameters[id] : -1,
    partIndex: id => Object.prototype.hasOwnProperty.call(parts || {}, id) ?
      parts[id] : -1,
    blinkIndices: () => blinks || [],
    mouthIndices: () => mouths || []
  };
}

function near(actual, expected, label) {
  assert.ok(Math.abs(actual - expected) < 1e-6,
    (label || 'value') + ': ' + actual + ' != ' + expected);
}

function cubic(a, b, c, d, u) {
  const q = 1 - u;
  return q * q * q * a + 3 * q * q * u * b + 3 * q * u * u * c + u * u * u * d;
}

function referenceBezier(t) {
  let low = 0;
  let high = 1;
  for (let i = 0; i < 60; i++) {
    const mid = (low + high) / 2;
    if (cubic(0, 0.5, 0.5, 1, mid) < t) {
      low = mid;
    } else {
      high = mid;
    }
  }
  return cubic(0, 0, 10, 1, (low + high) / 2);
}

test('all segment types and values outside the point range', () => {
  const motion = parse(
    { Duration: 6, AreBeziersRestricted: true },
    [constant('P', 0, 'Parameter', {
      Segments: [
        0, 0,
        0, 2, 2,
        1, 2, 2, 3, 2, 4, 8,
        2, 5, 8,
        3, 6, 20
      ]
    })]
  );
  const curve = motion.curves[0];
  near(Live2DMotion.evaluateCurve(curve, -1), 0, 'before first');
  near(Live2DMotion.evaluateCurve(curve, 1), 1, 'linear');
  near(Live2DMotion.evaluateCurve(curve, 3), 2.75, 'restricted bezier');
  near(Live2DMotion.evaluateCurve(curve, 4.5), 8, 'stepped');
  near(Live2DMotion.evaluateCurve(curve, 5), 8, 'stepped end');
  near(Live2DMotion.evaluateCurve(curve, 5.5), 20, 'inverse stepped');
  near(Live2DMotion.evaluateCurve(curve, 99), 20, 'after last');
});

test('unrestricted bezier solves time instead of using time fraction', () => {
  const segments = [0, 0, 1, 0.5, 0, 0.5, 10, 1, 1];
  const unrestricted = parse(
    { Duration: 1, AreBeziersRestricted: false },
    [constant('P', 0, 'Parameter', { Segments: segments })]
  );
  const restricted = parse(
    { Duration: 1, AreBeziersRestricted: true },
    [constant('P', 0, 'Parameter', { Segments: segments })]
  );
  for (const t of [0.2, 0.5, 0.8]) {
    near(Live2DMotion.evaluateCurve(unrestricted.curves[0], t),
      referenceBezier(t), 'unrestricted at ' + t);
  }
  assert.notEqual(
    Live2DMotion.evaluateCurve(unrestricted.curves[0], 0.2),
    Live2DMotion.evaluateCurve(restricted.curves[0], 0.2)
  );
});

test('motion fades honour overrides, Meta and per-curve values', () => {
  const basic = parse(
    { Duration: 2, Loop: true, FadeInTime: 0.2, FadeOutTime: 0.3 },
    [constant('P', 1)]
  );
  assert.equal(basic.duration, 2);
  assert.equal(basic.loop, true);
  assert.equal(basic.fadeIn, 0.2);
  assert.equal(basic.fadeOut, 0.3);

  const overridden = parse(
    { Duration: 2, FadeInTime: 5, FadeOutTime: -1 },
    [constant('P', 1)],
    { fadeIn: 0, fadeOut: 0.75 }
  );
  assert.equal(overridden.fadeIn, 0);
  assert.equal(overridden.fadeOut, 0.75);
  assert.throws(() => parse({ Duration: 1 }, [], { fadeIn: -1 }));
  assert.throws(() => parse({ Duration: 1 }, [], { fadeOut: NaN }));

  const mixed = parse(
    { Duration: 1, FadeInTime: 0.4, FadeOutTime: 0.6 },
    [
      constant('Eye', 1, 'Model', { FadeInTime: 0, FadeOutTime: 2 }),
      constant('P', 1, 'Parameter', { FadeInTime: -1, FadeOutTime: 0.25 })
    ]
  );
  assert.equal(mixed.curves[0].fadeIn, 0);
  assert.equal(mixed.curves[0].fadeOut, 2);
  assert.equal(mixed.curves[1].fadeIn, null);
  assert.equal(mixed.curves[1].fadeOut, 0.25);
  assert.equal(parse({ Duration: 1 }, [constant('P', 1)]).fadeOut, 1);
});

test('malformed motion input and both caps throw', () => {
  const good = () => constant('P', 1);
  assert.throws(() => Live2DMotion.parseMotion(null));
  assert.throws(() => Live2DMotion.parseMotion([]));
  assert.throws(() => Live2DMotion.parseMotion({ Curves: [] }));
  assert.throws(() => Live2DMotion.parseMotion({ Meta: {}, Curves: [] }));
  assert.throws(() => parse({ Duration: NaN }, []));
  assert.throws(() => parse({ Duration: -1 }, []));
  assert.throws(() => parse({ Duration: 1 }, null));
  assert.throws(() => parse({ Duration: 1 }, [constant('P', 1, 'Other')]));
  assert.throws(() => parse({ Duration: 1 }, [constant('', 1)]));
  assert.throws(() => parse({ Duration: 1 }, [constant('P', 1, 'Parameter', {
    Segments: [0]
  })]));
  assert.throws(() => parse({ Duration: 1 }, [constant('P', 1, 'Parameter', {
    Segments: [0, 0, 9, 1]
  })]));
  assert.throws(() => parse({ Duration: 1 }, [constant('P', 1, 'Parameter', {
    Segments: [0, 0, 1, 1, 2]
  })]));
  assert.throws(() => parse({ Duration: 1 }, [constant('P', 1, 'Parameter', {
    Segments: [0, 0, 0, 1, 0, -1, 2]
  })]));
  assert.throws(() => parse({ Duration: 1 }, [constant('P', 1, 'Parameter', {
    Segments: [0, Infinity, 0, 1]
  })]));

  const many = { Meta: { Duration: 1 }, Curves: [] };
  for (let i = 0; i < 4097; i++) {
    many.Curves.push(good());
  }
  assert.throws(() => Live2DMotion.parseMotion(many));
  many.Curves.pop();
  assert.equal(Live2DMotion.parseMotion(many).curves.length, 4096);

  const huge = { Meta: { Duration: 1 }, Curves: [constant('P', 0, 'Parameter', {
    Segments: new Array(1000001).fill(0)
  })] };
  assert.throws(() => Live2DMotion.parseMotion(huge));
});

test('expression parsing and malformed input', () => {
  const expression = Live2DMotion.parseExpression({
    Type: 'Live2D Expression',
    FadeInTime: 0,
    FadeOutTime: -2,
    Parameters: [{ Id: 'P', Value: 3 }]
  });
  assert.deepEqual(expression, {
    fadeIn: 0,
    fadeOut: 1,
    parameters: [{ id: 'P', value: 3, blend: 'Add' }]
  });
  assert.throws(() => Live2DMotion.parseExpression(null));
  assert.throws(() => Live2DMotion.parseExpression({ Parameters: {} }));
  assert.throws(() => Live2DMotion.parseExpression({
    Type: 'Other', Parameters: []
  }));
  assert.throws(() => Live2DMotion.parseExpression({
    Parameters: [{ Id: '', Value: 1 }]
  }));
  assert.throws(() => Live2DMotion.parseExpression({
    Parameters: [{ Id: 'P', Value: Infinity }]
  }));
  assert.throws(() => Live2DMotion.parseExpression({
    Parameters: [{ Id: 'P', Value: 1, Blend: 'Bad' }]
  }));
  assert.throws(() => Live2DMotion.parseExpression({
    Parameters: new Array(4097).fill({ Id: 'P', Value: 1 })
  }));
});

function frame(queue, initial, now, driven) {
  const values = [initial];
  queue.update(values, [], now, driven === undefined ? null : driven);
  return values;
}

test('sine fades, curve fade overrides, loop and non-loop endings', () => {
  const r = resolver({ P: 0 });
  const queue = Live2DMotion.createMotionQueue(r);
  const motion = parse(
    { Duration: 1, FadeInTime: 1, FadeOutTime: 0.5 },
    [constant('P', 1)]
  );
  assert.equal(queue.start(motion, 0, Priority.NORMAL), true);
  near(frame(queue, 0, 0.5)[0], 0.5, 'sine half fade-in');
  near(frame(queue, 0, 0.75)[0],
    (0.5 - 0.5 * Math.cos(Math.PI * 0.75)) * 0.5, 'combined sine fades');
  assert.equal(frame(queue, 0, 1)[0], 0, 'non-loop ended');
  assert.equal(queue.isFinished(), true);
  assert.equal(queue.currentPriority(), Priority.NONE);

  const loop = parse(
    { Duration: 1, Loop: true, FadeInTime: 0 },
    [constant('P', 0, 'Parameter', { Segments: [0, 0, 0, 1, 1, 0, 2, 4] })]
  );
  const loopQueue = Live2DMotion.createMotionQueue(r);
  loopQueue.start(loop, 0, Priority.NORMAL);
  near(frame(loopQueue, 0, 2.5)[0], 0.5, 'looped local time');
  assert.equal(loopQueue.isFinished(), false);
  assert.equal(loopQueue.currentPriority(), Priority.NORMAL);

  const curveFades = parse(
    { Duration: 2, FadeInTime: 1, FadeOutTime: 0.5 },
    [constant('P', 1, 'Parameter', { FadeInTime: 0, FadeOutTime: 1 })]
  );
  const curveQueue = Live2DMotion.createMotionQueue(r);
  curveQueue.start(curveFades, 0, Priority.NORMAL);
  near(frame(curveQueue, 0, 0.5)[0], 1, 'curve fade-in wins');
  near(frame(curveQueue, 0, 1.5)[0], 0.5, 'curve fade-out wins');
});

test('a new motion starts the old one fading out', () => {
  const queue = Live2DMotion.createMotionQueue(resolver({ P: 0 }));
  const motion = parse(
    { Duration: 10, Loop: true, FadeInTime: 1, FadeOutTime: 1 },
    [constant('P', 1)]
  );
  assert.equal(queue.start(motion, 0, Priority.NORMAL), true);
  assert.equal(queue.currentPriority(), Priority.NORMAL);
  assert.equal(queue.start(motion, 1, Priority.NORMAL), true);
  near(frame(queue, 0, 1.5)[0], 0.75, 'both entries weighted');
  near(frame(queue, 0, 2)[0], 1, 'old entry dropped');
  assert.equal(queue.currentPriority(), Priority.NORMAL);
});

test('start priority rules and IDLE after finish', () => {
  const queue = Live2DMotion.createMotionQueue(resolver({ P: 0 }));
  const motion = parse(
    { Duration: 1, FadeInTime: 0, FadeOutTime: 0 },
    [constant('P', 1)]
  );
  assert.equal(queue.start(motion, 0, Priority.NORMAL), true);
  assert.equal(queue.start(motion, 0, Priority.IDLE), false);
  assert.equal(queue.start(motion, 0, Priority.NORMAL), true);
  assert.equal(queue.start(motion, 0, Priority.FORCE), true);
  queue.update([0], [], 1, null);
  assert.equal(queue.isFinished(), true);
  assert.equal(queue.start(motion, 1, Priority.IDLE), true);
  queue.stopAll();
  assert.equal(queue.isFinished(), true);
});

test('Model EyeBlink, LipSync, PartOpacity and driven marking', () => {
  const r = resolver({ Blink: 10, Mouth: 20 }, { Opacity: 3 }, [10, 11], [20, 21]);
  const full = parse(
    { Duration: 1, FadeInTime: 0, FadeOutTime: 0 },
    [
      constant('Blink', 0.2),
      constant('Mouth', 0.1),
      constant('Opacity', 0.7, 'PartOpacity'),
      constant('EyeBlink', 2, 'Model'),
      constant('LipSync', 0.3, 'Model'),
      constant('Other', 9, 'Model')
    ]
  );
  const queue = Live2DMotion.createMotionQueue(r);
  queue.start(full, 0, Priority.NORMAL);
  const values = new Array(22).fill(0);
  const opacities = new Array(4).fill(0);
  const driven = new Array(22).fill(0);
  queue.update(values, opacities, 0, driven);
  near(values[10], 0.4, 'blink with parameter curve');
  near(values[11], 2, 'blink without parameter curve');
  near(values[20], 0.4, 'mouth with parameter curve');
  near(values[21], 0.3, 'mouth without parameter curve');
  near(opacities[3], 0.7, 'part opacity');
  assert.equal(driven[10], 1);
  assert.equal(driven[11], 1);
  assert.equal(driven[20], 1);
  assert.equal(driven[21], 1);
  assert.equal(driven[3], 0);

  const modelOnly = parse(
    { Duration: 1, FadeInTime: 0 },
    [constant('EyeBlink', 2, 'Model'), constant('LipSync', 0.3, 'Model')]
  );
  const second = Live2DMotion.createMotionQueue(r);
  const bare = new Array(22).fill(0);
  second.start(modelOnly, 0, Priority.NORMAL);
  second.update(bare, [], 0, null);
  near(bare[10], 2, 'bare blink 1');
  near(bare[11], 2, 'bare blink 2');
  near(bare[20], 0.3, 'bare mouth 1');
  near(bare[21], 0.3, 'bare mouth 2');

  const idle = Live2DMotion.createMotionQueue(r);
  const idleDriven = new Array(22).fill(0);
  idle.start(full, 0, Priority.IDLE);
  idle.update(new Array(22).fill(0), [], 0, idleDriven);
  assert.ok(idleDriven.every(value => value === 0), 'IDLE does not drive');
});

test('expression Add, Multiply, Overwrite, fades and replacement', () => {
  const index = id => {
    const map = { A: 0, M: 1, O: 2 };
    return Object.prototype.hasOwnProperty.call(map, id) ? map[id] : -1;
  };
  const first = Live2DMotion.parseExpression({
    Type: 'Live2D Expression',
    FadeInTime: 1,
    FadeOutTime: 1,
    Parameters: [
      { Id: 'A', Value: 1, Blend: 'Add' },
      { Id: 'M', Value: 2, Blend: 'Multiply' },
      { Id: 'O', Value: 8, Blend: 'Overwrite' }
    ]
  });
  const next = Live2DMotion.parseExpression({
    FadeInTime: 1,
    Parameters: [{ Id: 'A', Value: 2 }]
  });
  const queue = Live2DMotion.createExpressionQueue();
  const values = [0, 2, 10];
  queue.set(first, 0);
  queue.update(values, 0.5, index);
  near(values[0], 0.5, 'Add');
  near(values[1], 3, 'Multiply');
  near(values[2], 9, 'Overwrite');

  queue.set(next, 1);
  queue.update(values, 1.5, index);
  near(values[0], 2, 'old fades out while new fades in');
  near(values[1], 4.5, 'old expression still applies Multiply');
  queue.update(values, 2, index);
  near(values[0], 4, 'replacement fully applied');
  assert.equal(queue.isEmpty(), false);

  queue.set(null, 2);
  queue.update(values, 2.5, index);
  near(values[0], 5, 'replacement fades out');
  queue.update(values, 3, index);
  assert.equal(queue.isEmpty(), true);
});
