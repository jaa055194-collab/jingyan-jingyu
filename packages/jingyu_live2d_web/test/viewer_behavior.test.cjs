// Behaviour tests for web/live2d_viewer.js.
//
// These run the real viewer script in a VM sandbox with a stub PurismCore and a
// stub renderer adapter. They exercise the message protocol and the
// "ready means the first draw succeeded" contract without requiring a GPU,
// model assets or the PurismCore binary.
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const VIEWER = fs.readFileSync(
  path.join(__dirname, '..', 'web', 'live2d_viewer.js'),
  'utf8',
);
const RENDERER = fs.readFileSync(
  path.join(__dirname, '..', 'web', 'live2d_renderer_webgl.js'),
  'utf8',
);
// The animation modules the viewer needs, loaded before it like the page does.
const ANIMATION = [
  'live2d_motion.js',
  'live2d_behavior.js',
  'live2d_physics.js',
  'live2d_pose.js',
].map((name) => ({
  name,
  source: fs.readFileSync(path.join(__dirname, '..', 'web', name), 'utf8'),
}));

function createHarness(options = {}) {
  // `posted` (parent.postMessage) and `channelPosts` (Live2DBridge) hold every
  // event except `boot`; `log` holds all events in the order they were posted.
  const posted = [];
  const channelPosts = [];
  const log = [];
  const messageListeners = [];
  const bridgeListeners = [];
  const canvasListeners = {};
  const rafCallbacks = new Map();
  const rendererCalls = [];
  let nextRafId = 1;
  let draws = 0;
  let shownModel = null;

  const record = (target, message) => {
    log.push(message);
    if (message.event !== 'boot') target.push(message);
  };

  // One canvas for the whole run, so tests can fire WebGL context events.
  const canvas = {
    width: 300,
    height: 300,
    addEventListener(type, listener) {
      (canvasListeners[type] = canvasListeners[type] || []).push(listener);
    },
  };
  const fireCanvas = (type) => {
    const event = {
      type,
      defaultPrevented: false,
      preventDefault() {
        this.defaultPrevented = true;
      },
    };
    for (const listener of canvasListeners[type] || []) listener(event);
    return event;
  };

  const core = {
    Moc: {
      fromArrayBuffer() {
        return {
          getError: () => 0,
          _release: () => rendererCalls.push('moc.release'),
        };
      },
    },
    Model: {
      fromMoc() {
        if (options.modelCreationFails) return null;
        // `modelParameters` replaces the default parameter set (IDs and
        // values, no range arrays); `modelParts` adds the parts object the
        // default model lacks.
        const model = {
          parameters: options.modelParameters || {
            ids: ['ParamMouthOpenY', 'ParamEyeLOpen'],
            values: [0, 1],
            count: 2,
          },
          update: () => rendererCalls.push('model.update'),
          release: () => rendererCalls.push('model.release'),
        };
        if (options.modelParts) model.parts = options.modelParts;
        shownModel = model;
        return model;
      },
    },
  };
  if (options.noCore) delete core.Moc;

  const renderer = {
    prepare: async (target, model, textureUrls) => {
      rendererCalls.push('renderer.prepare');
      if (options.loseContextInPrepare) fireCanvas('webglcontextlost');
      if (options.restoreContextInPrepare) fireCanvas('webglcontextrestored');
      if (options.prepareFails) throw new Error('texture upload failed');
      assert.equal(textureUrls.length, 1, 'one texture expected');
      return options.prepareResult || { ok: true };
    },
    draw: () => {
      rendererCalls.push('renderer.draw');
      draws += 1;
      if (options.drawFails) throw new Error('first draw failed');
      if (draws === options.drawFailsAt) throw new Error('draw ' + draws + ' failed');
    },
    dispose: () => rendererCalls.push('renderer.dispose'),
  };

  const window = {
    parent: null,
    addEventListener(type, listener) {
      if (type === 'message') messageListeners.push(listener);
    },
    requestAnimationFrame(callback) {
      const id = nextRafId++;
      rafCallbacks.set(id, callback);
      return id;
    },
    cancelAnimationFrame(id) {
      rafCallbacks.delete(id);
    },
  };
  if (!options.noRenderer) window.Live2DRenderer = renderer;
  if (options.bridgeChannel || options.bridgeListener) {
    window.Live2DBridge = {
      postMessage: (text) => record(channelPosts, JSON.parse(text)),
    };
  }
  if (options.bridgeListener) {
    // Shape of an androidx.webkit WebMessageListener object: the host's
    // replies arrive as `message` events whose data is the posted string.
    window.Live2DBridge.addEventListener = (type, listener) => {
      if (type === 'message') bridgeListeners.push(listener);
    };
  }
  if (!options.noCore) window.PurismCore = core;
  window.parent = { postMessage: (message) => record(posted, message) };

  const document = {
    getElementById: () => canvas,
  };

  // `fileReferences` adds keys to the model3's FileReferences. `files` maps a
  // path below the model3 to its body: a string (served as UTF-8), a
  // Uint8Array (served as is) or an Error (the fetch rejects with it); any
  // other URL is a 404. Both are read at fetch time, so a test may change
  // them between loads. With `holdFiles` such a fetch waits until the test
  // calls releaseFiles(), so `filesInFlight` shows how many load at once.
  const fetches = [];
  const files = options.files || {};
  const filesBase = 'http://127.0.0.1:9/';
  let filesInFlight = 0;
  let maxFilesInFlight = 0;
  let releaseFiles = () => {};
  const filesGate = options.holdFiles
    ? new Promise((resolve) => {
        releaseFiles = resolve;
      })
    : null;
  const fetchStub = async (url) => {
    fetches.push(url);
    if (url.endsWith('model.model3.json')) {
      return {
        ok: true,
        async json() {
          return {
            FileReferences: {
              Moc: 'model.moc3',
              Textures: ['texture-0.png'],
              ...options.fileReferences,
            },
          };
        },
      };
    }
    if (url.endsWith('model.moc3')) {
      return {
        ok: true,
        async arrayBuffer() {
          return new ArrayBuffer(16);
        },
      };
    }
    const name = url.startsWith(filesBase) ? decodeURIComponent(url.slice(filesBase.length)) : '';
    if (!Object.prototype.hasOwnProperty.call(files, name)) return { ok: false, status: 404 };
    filesInFlight += 1;
    maxFilesInFlight = Math.max(maxFilesInFlight, filesInFlight);
    try {
      if (filesGate) await filesGate;
    } finally {
      filesInFlight -= 1;
    }
    const body = files[name];
    if (body instanceof Error) throw body;
    const bytes = typeof body === 'string' ? new TextEncoder().encode(body) : body;
    return {
      ok: true,
      async arrayBuffer() {
        return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
      },
    };
  };

  const globals = {
    window,
    document,
    console,
    URL,
    fetch: fetchStub,
    ArrayBuffer,
    Uint8Array,
    Promise,
    setTimeout,
    clearTimeout,
  };
  // The viewer checks expression and motion files with TextDecoder.
  if (!options.noTextDecoder) globals.TextDecoder = TextDecoder;
  const context = vm.createContext(globals);
  if (!options.noAnimation) {
    for (const module of ANIMATION) {
      vm.runInContext(module.source, context, { filename: module.name });
    }
  }
  vm.runInContext(VIEWER, context, { filename: 'live2d_viewer.js' });

  const flush = async () => {
    for (let i = 0; i < 6; i += 1) {
      await new Promise((resolve) => setImmediate(resolve));
    }
  };

  return {
    posted,
    channelPosts,
    log,
    rendererCalls,
    fetches,
    filesInFlight: () => filesInFlight,
    maxFilesInFlight: () => maxFilesInFlight,
    releaseFiles: () => releaseFiles(),
    flush,
    fireCanvas,
    send(message) {
      window.__live2dReceive(message);
    },
    sendViaBridge(message) {
      for (const listener of bridgeListeners) {
        listener({ data: JSON.stringify(message) });
      }
    },
    model: () => shownModel,
    flushOneFrame(time) {
      const entry = rafCallbacks.entries().next();
      if (entry.done) return;
      rafCallbacks.delete(entry.value[0]);
      entry.value[1](time);
    },
    rafPending: () => rafCallbacks.size,
  };
}

const loadCommand = {
  cmd: 'load',
  modelId: 'model.a',
  model3: 'http://127.0.0.1:9/model.model3.json',
  textureUrls: ['http://127.0.0.1:9/texture-0.png'],
  profileRev: 1,
};

// 'ready', or 'error:<code>' for an error event.
const summary = (messages) =>
  messages.map((message) => message.event + (message.code ? ':' + message.code : ''));

test('load reports ready only after the first draw succeeds', async () => {
  const harness = createHarness();
  harness.send(loadCommand);
  await harness.flush();

  assert.deepEqual(harness.rendererCalls.slice(0, 3), [
    'renderer.prepare',
    'model.update',
    'renderer.draw',
  ]);
  const events = harness.posted.map((message) => message.event);
  assert.deepEqual(events, ['ready']);
  assert.equal(harness.posted[0].modelId, 'model.a');
  assert.equal(harness.posted[0].profileRev, 1);
});

// A posted event as the host decodes it (JSON on the wire). Decoding also turns
// the viewer's objects, made in the VM realm, into plain objects of this realm,
// which strict deepEqual needs to compare them with literals.
const wire = (value) => JSON.parse(JSON.stringify(value));

test('ready lists the runtime parameter ranges and part IDs in runtime order', async () => {
  const harness = createHarness({
    modelParameters: {
      count: 3,
      ids: ['ParamAngleX', 'ParamMouthOpenY', 'ParamEyeLOpen'],
      values: new Float32Array([0, 0, 1]),
      minimumValues: new Float32Array([-30, 0, 0]),
      maximumValues: new Float32Array([30, 1, 1]),
      defaultValues: new Float32Array([0, 0, 1]),
    },
    modelParts: { count: 2, ids: ['PartHead', 'PartArmL'] },
  });
  harness.send(loadCommand);
  await harness.flush();

  assert.deepEqual(summary(harness.posted), ['ready']);
  const ready = wire(harness.posted[0]);
  assert.equal(ready.modelId, 'model.a');
  assert.equal(ready.profileRev, 1);
  assert.deepEqual(ready.parameters, [
    { id: 'ParamAngleX', min: -30, max: 30, default: 0 },
    { id: 'ParamMouthOpenY', min: 0, max: 1, default: 0 },
    { id: 'ParamEyeLOpen', min: 0, max: 1, default: 1 },
  ]);
  assert.deepEqual(ready.parts, ['PartHead', 'PartArmL']);
});

test('ready leaves a non-finite range value out of its parameter entry', async () => {
  const harness = createHarness({
    modelParameters: {
      count: 3,
      ids: ['ParamA', 'ParamB', 'ParamC'],
      values: [0, 0, 0],
      minimumValues: [NaN, -1, '0'],
      maximumValues: [1, Infinity, null],
      // Shorter than count: ParamC has no default value at all.
      defaultValues: [0.5, -Infinity],
    },
  });
  harness.send(loadCommand);
  await harness.flush();

  assert.deepEqual(summary(harness.posted), ['ready']);
  const parameters = harness.posted[0].parameters;
  // Left out means no key at all, not a key holding undefined or null.
  assert.deepEqual(Array.from(parameters, (entry) => Object.keys(entry)), [
    ['id', 'max', 'default'],
    ['id', 'min'],
    ['id'],
  ]);
  assert.deepEqual(wire(parameters), [
    { id: 'ParamA', max: 1, default: 0.5 },
    { id: 'ParamB', min: -1 },
    { id: 'ParamC' },
  ]);
});

test('ready leaves out an ID list it cannot report whole and still arrives', async () => {
  const names = (count) => Array.from({ length: count }, (_, index) => 'Param' + index);
  const parts = { count: 1, ids: ['PartHead'] };
  const unreportable = {
    'more than 4096 IDs': { count: 4097, ids: names(4097) },
    'a non-string ID': { count: 2, ids: ['ParamAngleX', 7] },
    'an empty ID': { count: 2, ids: ['ParamAngleX', ''] },
    'fewer IDs than count': { count: 3, ids: names(2) },
    'a fractional count': { count: 1.5, ids: names(2) },
    'a negative count': { count: -1, ids: [] },
    'no count': { ids: names(2) },
    'unreadable IDs': {
      count: 1,
      get ids() {
        throw new Error('parameter IDs unreadable');
      },
    },
  };
  for (const [label, modelParameters] of Object.entries(unreportable)) {
    const harness = createHarness({ modelParameters, modelParts: parts });
    harness.send(loadCommand);
    await harness.flush();
    assert.deepEqual(summary(harness.posted), ['ready'], label);
    assert.equal('parameters' in harness.posted[0], false, label);
    assert.deepEqual(wire(harness.posted[0].parts), ['PartHead'], label);
  }

  // The limit is inclusive: 4096 IDs are still reported in full.
  const atLimit = createHarness({ modelParameters: { count: 4096, ids: names(4096) } });
  atLimit.send(loadCommand);
  await atLimit.flush();
  assert.deepEqual(summary(atLimit.posted), ['ready']);
  assert.equal(atLimit.posted[0].parameters.length, 4096);

  // A malformed parts list is dropped on its own; the parameters stay.
  const badParts = createHarness({ modelParts: { count: 2, ids: ['PartHead', null] } });
  badParts.send(loadCommand);
  await badParts.flush();
  assert.deepEqual(summary(badParts.posted), ['ready']);
  assert.equal('parts' in badParts.posted[0], false);
  assert.equal(badParts.posted[0].parameters.length, 2);
});

test('ready from a model without ranges, parts, expressions or motions lists bare parameter IDs and empty lists', async () => {
  const harness = createHarness();
  harness.send(loadCommand);
  await harness.flush();

  assert.deepEqual(summary(harness.posted), ['ready']);
  const ready = harness.posted[0];
  assert.deepEqual(Object.keys(ready), [
    'event',
    'modelId',
    'profileRev',
    'parameters',
    'expressions',
    'motions',
  ]);
  assert.deepEqual(wire(ready.parameters), [{ id: 'ParamMouthOpenY' }, { id: 'ParamEyeLOpen' }]);
  // A model3 without Expressions or Motions has none: whole, empty lists.
  assert.deepEqual(wire(ready.expressions), []);
  assert.deepEqual(wire(ready.motions), []);

  // Empty ones too; a motion group without motions has nothing to address.
  const empty = createHarness({ fileReferences: { Expressions: [], Motions: { Idle: [] } } });
  empty.send(loadCommand);
  await empty.flush();
  assert.deepEqual(summary(empty.posted), ['ready']);
  assert.deepEqual(wire(empty.posted[0].expressions), []);
  assert.deepEqual(wire(empty.posted[0].motions), []);
});

// A staged file is listed only when live2d_motion.js can compile it. This
// minimal object is both a valid exp3 and a valid motion3 file.
const OBJECT_FILE = JSON.stringify({
  Version: 3,
  Type: 'Live2D Expression',
  Parameters: [],
  Meta: { Duration: 1 },
  Curves: [],
});
// One parameter curve from 0 to 1, for checking that the frame pipeline plays.
const MOUTH_MOTION = JSON.stringify({
  Version: 3,
  Meta: { Duration: 2, FadeInTime: 0, FadeOutTime: 0 },
  Curves: [{
    Target: 'Parameter', Id: 'ParamMouthOpenY', Segments: [0, 0, 0, 1, 1],
  }],
});
const fileFetches = (harness) =>
  harness.fetches.filter((url) => /\.(exp3|motion3)\.json$/.test(url));

test('ready lists the staged expressions and motion groups in model3 order', async () => {
  const harness = createHarness({
    fileReferences: {
      Expressions: [
        { Name: 'Smile', File: 'expressions/smile.exp3.json' },
        { Name: 'Angry', File: 'expressions/angry.exp3.json' },
        // Names may share a file.
        { Name: 'Grin', File: 'expressions/smile.exp3.json' },
      ],
      Motions: {
        Idle: [
          { File: 'motions/idle_0.motion3.json' },
          { File: 'motions/idle_1.motion3.json', FadeInTime: 0.5 },
        ],
        // Cubism allows an empty group name.
        '': [{ File: 'motions/idle_0.motion3.json' }],
        // A group without motions has nothing to address.
        Empty: [],
        TapBody: [{ File: 'motions/tap.motion3.json' }],
      },
    },
    files: {
      'expressions/smile.exp3.json': OBJECT_FILE,
      'expressions/angry.exp3.json': OBJECT_FILE,
      'motions/idle_0.motion3.json': OBJECT_FILE,
      'motions/idle_1.motion3.json': OBJECT_FILE,
      'motions/tap.motion3.json': OBJECT_FILE,
    },
  });
  harness.send(loadCommand);
  await harness.flush();

  assert.deepEqual(summary(harness.posted), ['ready']);
  const ready = wire(harness.posted[0]);
  assert.deepEqual(ready.expressions, ['Smile', 'Angry', 'Grin']);
  assert.deepEqual(ready.motions, [
    { group: 'Idle', count: 2 },
    { group: '', count: 1 },
    { group: 'TapBody', count: 1 },
  ]);
  // Each distinct file is loaded once.
  assert.equal(fileFetches(harness).length, 5);
  assert.equal(new Set(fileFetches(harness)).size, 5);
});

test('ready leaves out an expression or a motion group whose file does not load', async () => {
  const arrays = (depth) => '['.repeat(depth) + ']'.repeat(depth);
  const harness = createHarness({
    fileReferences: {
      Expressions: [
        { Name: 'Loads', File: 'loads.exp3.json' },
        { Name: 'Missing', File: 'missing.exp3.json' },
        { Name: 'Rejected', File: 'rejected.exp3.json' },
        { Name: 'NotJson', File: 'not-json.exp3.json' },
        { Name: 'ArrayRoot', File: 'array-root.exp3.json' },
        { Name: 'NotUtf8', File: 'not-utf8.exp3.json' },
        { Name: 'TooDeep', File: 'too-deep.exp3.json' },
        { Name: 'Bom', File: 'bom.exp3.json' },
        { Name: 'DeepestAllowed', File: 'deepest.exp3.json' },
        { Name: 'BracketsInString', File: 'brackets.exp3.json' },
      ],
      Motions: {
        Idle: [{ File: 'loads.motion3.json' }, { File: 'loads.motion3.json' }],
        // One motion that does not load drops its whole group, so a
        // {group, index} keeps addressing the staged model3.
        Tap: [{ File: 'loads.motion3.json' }, { File: 'missing.motion3.json' }],
        Shake: [{ File: 'not-json.exp3.json' }],
        Walk: [{ File: 'loads.motion3.json' }],
      },
    },
    files: {
      'loads.exp3.json': OBJECT_FILE,
      'rejected.exp3.json': new Error('connection reset'),
      'not-json.exp3.json': '{"Version":',
      'array-root.exp3.json': '[]',
      'not-utf8.exp3.json': new Uint8Array([0x7b, 0xff, 0x7d]),
      // The root object and 64 arrays: 65 levels, one past the staging limit.
      'too-deep.exp3.json': OBJECT_FILE.slice(0, -1) + ',"a":' + arrays(64) + '}',
      'bom.exp3.json': '\ufeff' + OBJECT_FILE,
      'deepest.exp3.json': OBJECT_FILE.slice(0, -1) + ',"a":' + arrays(63) + '}',
      // Brackets in a string, after an escaped quote, do not nest.
      'brackets.exp3.json': OBJECT_FILE.slice(0, -1) + ',"a":' +
        JSON.stringify('"' + '['.repeat(70)) + '}',
      'loads.motion3.json': OBJECT_FILE,
    },
  });
  harness.send(loadCommand);
  await harness.flush();

  assert.deepEqual(summary(harness.posted), ['ready']);
  const ready = wire(harness.posted[0]);
  assert.deepEqual(ready.expressions, ['Loads', 'Bom', 'DeepestAllowed', 'BracketsInString']);
  assert.deepEqual(ready.motions, [
    { group: 'Idle', count: 2 },
    { group: 'Walk', count: 1 },
  ]);
});

test('ready leaves out an expression or motion list it cannot report whole and still arrives', async () => {
  const entries = (count, entry) => Array.from({ length: count }, (_, index) => entry(index));
  const files = { 'a.exp3.json': OBJECT_FILE, 'a.motion3.json': OBJECT_FILE };
  const expression = (index) => ({ Name: 'E' + index, File: 'a.exp3.json' });
  const motion = () => ({ File: 'a.motion3.json' });

  const unreportableExpressions = {
    'not a list': expression(0),
    'a null list': null,
    'an entry not an object': ['a.exp3.json'],
    'a null entry': [null],
    'no File': [{ Name: 'Smile' }],
    'an empty File': [{ Name: 'Smile', File: '' }],
    'a non-string File': [{ Name: 'Smile', File: 7 }],
    'no Name': [{ File: 'a.exp3.json' }],
    'an empty Name': [{ Name: '', File: 'a.exp3.json' }],
    'a non-string Name': [{ Name: 3, File: 'a.exp3.json' }],
    'a Name over 256 units': [{ Name: 'x'.repeat(257), File: 'a.exp3.json' }],
    'a repeated Name': [expression(1), expression(1)],
    'more than 1024 entries': entries(1025, expression),
  };
  for (const [label, Expressions] of Object.entries(unreportableExpressions)) {
    const harness = createHarness({
      fileReferences: { Expressions, Motions: { Idle: [motion()] } },
      files,
    });
    harness.send(loadCommand);
    await harness.flush();
    assert.deepEqual(summary(harness.posted), ['ready'], label);
    assert.equal('expressions' in harness.posted[0], false, label);
    assert.deepEqual(wire(harness.posted[0].motions), [{ group: 'Idle', count: 1 }], label);
  }

  const unreportableMotions = {
    'not a map': [motion()],
    'a null map': null,
    'a group not a list': { Idle: motion() },
    'an entry not an object': { Idle: ['a.motion3.json'] },
    'no File': { Idle: [{ FadeInTime: 0.5 }] },
    'an empty File': { Idle: [{ File: '' }] },
    'a group name over 256 units': { ['g'.repeat(257)]: [motion()] },
    'more than 1024 motions in a group': { Idle: entries(1025, motion) },
    'more than 4096 motions in all': Object.fromEntries(
      entries(5, (index) => ['G' + index, entries(820, motion)]),
    ),
    'more than 4096 groups': Object.fromEntries(entries(4097, (index) => ['G' + index, []])),
  };
  for (const [label, Motions] of Object.entries(unreportableMotions)) {
    const harness = createHarness({
      fileReferences: { Expressions: [expression(0)], Motions },
      files,
    });
    harness.send(loadCommand);
    await harness.flush();
    assert.deepEqual(summary(harness.posted), ['ready'], label);
    assert.equal('motions' in harness.posted[0], false, label);
    assert.deepEqual(wire(harness.posted[0].expressions), ['E0'], label);
  }

  // The limits are inclusive.
  const longName = 'x'.repeat(256);
  const atLimits = createHarness({
    fileReferences: {
      Expressions: [...entries(1023, expression), { Name: longName, File: 'a.exp3.json' }],
      Motions: {
        [longName]: entries(1024, motion),
        // 3072 more motions make 4096 in all; 1023 empty groups make 4096 groups.
        ...Object.fromEntries(entries(3072, (index) => ['G' + index, [motion()]])),
        ...Object.fromEntries(entries(1023, (index) => ['Empty' + index, []])),
      },
    },
    files,
  });
  atLimits.send(loadCommand);
  await atLimits.flush();
  assert.deepEqual(summary(atLimits.posted), ['ready']);
  const ready = wire(atLimits.posted[0]);
  assert.equal(ready.expressions.length, 1024);
  assert.equal(ready.expressions[1023], longName);
  assert.equal(ready.motions.length, 3073);
  assert.deepEqual(ready.motions[0], { group: longName, count: 1024 });
  // Entries that share a file load it once.
  assert.equal(fileFetches(atLimits).length, 2);
});

test('without TextDecoder ready leaves out an expression or motion list with files', async () => {
  const harness = createHarness({
    noTextDecoder: true,
    fileReferences: {
      Expressions: [{ Name: 'Smile', File: 'a.exp3.json' }],
      Motions: { Idle: [{ File: 'a.motion3.json' }] },
    },
    files: { 'a.exp3.json': OBJECT_FILE, 'a.motion3.json': OBJECT_FILE },
  });
  harness.send(loadCommand);
  await harness.flush();

  // No file can be checked, so none is fetched and the preview still loads.
  assert.deepEqual(summary(harness.posted), ['ready']);
  assert.equal('expressions' in harness.posted[0], false);
  assert.equal('motions' in harness.posted[0], false);
  assert.deepEqual(fileFetches(harness), []);

  // Lists without files need no check and stay whole.
  const empty = createHarness({ noTextDecoder: true, fileReferences: { Motions: { Idle: [] } } });
  empty.send(loadCommand);
  await empty.flush();
  assert.deepEqual(summary(empty.posted), ['ready']);
  assert.deepEqual(wire(empty.posted[0].expressions), []);
  assert.deepEqual(wire(empty.posted[0].motions), []);
});

test('a load keeps the shown model until its expression and motion files load', async () => {
  // Both are read at fetch time, so the second load sees what is added below.
  const fileReferences = {};
  const files = {};
  const harness = createHarness({ fileReferences, files, holdFiles: true });
  harness.send(loadCommand);
  await harness.flush();
  assert.deepEqual(summary(harness.posted), ['ready']);

  // Nine distinct files; e0.exp3.json is referenced twice.
  fileReferences.Expressions = Array.from({ length: 8 }, (_, index) => {
    files['e' + index + '.exp3.json'] = OBJECT_FILE;
    return { Name: 'E' + index, File: 'e' + index + '.exp3.json' };
  });
  files['idle.motion3.json'] = OBJECT_FILE;
  fileReferences.Motions = { Idle: [{ File: 'idle.motion3.json' }, { File: 'e0.exp3.json' }] };
  harness.send({ ...loadCommand, modelId: 'model.b', profileRev: 2 });
  await harness.flush();

  // At most four files load at once, and the first model is still shown.
  assert.equal(harness.filesInFlight(), 4);
  assert.deepEqual(summary(harness.posted), ['ready']);
  assert.equal(harness.rendererCalls.includes('model.release'), false);
  assert.equal(harness.rendererCalls.filter((call) => call === 'renderer.prepare').length, 1);

  harness.releaseFiles();
  await harness.flush();
  assert.deepEqual(summary(harness.posted), ['ready', 'ready']);
  const ready = wire(harness.posted[1]);
  assert.equal(ready.modelId, 'model.b');
  assert.deepEqual(ready.expressions, ['E0', 'E1', 'E2', 'E3', 'E4', 'E5', 'E6', 'E7']);
  assert.deepEqual(ready.motions, [{ group: 'Idle', count: 2 }]);
  assert.equal(harness.maxFilesInFlight(), 4);
  assert.equal(fileFetches(harness).length, 9);
  assert.equal(new Set(fileFetches(harness)).size, 9);
  // The swap released the first model.
  assert.equal(harness.rendererCalls.filter((call) => call === 'model.release').length, 1);
});

test('dispose while expression and motion files load ends the load without ready or error', async () => {
  const harness = createHarness({
    holdFiles: true,
    fileReferences: { Expressions: [{ Name: 'Smile', File: 'a.exp3.json' }] },
    files: { 'a.exp3.json': OBJECT_FILE },
  });
  harness.send(loadCommand);
  await harness.flush();
  assert.equal(harness.filesInFlight(), 1);

  harness.send({ cmd: 'dispose' });
  harness.releaseFiles();
  await harness.flush();

  assert.deepEqual(harness.posted, []);
  // The new model was never shown, so the load releases it itself.
  assert.ok(harness.rendererCalls.includes('model.release'));
  assert.ok(harness.rendererCalls.includes('moc.release'));
  assert.equal(harness.rendererCalls.includes('renderer.prepare'), false);
});

test('a failed first draw reports error and never reports ready', async () => {
  const harness = createHarness({ drawFails: true });
  harness.send(loadCommand);
  await harness.flush();

  const events = harness.posted.map((message) => message.event);
  assert.deepEqual(events, ['error']);
  assert.match(harness.posted[0].message, /first draw failed/);
});

test('a failed renderer prepare reports error and never reports ready', async () => {
  const harness = createHarness({ prepareFails: true });
  harness.send(loadCommand);
  await harness.flush();

  const events = harness.posted.map((message) => message.event);
  assert.deepEqual(events, ['error']);
  assert.match(harness.posted[0].message, /texture upload failed/);
});

test('a missing renderer adapter is an error, not a ready core update', async () => {
  const harness = createHarness({ noRenderer: true });
  harness.send(loadCommand);
  await harness.flush();

  const events = harness.posted.map((message) => message.event);
  assert.deepEqual(events, ['error']);
  assert.match(harness.posted[0].message, /renderer adapter missing/);
});

test('a missing PurismCore runtime reports error', async () => {
  const harness = createHarness({ noCore: true });
  harness.send(loadCommand);
  await harness.flush();

  const events = harness.posted.map((message) => message.event);
  assert.deepEqual(events, ['error']);
  assert.match(harness.posted[0].message, /PurismCore runtime missing/);
});

test('model creation failure reports error and never reports ready', async () => {
  const harness = createHarness({ modelCreationFails: true });
  harness.send(loadCommand);
  await harness.flush();

  const events = harness.posted.map((message) => message.event);
  assert.deepEqual(events, ['error']);
  assert.match(harness.posted[0].message, /Model creation failed/);
});

test('a second load while one is running is rejected', async () => {
  const harness = createHarness();
  harness.send(loadCommand);
  harness.send({ ...loadCommand, modelId: 'model.b' });
  await harness.flush();

  const errors = harness.posted.filter((message) => message.event === 'error');
  const ready = harness.posted.filter((message) => message.event === 'ready');
  assert.equal(errors.length, 1);
  assert.match(errors[0].message, /load already in progress/);
  assert.equal(ready.length, 1, 'only the first load may become ready');
  assert.equal(ready[0].modelId, 'model.a');
});

test('parameters are applied on the loaded model while ready', async () => {
  const harness = createHarness();
  harness.send(loadCommand);
  await harness.flush();
  harness.send({ cmd: 'setParam', name: 'ParamMouthOpenY', value: 0.75 });
  assert.equal(harness.posted.length, 1, 'no error expected');
  harness.send({ cmd: 'setParam', name: 'ParamMissing', value: 0.5 });
  assert.equal(harness.posted.at(-1).event, 'error');
  assert.match(harness.posted.at(-1).message, /unknown parameter/);
});

test('dispose releases the model and stops frame requests', async () => {
  const harness = createHarness();
  harness.send(loadCommand);
  await harness.flush();
  harness.send({ cmd: 'dispose' });
  assert.ok(harness.rendererCalls.includes('renderer.dispose'));
  assert.ok(harness.rendererCalls.includes('model.release'));
  assert.ok(harness.rendererCalls.includes('moc.release'));
  assert.equal(harness.rafPending(), 0);
});

test('events use the webview_flutter JavaScript channel when present', async () => {
  const harness = createHarness({ bridgeChannel: true });
  harness.send(loadCommand);
  await harness.flush();

  assert.deepEqual(
    harness.channelPosts.map((message) => message.event),
    ['ready'],
  );
  assert.equal(harness.channelPosts[0].modelId, 'model.a');
  assert.equal(harness.posted.length, 0);
});

test('the WebGL adapter exposes its public surface without a GPU', () => {
  const sandbox = { window: {}, console };
  vm.runInContext(RENDERER, vm.createContext(sandbox), {
    filename: 'live2d_renderer_webgl.js',
  });
  const surface = sandbox.window.Live2DRenderer;
  assert.ok(surface);
  for (const member of ['prepare', 'draw', 'dispose']) {
    assert.equal(typeof surface[member], 'function', member);
  }
});

test('boot is posted once, before any other event', async () => {
  const harness = createHarness();
  assert.deepEqual(summary(harness.log), ['boot']);
  harness.send(loadCommand);
  await harness.flush();
  assert.deepEqual(summary(harness.log), ['boot', 'ready']);
});

test('host commands arrive as message events on the Android bridge object', async () => {
  const harness = createHarness({ bridgeListener: true });
  harness.sendViaBridge(loadCommand);
  await harness.flush();
  assert.deepEqual(summary(harness.log), ['boot', 'ready']);
  assert.equal(harness.channelPosts.length, 1, 'events use the bridge');
  assert.equal(harness.posted.length, 0);
});

test('a renderer that reports not ok fails the load instead of claiming ready', async () => {
  const harness = createHarness({
    prepareResult: { ok: false, reason: 'webgl-unavailable' },
  });
  harness.send(loadCommand);
  await harness.flush();
  assert.deepEqual(summary(harness.posted), ['error:load_failed']);
  assert.match(harness.posted[0].message, /webgl-unavailable/);
  assert.ok(!harness.rendererCalls.includes('renderer.draw'));
});

test('bad commands and load failures carry their own codes', async () => {
  const harness = createHarness({ prepareFails: true });
  harness.send({ cmd: 'unknown' });
  harness.send({ cmd: 'setParam', name: 'ParamMouthOpenY', value: 1 });
  harness.send(loadCommand);
  await harness.flush();
  assert.deepEqual(summary(harness.posted), [
    'error:bad_command',
    'error:bad_command',
    'error:load_failed',
  ]);
});

test('a context loss after ready is reported once and releases the model', async () => {
  const harness = createHarness();
  harness.send(loadCommand);
  await harness.flush();
  const lost = harness.fireCanvas('webglcontextlost');
  harness.fireCanvas('webglcontextlost');
  assert.equal(lost.defaultPrevented, true, 'the viewer asks for the context back');
  assert.deepEqual(summary(harness.posted), ['ready', 'error:webgl_context_lost']);
  assert.equal(harness.rafPending(), 0);
  assert.ok(harness.rendererCalls.includes('model.release'));
  harness.send({ cmd: 'setParam', name: 'ParamMouthOpenY', value: 1 });
  assert.equal(summary(harness.posted).at(-1), 'error:bad_command');
});

test('loads fail with webgl_context_lost until the context is restored', async () => {
  const harness = createHarness();
  harness.send(loadCommand);
  await harness.flush();
  harness.fireCanvas('webglcontextlost');
  harness.send({ ...loadCommand, profileRev: 2 });
  await harness.flush();
  assert.deepEqual(summary(harness.posted), [
    'ready',
    'error:webgl_context_lost',
    'error:webgl_context_lost',
  ]);
  harness.fireCanvas('webglcontextrestored');
  harness.send({ ...loadCommand, profileRev: 3 });
  await harness.flush();
  assert.equal(summary(harness.posted).at(-1), 'ready');
  assert.equal(harness.posted.at(-1).profileRev, 3);
});

test('a context loss during a load fails that load as webgl_context_lost', async () => {
  for (const prepareFails of [false, true]) {
    const harness = createHarness({ loseContextInPrepare: true, prepareFails });
    harness.send(loadCommand);
    await harness.flush();
    assert.deepEqual(
      summary(harness.posted),
      ['error:webgl_context_lost'],
      'prepareFails=' + prepareFails,
    );
  }
});

test('a later frame failure is reported as render_failed and stops the loop', async () => {
  const harness = createHarness({ drawFailsAt: 2 });
  harness.send(loadCommand);
  await harness.flush();
  harness.flushOneFrame();
  harness.flushOneFrame();
  assert.deepEqual(summary(harness.posted), ['ready', 'error:render_failed']);
  assert.match(harness.posted[1].message, /draw 2 failed/);
  assert.equal(harness.rafPending(), 0);
  assert.ok(harness.rendererCalls.includes('model.release'));
});

test('a load that saw a loss fails even if the context came back meanwhile', async () => {
  const harness = createHarness({
    loseContextInPrepare: true,
    restoreContextInPrepare: true,
  });
  harness.send(loadCommand);
  await harness.flush();
  assert.deepEqual(summary(harness.posted), ['error:webgl_context_lost']);
  assert.ok(!harness.rendererCalls.includes('renderer.draw'));
});

test('a viewer without the animation modules fails the load', async () => {
  const harness = createHarness({ noAnimation: true });
  harness.send(loadCommand);
  await harness.flush();
  assert.deepEqual(summary(harness.posted), ['error:load_failed']);
  assert.match(harness.posted[0].message, /animation modules missing/);
});

test('an idle motion plays in the frame pipeline', async () => {
  const harness = createHarness({
    fileReferences: { Motions: { Idle: [{ File: 'idle.motion3.json' }] } },
    files: { 'idle.motion3.json': MOUTH_MOTION },
  });
  harness.send(loadCommand);
  await harness.flush();
  assert.equal(harness.model().parameters.values[0], 0);
  harness.flushOneFrame(0);
  harness.flushOneFrame(50);
  harness.flushOneFrame(150);
  assert.ok(harness.model().parameters.values[0] > 0.05);
  assert.ok(harness.rendererCalls.includes('model.update'));
});

test('staged physics and pose run in the frame pipeline', async () => {
  const physics = {
    Version: 3,
    Meta: { PhysicsSettingCount: 1 },
    PhysicsSettings: [{
      Id: 'S',
      Input: [{
        Source: { Target: 'Parameter', Id: 'PA' },
        Weight: 100,
        Type: 'Angle',
        Reflect: true,
      }],
      Output: [{
        Destination: { Target: 'Parameter', Id: 'PX' },
        VertexIndex: 1,
        Scale: 1,
        Weight: 100,
        Type: 'X',
        Reflect: false,
      }],
      Vertices: [
        { Position: { X: 0, Y: 0 }, Mobility: 1, Delay: 0, Acceleration: 1, Radius: 1 },
        { Position: { X: 0, Y: 0 }, Mobility: 1, Delay: 0, Acceleration: 1, Radius: 1 },
      ],
      Normalization: {
        Position: { Minimum: -1, Default: 0, Maximum: 1 },
        Angle: { Minimum: -30, Default: 0, Maximum: 30 },
      },
    }],
  };
  const pose = {
    Type: 'Live2D Pose',
    FadeInTime: 0,
    Groups: [[{ Id: 'PartA' }, { Id: 'PartB' }]],
  };
  const parts = { count: 2, ids: ['PartA', 'PartB'], opacities: new Float32Array([1, 1]) };
  const harness = createHarness({
    modelParameters: {
      count: 2,
      ids: ['PA', 'PX'],
      values: [15, 0],
      minimumValues: [-30, -1],
      maximumValues: [30, 1],
      defaultValues: [0, 0],
    },
    modelParts: parts,
    fileReferences: {
      Physics: 'physics.physics3.json',
      Pose: 'pose.pose3.json',
    },
    files: {
      'physics.physics3.json': JSON.stringify(physics),
      'pose.pose3.json': JSON.stringify(pose),
    },
  });
  harness.send(loadCommand);
  await harness.flush();
  assert.deepEqual(summary(harness.posted), ['ready']);
  assert.ok(harness.fetches.some((url) => url.endsWith('physics.physics3.json')));
  assert.ok(harness.fetches.some((url) => url.endsWith('pose.pose3.json')));
  assert.equal(parts.opacities[0], 1);
  assert.equal(parts.opacities[1], 0);
  harness.flushOneFrame(16);
  harness.flushOneFrame(160);
  assert.deepEqual(summary(harness.posted), ['ready']);
});

test('setParam is held across frames and clearParam releases it', async () => {
  const harness = createHarness();
  harness.send(loadCommand);
  await harness.flush();
  harness.send({ cmd: 'setParam', name: 'ParamMouthOpenY', value: 0.75 });
  harness.flushOneFrame(0);
  harness.flushOneFrame(16);
  assert.equal(harness.model().parameters.values[0], 0.75);
  harness.send({ cmd: 'clearParam', name: 'ParamMouthOpenY' });
  harness.flushOneFrame(32);
  assert.notEqual(harness.model().parameters.values[0], 0.75);
  assert.equal(harness.posted.length, 1);
});

test('animation commands accept listed names and reject malformed ones', async () => {
  const harness = createHarness({
    fileReferences: {
      Expressions: [{ Name: 'Smile', File: 'smile.exp3.json' }],
      Motions: { Idle: [{ File: 'idle.motion3.json' }] },
    },
    files: {
      'smile.exp3.json': OBJECT_FILE,
      'idle.motion3.json': MOUTH_MOTION,
    },
  });
  harness.send(loadCommand);
  await harness.flush();
  harness.send({ cmd: 'setExpression', name: 'Smile' });
  harness.send({ cmd: 'setExpression', name: null });
  harness.send({ cmd: 'setMotion', group: 'Idle', index: 0 });
  harness.send({ cmd: 'behavior', blink: ['ParamEyeLOpen'], mouth: [] });
  harness.send({ cmd: 'blink' });
  harness.send({ cmd: 'speak', levels: [0, 1, 0], step: 20 });
  harness.flushOneFrame(0);
  assert.deepEqual(harness.posted.map((message) => message.event), ['ready']);
  harness.send({ cmd: 'setExpression', name: 'Missing' });
  harness.send({ cmd: 'setMotion', group: 'Idle', index: 3 });
  harness.send({ cmd: 'behavior', blink: ['ParamMissing'], mouth: [] });
  harness.send({ cmd: 'speak', levels: [2], step: 20 });
  assert.deepEqual(harness.posted.slice(1).map((message) => message.code), [
    'bad_command', 'bad_command', 'bad_command', 'bad_command',
  ]);
});
