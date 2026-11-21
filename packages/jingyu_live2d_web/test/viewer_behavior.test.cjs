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

function createHarness(options = {}) {
  const posted = [];
  const channelPosts = [];
  const messageListeners = [];
  const rafCallbacks = new Map();
  const rendererCalls = [];
  let nextRafId = 1;

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
        return {
          parameters: {
            ids: ['ParamMouthOpenY', 'ParamEyeLOpen'],
            values: [0, 1],
            count: 2,
          },
          update: () => rendererCalls.push('model.update'),
          release: () => rendererCalls.push('model.release'),
        };
      },
    },
  };
  if (options.noCore) delete core.Moc;

  const renderer = {
    prepare: async (canvas, model, textureUrls) => {
      rendererCalls.push('renderer.prepare');
      if (options.prepareFails) throw new Error('texture upload failed');
      assert.equal(textureUrls.length, 1, 'one texture expected');
    },
    draw: () => {
      rendererCalls.push('renderer.draw');
      if (options.drawFails) throw new Error('first draw failed');
    },
    setExpression: (name) => rendererCalls.push('renderer.expression:' + name),
    setMotion: (group, index) =>
      rendererCalls.push('renderer.motion:' + group + ':' + index),
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
  if (options.bridgeChannel) {
    window.Live2DBridge = {
      postMessage: (text) => channelPosts.push(JSON.parse(text)),
    };
  }
  if (!options.noCore) window.PurismCore = core;
  window.parent = { postMessage: (message) => posted.push(message) };

  const document = {
    getElementById: () => ({ width: 300, height: 300 }),
  };

  const fetchStub = async (url) => {
    if (url.endsWith('model.model3.json')) {
      return {
        ok: true,
        async json() {
          return {
            FileReferences: {
              Moc: 'model.moc3',
              Textures: ['texture-0.png'],
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
    return { ok: false, status: 404 };
  };

  const context = vm.createContext({
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
  });
  vm.runInContext(VIEWER, context, { filename: 'live2d_viewer.js' });

  const flush = async () => {
    for (let i = 0; i < 6; i += 1) {
      await new Promise((resolve) => setImmediate(resolve));
    }
  };

  return {
    posted,
    channelPosts,
    rendererCalls,
    flush,
    send(message) {
      window.__live2dReceive(message);
    },
    flushOneFrame() {
      const entry = rafCallbacks.entries().next();
      if (entry.done) return;
      rafCallbacks.delete(entry.value[0]);
      entry.value[1]();
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
  for (const member of ['prepare', 'draw', 'setExpression', 'setMotion', 'dispose']) {
    assert.equal(typeof surface[member], 'function', member);
  }
});
