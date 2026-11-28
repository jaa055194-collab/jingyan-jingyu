// Hot-switch protocol tests for web/live2d_viewer.js.
//
// These run the real viewer in a VM sandbox with a stub PurismCore and a fake
// multi-scene renderer shaped like the D3a `window.Live2DRenderer` surface:
// createScene() returns scene objects, draw(scene, alpha) records the scene and
// alpha, beginFrame()/endFrame() bracket one composite frame, disposeScene()
// frees a scene, and lastError reports a texture-budget refusal.
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
const ANIMATION = [
  'live2d_motion.js',
  'live2d_behavior.js',
  'live2d_physics.js',
  'live2d_pose.js',
].map((name) => ({
  name,
  source: fs.readFileSync(path.join(__dirname, '..', 'web', name), 'utf8'),
}));

const OLD_MODEL3 = 'http://127.0.0.1:9/old.model3.json';
const NEXT_MODEL3 = 'http://127.0.0.1:9/next.model3.json';

const loadCommand = {
  cmd: 'load',
  modelId: 'model.a',
  model3: OLD_MODEL3,
  textureUrls: ['http://127.0.0.1:9/old-texture.png'],
  profileRev: 1,
};

const preloadCommand = {
  cmd: 'preload',
  loadId: 'load-1',
  modelId: 'model.b',
  model3: NEXT_MODEL3,
  textureUrls: ['http://127.0.0.1:9/next-texture.png'],
  profileRev: 2,
};

const summary = (messages) =>
  messages.map((message) => message.event + (message.code ? ':' + message.code : ''));
const wire = (value) => JSON.parse(JSON.stringify(value));

// Fresh arrays so two models never share parameter storage.
function defaultParameters() {
  return {
    count: 2,
    ids: ['ParamMouthOpenY', 'ParamEyeLOpen'],
    values: [0, 1],
  };
}

function createHarness() {
  const posted = [];
  const log = [];
  const calls = [];
  const models = [];
  const mocs = [];
  const scenes = [];
  const drawRecords = [];
  const rafCallbacks = [];
  const canvasListeners = {};
  let nextRafId = 1;
  let lastError = null;

  const h = {
    posted,
    log,
    calls,
    models,
    mocs,
    scenes,
    drawRecords,
    nextSceneFailure: null,
    nextModelSpec: null,
    failNextModelCreation: false,
    failModel3Url: null,
    drawThrowModel: null,
    holdNextCreateScene: false,
    releaseSceneGate: null,
  };

  const record = (target, message) => {
    log.push(message);
    if (message.event !== 'boot') target.push(message);
  };

  const canvas = {
    width: 300,
    height: 300,
    addEventListener(type, listener) {
      (canvasListeners[type] = canvasListeners[type] || []).push(listener);
    },
  };

  const core = {
    Moc: {
      fromArrayBuffer() {
        const moc = {
          id: 'moc-' + (mocs.length + 1),
          releases: 0,
          getError: () => 0,
          _release() {
            moc.releases += 1;
            calls.push({ call: 'moc.release', id: moc.id });
          },
        };
        mocs.push(moc);
        return moc;
      },
    },
    Model: {
      fromMoc(moc) {
        if (h.failNextModelCreation) {
          h.failNextModelCreation = false;
          return null;
        }
        const spec = h.nextModelSpec || {};
        h.nextModelSpec = null;
        const model = {
          id: 'model-' + (models.length + 1),
          moc,
          parameters: spec.parameters || defaultParameters(),
          updates: 0,
          releases: 0,
          update() {
            model.updates += 1;
          },
          release() {
            model.releases += 1;
            calls.push({ call: 'model.release', id: model.id });
          },
        };
        if (spec.parts) model.parts = spec.parts;
        models.push(model);
        return model;
      },
    },
  };

  const renderer = {
    get lastError() {
      return lastError;
    },
    set lastError(value) {
      lastError = value;
    },
    async createScene(target, model, textureUrls) {
      calls.push({
        call: 'createScene',
        modelId: model.id,
        textures: Array.from(textureUrls),
      });
      if (h.holdNextCreateScene) {
        h.holdNextCreateScene = false;
        await new Promise((resolve) => {
          h.releaseSceneGate = resolve;
        });
        h.releaseSceneGate = null;
      }
      const failure = h.nextSceneFailure;
      h.nextSceneFailure = null;
      if (failure === 'texture_budget') {
        lastError = 'texture_budget';
        return null;
      }
      if (failure === 'unavailable') {
        lastError = 'webgl-unavailable';
        return null;
      }
      if (failure === 'throw') {
        lastError = 'createScene exploded';
        throw new Error('createScene exploded');
      }
      lastError = null;
      const scene = {
        id: 'scene-' + (scenes.length + 1),
        isLive2DScene: true,
        model,
        disposed: false,
        disposeCalls: 0,
        bytes: 1000,
      };
      scenes.push(scene);
      return scene;
    },
    draw(target, alpha) {
      const scene = target && target.isLive2DScene ? target : null;
      const model = scene ? scene.model : target;
      const recordEntry = {
        kind: scene ? 'scene' : 'model',
        sceneId: scene ? scene.id : null,
        modelId: model ? model.id : null,
        alpha: typeof alpha === 'number' && Number.isFinite(alpha) ? alpha : 1,
      };
      drawRecords.push(recordEntry);
      calls.push({ call: 'draw', ...recordEntry });
      if (h.drawThrowModel && recordEntry.modelId === h.drawThrowModel) {
        throw new Error('draw failed for ' + recordEntry.modelId);
      }
    },
    beginFrame() {
      calls.push({ call: 'beginFrame' });
      return true;
    },
    endFrame() {
      calls.push({ call: 'endFrame' });
    },
    disposeScene(scene) {
      if (!scene) return;
      scene.disposed = true;
      scene.disposeCalls += 1;
      calls.push({ call: 'disposeScene', id: scene.id });
    },
    sceneBytes(scene) {
      return scene ? scene.bytes : 0;
    },
    totalLiveBytes() {
      return scenes
        .filter((scene) => !scene.disposed)
        .reduce((sum, scene) => sum + scene.bytes, 0);
    },
    // Legacy fallback; this fake always exposes createScene, so the viewer
    // takes the multi-scene path.
    async prepare() {
      calls.push({ call: 'prepare' });
      return { ok: true };
    },
    dispose() {
      calls.push({ call: 'renderer.dispose' });
      for (const scene of scenes) scene.disposed = true;
    },
  };

  const fetchStub = async (url) => {
    calls.push({ call: 'fetch', url });
    if (url === h.failModel3Url) {
      throw new Error('model3 fetch failed: ' + url);
    }
    if (url.endsWith('.model3.json')) {
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
    if (url.endsWith('.moc3')) {
      return {
        ok: true,
        async arrayBuffer() {
          return new ArrayBuffer(16);
        },
      };
    }
    return { ok: false, status: 404 };
  };

  const window = {
    addEventListener(type, listener) {
      if (type === 'message') messageListeners.push(listener);
    },
    requestAnimationFrame(callback) {
      const id = nextRafId++;
      rafCallbacks.push({ id, callback });
      return id;
    },
    cancelAnimationFrame(id) {
      const index = rafCallbacks.findIndex((entry) => entry.id === id);
      if (index >= 0) rafCallbacks.splice(index, 1);
    },
    parent: {
      postMessage(message) {
        record(posted, message);
      },
    },
  };
  const messageListeners = [];
  window.Live2DRenderer = renderer;
  window.PurismCore = core;

  const document = {
    getElementById: () => canvas,
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
    TextDecoder,
  };
  const context = vm.createContext(globals);
  for (const module of ANIMATION) {
    vm.runInContext(module.source, context, { filename: module.name });
  }
  vm.runInContext(VIEWER, context, { filename: 'live2d_viewer.js' });

  h.send = (message) => window.__live2dReceive(message);
  h.flush = async () => {
    for (let i = 0; i < 20; i += 1) {
      await new Promise((resolve) => setImmediate(resolve));
    }
  };
  h.flushFrame = (time) => {
    const entry = rafCallbacks.shift();
    if (!entry) return false;
    entry.callback(time);
    return true;
  };
  h.rafPending = () => rafCallbacks.length;
  h.releaseScene = () => {
    if (h.releaseSceneGate) {
      const release = h.releaseSceneGate;
      h.releaseSceneGate = null;
      release();
    }
  };
  h.renderer = renderer;
  return h;
}

async function loadOld() {
  const h = createHarness();
  h.send(loadCommand);
  await h.flush();
  assert.deepEqual(summary(h.posted), ['ready']);
  assert.equal(h.models.length, 1);
  assert.equal(h.scenes.length, 1);
  return h;
}

test('preload stages a scene while the shown model keeps ticking and drawing', async () => {
  const h = await loadOld();
  const oldModel = h.models[0];
  const oldScene = h.scenes[0];
  const updatesBefore = oldModel.updates;
  const drawMark = h.drawRecords.length;

  h.send(preloadCommand);
  await h.flush();

  assert.deepEqual(summary(h.posted), ['ready', 'preloaded']);
  assert.equal(h.posted[1].loadId, 'load-1');
  assert.equal(h.models.length, 2);
  assert.equal(h.scenes.length, 2);
  assert.equal(h.scenes[1].model, h.models[1]);
  // Nothing belonging to the shown model was released or disposed.
  assert.equal(oldModel.releases, 0);
  assert.equal(h.mocs[0].releases, 0);
  assert.equal(oldScene.disposed, false);
  assert.equal(oldScene.disposeCalls, 0);
  // The frame loop is still the old one and keeps running.
  assert.equal(h.rafPending(), 1);
  h.flushFrame(100);
  assert.equal(oldModel.updates, updatesBefore + 1);
  const frame = h.drawRecords.slice(drawMark);
  assert.ok(
    frame.some((entry) =>
      entry.kind === 'model' && entry.modelId === oldModel.id && entry.alpha === 1),
    'the shown model still draws at full alpha',
  );
  assert.equal(h.models[1].updates, 0, 'the staged model was not ticking yet');
});

test('a texture-budget refusal rejects the preload and leaves the old model alone', async () => {
  const h = await loadOld();
  const oldModel = h.models[0];
  const oldScene = h.scenes[0];
  h.nextSceneFailure = 'texture_budget';

  h.send(preloadCommand);
  await h.flush();

  assert.deepEqual(summary(h.posted), ['ready', 'preload_rejected:texture_budget']);
  assert.equal(h.posted[1].loadId, 'load-1');
  assert.equal(h.posted[1].code, 'texture_budget');
  assert.equal(h.scenes.length, 1);
  assert.equal(oldScene.disposed, false);
  assert.equal(oldModel.releases, 0);
  assert.equal(h.rafPending(), 1);
  const drawMark = h.drawRecords.length;
  const updatesBefore = oldModel.updates;
  h.flushFrame(200);
  assert.equal(oldModel.updates, updatesBefore + 1);
  assert.ok(h.drawRecords.slice(drawMark).some((entry) => entry.modelId === oldModel.id));
});

test('a preload failure reports its code and message without disturbing the old model', async () => {
  const h = await loadOld();
  const oldModel = h.models[0];
  h.failNextModelCreation = true;

  h.send(preloadCommand);
  await h.flush();

  assert.deepEqual(summary(h.posted), ['ready', 'preload_failed:load_failed']);
  assert.equal(h.posted[1].loadId, 'load-1');
  assert.equal(h.posted[1].code, 'load_failed');
  assert.match(h.posted[1].message, /Model creation failed/);
  assert.equal(h.models.length, 1);
  assert.equal(h.scenes.length, 1);
  assert.equal(oldModel.releases, 0);
  assert.equal(h.rafPending(), 1);

  // A createScene failure uses the same event and keeps the old model.
  const throwing = await loadOld();
  throwing.nextSceneFailure = 'throw';
  throwing.send(preloadCommand);
  await throwing.flush();
  assert.deepEqual(summary(throwing.posted), ['ready', 'preload_failed:load_failed']);
  assert.equal(throwing.posted[1].code, 'load_failed');
  assert.match(throwing.posted[1].message, /createScene exploded/);
  assert.equal(throwing.models[0].releases, 0);
  assert.equal(throwing.scenes.length, 1);
  assert.equal(throwing.rafPending(), 1);
});

test('a newer preload releases the older ready preload scene and its core objects', async () => {
  const h = await loadOld();
  const oldModel = h.models[0];

  h.send(preloadCommand);
  await h.flush();
  assert.deepEqual(summary(h.posted), ['ready', 'preloaded']);
  const firstScene = h.scenes[1];
  const firstModel = h.models[1];
  const firstMoc = h.mocs[1];

  h.send({
    cmd: 'preload',
    loadId: 'load-2',
    modelId: 'model.c',
    model3: NEXT_MODEL3,
    textureUrls: ['http://127.0.0.1:9/third-texture.png'],
    profileRev: 3,
  });
  await h.flush();

  assert.deepEqual(summary(h.posted), ['ready', 'preloaded', 'preloaded']);
  assert.equal(h.posted[2].loadId, 'load-2');
  assert.equal(firstScene.disposed, true);
  assert.equal(firstScene.disposeCalls, 1);
  assert.equal(firstModel.releases, 1);
  assert.equal(firstMoc.releases, 1);
  assert.equal(oldModel.releases, 0, 'the shown model is still untouched');
  assert.equal(h.scenes[0].disposed, false);
  assert.equal(h.models.length, 3);
  assert.equal(h.rafPending(), 1);
});

test('a preload superseded while createScene is in flight releases its late scene silently', async () => {
  const h = await loadOld();
  h.holdNextCreateScene = true;

  h.send(preloadCommand);
  await h.flush();
  assert.deepEqual(summary(h.posted), ['ready'], 'the first preload has no reply yet');

  h.send({
    cmd: 'preload',
    loadId: 'load-2',
    modelId: 'model.c',
    model3: NEXT_MODEL3,
    profileRev: 3,
  });
  await h.flush();
  assert.deepEqual(summary(h.posted), ['ready', 'preloaded']);
  assert.equal(h.posted[1].loadId, 'load-2');

  // Let the superseded createScene() resolve: the viewer must dispose that
  // late scene and must not post a reply for load-1.
  h.releaseScene();
  await h.flush();

  assert.deepEqual(summary(h.posted), ['ready', 'preloaded']);
  assert.equal(h.mocs[1].releases, 1, 'the superseded model was released');
  assert.equal(h.models[1].releases, 1);
  const lateScene = h.scenes.find((scene) => scene.model === h.models[1]);
  assert.ok(lateScene);
  assert.equal(lateScene.disposed, true);
  assert.equal(lateScene.disposeCalls, 1);
  assert.equal(h.scenes[0].disposed, false);
  assert.equal(h.rafPending(), 1);
});

test('swap before any preload fails with not_preloaded and leaves the loop running', async () => {
  const h = await loadOld();
  const oldModel = h.models[0];
  h.send({ cmd: 'swap', loadId: 'missing', fadeMs: 100 });

  assert.deepEqual(summary(h.posted), ['ready', 'swap_failed:not_preloaded']);
  assert.equal(h.posted[1].loadId, 'missing');
  assert.equal(oldModel.releases, 0);
  assert.equal(h.scenes[0].disposed, false);
  assert.equal(h.rafPending(), 1);
  const drawMark = h.drawRecords.length;
  const updatesBefore = oldModel.updates;
  h.flushFrame(100);
  assert.equal(oldModel.updates, updatesBefore + 1);
  assert.ok(h.drawRecords.slice(drawMark).some((entry) => entry.modelId === oldModel.id));
});

test('swap cross-fades old 1-t / new t then disposes the old scene and posts swapped', async () => {
  const h = await loadOld();
  const oldModel = h.models[0];
  const oldScene = h.scenes[0];

  // A held setParam on the old animation must not carry to the new one.
  h.send({ cmd: 'setParam', name: 'ParamMouthOpenY', value: 1 });
  h.flushFrame(900);
  assert.equal(oldModel.parameters.values[0], 1, 'old animation holds the override');

  const newParameters = {
    count: 2,
    ids: ['ParamMouthOpenY', 'ParamEyeLOpen'],
    values: [0, 1],
    minimumValues: [0, 0],
    maximumValues: [1, 1],
    defaultValues: [0, 1],
  };
  h.nextModelSpec = {
    parameters: newParameters,
    parts: { count: 1, ids: ['PartHead'] },
  };
  h.send(preloadCommand);
  await h.flush();
  assert.deepEqual(summary(h.posted), ['ready', 'preloaded']);

  const newModel = h.models[1];
  const newScene = h.scenes[1];
  const drawMark = h.drawRecords.length;
  const frameMark = h.calls.filter((entry) => entry.call === 'beginFrame').length;

  h.send({ cmd: 'swap', loadId: 'load-1', fadeMs: 100 });
  assert.equal(h.rafPending(), 1);

  h.flushFrame(1000); // first frame: t = 0
  let sceneDraws = h.drawRecords.slice(drawMark).filter((entry) => entry.kind === 'scene');
  assert.deepEqual(sceneDraws, [
    { kind: 'scene', sceneId: oldScene.id, modelId: oldModel.id, alpha: 1 },
    { kind: 'scene', sceneId: newScene.id, modelId: newModel.id, alpha: 0 },
  ]);
  assert.equal(
    h.calls.filter((entry) => entry.call === 'beginFrame').length - frameMark,
    1,
    'one composite frame per fade step',
  );
  assert.equal(oldModel.releases, 0);
  assert.equal(oldScene.disposed, false);
  assert.equal(h.posted.at(-1).event, 'preloaded', 'no swapped before the fade ends');

  h.flushFrame(1050); // t = 0.5
  sceneDraws = h.drawRecords.slice(drawMark).filter((entry) => entry.kind === 'scene');
  assert.deepEqual(sceneDraws.slice(-2), [
    { kind: 'scene', sceneId: oldScene.id, modelId: oldModel.id, alpha: 0.5 },
    { kind: 'scene', sceneId: newScene.id, modelId: newModel.id, alpha: 0.5 },
  ]);
  assert.equal(oldModel.releases, 0);

  h.flushFrame(1100); // t = 1 and commit
  sceneDraws = h.drawRecords.slice(drawMark).filter((entry) => entry.kind === 'scene');
  assert.deepEqual(sceneDraws.slice(-2), [
    { kind: 'scene', sceneId: oldScene.id, modelId: oldModel.id, alpha: 0 },
    { kind: 'scene', sceneId: newScene.id, modelId: newModel.id, alpha: 1 },
  ]);
  assert.equal(oldScene.disposed, true);
  assert.equal(oldScene.disposeCalls, 1);
  assert.equal(oldModel.releases, 1);
  assert.equal(h.mocs[0].releases, 1);
  assert.equal(newScene.disposed, false);
  assert.equal(newModel.releases, 0);

  assert.deepEqual(summary(h.posted), ['ready', 'preloaded', 'swapped']);
  const swapped = wire(h.posted[2]);
  assert.deepEqual(swapped, {
    event: 'swapped',
    loadId: 'load-1',
    modelId: 'model.b',
    profileRev: 2,
    parameters: [
      { id: 'ParamMouthOpenY', min: 0, max: 1, default: 0 },
      { id: 'ParamEyeLOpen', min: 0, max: 1, default: 1 },
    ],
    parts: ['PartHead'],
    expressions: [],
    motions: [],
  });
  // The new animation starts without the old animation's held override.
  assert.equal(newModel.parameters.values[0], 0);

  // After the commit the loop draws the new model at full alpha and no longer
  // updates the old one.
  const commitsMark = h.drawRecords.length;
  const oldUpdates = oldModel.updates;
  h.flushFrame(1200);
  assert.equal(oldModel.updates, oldUpdates);
  const last = h.drawRecords.at(-1);
  assert.equal(last.kind, 'model');
  assert.equal(last.modelId, newModel.id);
  assert.equal(last.alpha, 1);
  assert.ok(h.drawRecords.length > commitsMark);
  assert.equal(h.rafPending(), 1);
});

test('a failing first new draw rolls back to the old scene and keeps it running', async () => {
  const h = await loadOld();
  const oldModel = h.models[0];
  const oldScene = h.scenes[0];
  h.send(preloadCommand);
  await h.flush();
  const newModel = h.models[1];
  const newScene = h.scenes[1];

  h.drawThrowModel = newModel.id;
  h.send({ cmd: 'swap', loadId: 'load-1', fadeMs: 100 });
  h.flushFrame(1000);

  assert.deepEqual(summary(h.posted), ['ready', 'preloaded', 'swap_failed:render_failed']);
  assert.equal(h.posted[2].loadId, 'load-1');
  assert.match(h.posted[2].message, /draw failed/);
  assert.equal(newScene.disposed, true);
  assert.equal(newScene.disposeCalls, 1);
  assert.equal(newModel.releases, 1);
  assert.equal(h.mocs[1].releases, 1);
  assert.equal(oldScene.disposed, false);
  assert.equal(oldModel.releases, 0);
  assert.equal(h.rafPending(), 1);

  h.drawThrowModel = null;
  const updatesBefore = oldModel.updates;
  const drawMark = h.drawRecords.length;
  h.flushFrame(1100);
  assert.equal(oldModel.updates, updatesBefore + 1);
  const frame = h.drawRecords.slice(drawMark);
  assert.ok(
    frame.some((entry) =>
      entry.kind === 'model' && entry.modelId === oldModel.id && entry.alpha === 1),
    'old model draws at full alpha after rollback',
  );
  assert.equal(h.rafPending(), 1);
});

test('pause stops the frame loop and resume restarts it without releasing anything', async () => {
  const h = await loadOld();
  const oldModel = h.models[0];
  const oldScene = h.scenes[0];

  h.send({ cmd: 'pause' });
  assert.deepEqual(summary(h.posted), ['ready', 'paused']);
  assert.equal(h.rafPending(), 0);
  assert.equal(oldScene.disposed, false);
  assert.equal(oldModel.releases, 0);
  assert.equal(h.flushFrame(100), false);

  h.send({ cmd: 'pause' }); // idempotent: still paused, still nothing released
  assert.deepEqual(summary(h.posted), ['ready', 'paused', 'paused']);
  assert.equal(h.rafPending(), 0);
  assert.equal(oldModel.releases, 0);

  h.send({ cmd: 'resume' });
  assert.deepEqual(summary(h.posted), ['ready', 'paused', 'paused', 'resumed']);
  assert.equal(h.rafPending(), 1);
  const updatesBefore = oldModel.updates;
  h.flushFrame(150);
  assert.equal(oldModel.updates, updatesBefore + 1);

  h.send({ cmd: 'resume' }); // idempotent: no second rAF
  assert.deepEqual(summary(h.posted).at(-1), 'resumed');
  assert.equal(h.rafPending(), 1);
  assert.equal(oldScene.disposed, false);
});

test('swap while paused fails with paused, keeps the preload, and succeeds after resume', async () => {
  const h = await loadOld();
  h.send({ cmd: 'pause' });
  assert.equal(h.rafPending(), 0);

  // Preload is allowed while paused and must not restart the loop.
  h.send(preloadCommand);
  await h.flush();
  assert.deepEqual(summary(h.posted), ['ready', 'paused', 'preloaded']);
  assert.equal(h.rafPending(), 0);
  assert.equal(h.models.length, 2);
  assert.equal(h.scenes.length, 2);

  h.send({ cmd: 'swap', loadId: 'load-1', fadeMs: 100 });
  assert.deepEqual(
    summary(h.posted),
    ['ready', 'paused', 'preloaded', 'swap_failed:paused'],
  );
  assert.equal(h.posted.at(-1).loadId, 'load-1');
  assert.equal(h.scenes[1].disposed, false, 'the preload survives a paused swap');
  assert.equal(h.scenes[0].disposed, false);
  assert.equal(h.rafPending(), 0);

  h.send({ cmd: 'resume' });
  assert.equal(h.rafPending(), 1);
  h.send({ cmd: 'swap', loadId: 'load-1', fadeMs: 0 });
  h.flushFrame(2000);
  assert.deepEqual(
    summary(h.posted),
    ['ready', 'paused', 'preloaded', 'swap_failed:paused', 'resumed', 'swapped'],
  );
  assert.equal(h.scenes[0].disposed, true);
  assert.equal(h.scenes[1].disposed, false);
});

test('dispose during a fade releases both scenes and models and posts nothing further', async () => {
  const h = await loadOld();
  h.send(preloadCommand);
  await h.flush();
  const oldModel = h.models[0];
  const newModel = h.models[1];
  const oldScene = h.scenes[0];
  const newScene = h.scenes[1];

  h.send({ cmd: 'swap', loadId: 'load-1', fadeMs: 100 });
  h.flushFrame(1000);
  assert.equal(oldModel.releases, 0);
  assert.equal(newModel.releases, 0);

  const postsBefore = h.posted.length;
  h.send({ cmd: 'dispose' });

  assert.equal(oldScene.disposed, true);
  assert.equal(newScene.disposed, true);
  assert.equal(oldModel.releases, 1);
  assert.equal(newModel.releases, 1);
  assert.equal(h.mocs[0].releases, 1);
  assert.equal(h.mocs[1].releases, 1);
  assert.ok(h.calls.some((entry) => entry.call === 'renderer.dispose'));
  assert.equal(h.rafPending(), 0);
  assert.equal(h.posted.length, postsBefore, 'dispose posts nothing');

  assert.equal(h.flushFrame(1100), false);
  await h.flush();
  assert.equal(h.posted.length, postsBefore, 'no swapped or failed event after dispose');
});

test('dispose during a preload releases its staged resources and posts nothing', async () => {
  const h = await loadOld();
  h.holdNextCreateScene = true;
  h.send(preloadCommand);
  await h.flush();
  assert.equal(h.models.length, 2, 'the staged model exists while createScene waits');
  const stagedModel = h.models[1];
  const postsBefore = h.posted.length;

  h.send({ cmd: 'dispose' });
  assert.equal(stagedModel.releases, 1);
  assert.equal(h.mocs[1].releases, 1);
  h.releaseScene();
  await h.flush();
  assert.equal(h.posted.length, postsBefore);
  const stagedScene = h.scenes.find((scene) => scene.model === stagedModel);
  if (stagedScene) assert.equal(stagedScene.disposed, true);
});

test('a preload or another swap during a fade is rejected as busy', async () => {
  const h = await loadOld();
  h.send(preloadCommand);
  await h.flush();
  h.send({ cmd: 'swap', loadId: 'load-1', fadeMs: 100 });
  h.flushFrame(1000); // fade is now active

  h.send({
    cmd: 'preload',
    loadId: 'load-2',
    modelId: 'model.c',
    model3: NEXT_MODEL3,
  });
  await h.flush();
  assert.deepEqual(
    summary(h.posted),
    ['ready', 'preloaded', 'preload_failed:busy'],
  );
  assert.equal(h.posted.at(-1).loadId, 'load-2');

  h.send({ cmd: 'swap', loadId: 'load-1', fadeMs: 100 });
  assert.deepEqual(
    summary(h.posted),
    ['ready', 'preloaded', 'preload_failed:busy', 'swap_failed:busy'],
  );
  assert.equal(h.scenes.length, 2, 'no third scene was created during the fade');
  assert.equal(h.scenes[1].disposed, false);

  h.flushFrame(1050);
  h.flushFrame(1100);
  assert.deepEqual(
    summary(h.posted),
    [
      'ready',
      'preloaded',
      'preload_failed:busy',
      'swap_failed:busy',
      'swapped',
    ],
  );
});

test('fadeMs defaults to 250 ms and is clamped to 0..1000', async () => {
  // Default: first frame at 1000 starts the fade, 1125 is half, 1250 commits.
  const h = await loadOld();
  h.send(preloadCommand);
  await h.flush();
  h.send({ cmd: 'swap', loadId: 'load-1' });
  h.flushFrame(1000);
  h.flushFrame(1125);
  let sceneDraws = h.drawRecords.filter((entry) => entry.kind === 'scene');
  assert.deepEqual(sceneDraws.slice(-2).map((entry) => entry.alpha), [0.5, 0.5]);
  h.flushFrame(1250);
  assert.equal(h.posted.at(-1).event, 'swapped');

  // Clamp: 5000 becomes 1000, so a frame 500 ms later is only halfway.
  const clamped = await loadOld();
  clamped.send(preloadCommand);
  await clamped.flush();
  clamped.send({ cmd: 'swap', loadId: 'load-1', fadeMs: 5000 });
  clamped.flushFrame(1000);
  clamped.flushFrame(1500);
  sceneDraws = clamped.drawRecords.filter((entry) => entry.kind === 'scene');
  assert.deepEqual(sceneDraws.slice(-2).map((entry) => entry.alpha), [0.5, 0.5]);
  clamped.flushFrame(2000);
  assert.equal(clamped.posted.at(-1).event, 'swapped');
});