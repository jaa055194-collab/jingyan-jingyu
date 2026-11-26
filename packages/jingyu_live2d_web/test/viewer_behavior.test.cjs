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
    log,
    rendererCalls,
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
