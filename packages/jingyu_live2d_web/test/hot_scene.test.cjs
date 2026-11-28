'use strict';

// Multi-scene (hot switch) tests for web/live2d_renderer_webgl.js.
//
// Two scenes share one canvas, WebGL context and shader programs while each
// owns its textures, geometry cache, fit and byte estimate. draw(scene, alpha)
// sets the new u_alpha uniform; draw(model) keeps the old single-scene call
// working. The GL stand-in records calls, like texture_budget.test.cjs.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const MiB = 1024 * 1024;
const BUDGET_FILE = path.join(__dirname, '..', 'web', 'live2d_texture_budget.js');
const RENDERER_FILE = path.join(__dirname, '..', 'web', 'live2d_renderer_webgl.js');
const budget = require(BUDGET_FILE);

function pngHeader(width, height) {
  const bytes = new Uint8Array(33);
  const view = new DataView(bytes.buffer);
  bytes.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], 0);
  view.setUint32(8, 13);
  bytes.set([0x49, 0x48, 0x44, 0x52], 12);
  view.setUint32(16, width);
  view.setUint32(20, height);
  bytes.set([8, 6, 0, 0, 0], 24);
  return bytes;
}

function size(width, height) {
  return { width, height };
}

// WebGL stand-in: upper-case members are distinct numeric constants; other
// members are recording functions. getUniformLocation objects remember their
// uniform name so the tests can read u_alpha back.
function fakeGl(maxTextureSize, log, uniformNames) {
  const calls = [];
  const constants = new Map([['NO_ERROR', 0]]);
  const overrides = {
    then: undefined,
    getError: () => 0,
    getParameter: (name) => (name === gl.MAX_TEXTURE_SIZE ? maxTextureSize : null),
    getShaderParameter: () => true,
    getProgramParameter: () => true,
    getShaderInfoLog: () => '',
    getProgramInfoLog: () => '',
    getAttribLocation: () => 0,
    isContextLost: () => false,
    getUniformLocation: (program, name) => {
      const location = { glCall: 'uniformLocation', uniform: name, id: calls.length };
      uniformNames.set(location, name);
      return location;
    },
  };
  const gl = new Proxy(
    {},
    {
      get(target, name) {
        if (typeof name !== 'string') return undefined;
        if (Object.hasOwn(overrides, name)) return overrides[name];
        if (/^[A-Z][A-Z0-9_]*$/.test(name)) {
          if (!constants.has(name)) constants.set(name, 0x1000 + constants.size);
          return constants.get(name);
        }
        return (...args) => {
          const result = { glCall: name, id: calls.length, kind: name };
          calls.push({ name, args, result });
          if (name === 'texImage2D') log.push('upload ' + args[5].url);
          if (name === 'generateMipmap') log.push('mipmap');
          return result;
        };
      },
    },
  );
  return { gl, calls };
}

// Loads the budget + renderer into one VM window. One canvas/context is shared
// by every createScene() call; getContextCalls() counts how many were created.
function loadRenderer({ files = {}, webgl2 = true, maxTextureSize = 4096 } = {}) {
  const h = {
    log: [],
    warnings: [],
    infos: [],
    decodes: [],
    uploads: [],
    getContextCalls: 0,
  };
  const uniformNames = new Map();
  const { gl, calls } = fakeGl(maxTextureSize, h.log, uniformNames);
  h.gl = gl;
  h.calls = calls;
  h.canvas = {
    width: 300,
    height: 150,
    clientWidth: 300,
    clientHeight: 150,
    getContext(type) {
      h.getContextCalls += 1;
      if (type === 'webgl2' && webgl2) return gl;
      if (type === 'webgl' && !webgl2) return gl;
      return null;
    },
    addEventListener() {},
  };
  const blobUrls = new WeakMap();
  const context = vm.createContext({
    console: {
      info: (message) => h.infos.push(String(message)),
      warn: (message) => h.warnings.push(String(message)),
      log() {},
      error() {},
    },
    devicePixelRatio: 1,
    fetch: async (url) => {
      h.log.push('fetch ' + url);
      if (!Object.hasOwn(files, url)) {
        return { ok: false, status: 404, blob: async () => new Blob([]) };
      }
      const blob = new Blob([files[url]]);
      blobUrls.set(blob, url);
      return { ok: true, status: 200, blob: async () => blob };
    },
    createImageBitmap: async (blob, options) => {
      const url = blobUrls.get(blob);
      h.log.push('decode ' + url);
      h.decodes.push(url);
      const png = budget.readPngSize(
        new Uint8Array(await blob.slice(0, 33).arrayBuffer()),
      );
      return {
        url,
        width: options.resizeWidth || png.width,
        height: options.resizeHeight || png.height,
        close: () => h.log.push('close ' + url),
      };
    },
  });
  context.window = context;
  vm.runInContext(fs.readFileSync(BUDGET_FILE, 'utf8'), context, {
    filename: BUDGET_FILE,
  });
  vm.runInContext(fs.readFileSync(RENDERER_FILE, 'utf8'), context, {
    filename: RENDERER_FILE,
  });
  h.renderer = context.Live2DRenderer;
  h.createScene = (model, urls, options) =>
    h.renderer.createScene(h.canvas, model, urls, options);
  h.mark = () => calls.length;
  h.since = (mark, name) =>
    calls.slice(mark).filter((entry) => entry.name === name);
  h.uniformValues = (mark, uniform) =>
    calls
      .slice(mark)
      .filter(
        (entry) =>
          entry.name === 'uniform1f' && uniformNames.get(entry.args[0]) === uniform,
      )
      .map((entry) => entry.args[1]);
  h.lastUniform = (uniform) => {
    for (let i = calls.length - 1; i >= 0; i -= 1) {
      const entry = calls[i];
      if (
        entry.name === 'uniform1f' &&
        uniformNames.get(entry.args[0]) === uniform
      ) {
        return entry.args[1];
      }
    }
    return undefined;
  };
  return h;
}

// Two drawables per model, both on texture slot 0: proves the scene's own
// texture array is bound (twice), not a global one.
function fakeModel(label) {
  return {
    label,
    renderOrders: [0, 1],
    drawables: {
      count: 2,
      vertexPositions: [
        new Float32Array([-50, 50, 50, 50, 0, -50]),
        new Float32Array([-20, 20, 20, 20, 0, -20]),
      ],
      vertexUvs: [
        new Float32Array([0, 0, 1, 0, 0.5, 1]),
        new Float32Array([0, 0, 1, 0, 0.5, 1]),
      ],
      indices: [new Uint16Array([0, 1, 2]), new Uint16Array([0, 1, 2])],
      textureIndices: [0, 0],
      constantFlags: [0, 0],
      masks: [null, null],
      opacities: new Float32Array([1, 1]),
      dynamicFlags: new Uint8Array([3, 3]),
      multiplyColors: new Float32Array([1, 1, 1, 1, 1, 1, 1, 1]),
      screenColors: new Float32Array([0, 0, 0, 0, 0, 0, 0, 0]),
    },
  };
}

test('two scenes share one canvas, context and program pair but own their textures and fit', async () => {
  const h = loadRenderer({
    files: { 'a.png': pngHeader(64, 64), 'b.png': pngHeader(128, 128) },
  });
  const modelA = fakeModel('a');
  const modelB = fakeModel('b');
  const sc0 = await h.createScene(modelA, ['a.png']);
  const sc1 = await h.createScene(modelB, ['b.png']);

  assert.ok(sc0, 'first scene created');
  assert.ok(sc1, 'second scene created');
  assert.equal(h.renderer.lastError, null);
  assert.equal(h.getContextCalls, 1, 'one WebGL context');
  assert.equal(h.since(0, 'createProgram').length, 2, 'one draw + one mask program');
  assert.equal(sc0.glVersion, 2);
  assert.equal(sc1.glVersion, 2);
  assert.equal(sc0.textures.length, 1);
  assert.equal(sc1.textures.length, 1);
  assert.notEqual(sc0.textures[0], sc1.textures[0]);
  assert.notEqual(sc0.fit, sc1.fit, 'each scene owns its camera fit');
  assert.equal(sc0.model, modelA);
  assert.equal(sc1.model, modelB);
  assert.equal(sc0.bytes, budget.estimateBytes([size(64, 64)]));
  assert.equal(sc1.bytes, budget.estimateBytes([size(128, 128)]));
  assert.equal(h.renderer.diagnostics().liveScenes, 2);
  assert.deepEqual(h.warnings, []);
});

test('draw(scene, alpha) sets u_alpha and draw(scene) defaults to 1', async () => {
  const h = loadRenderer({ files: { 'a.png': pngHeader(32, 32) } });
  const sc0 = await h.createScene(fakeModel('a'), ['a.png']);
  assert.ok(sc0);
  const fragment = h
    .since(0, 'shaderSource')
    .map((entry) => entry.args[1])
    .find((source) => source.includes('u_alpha'));
  assert.ok(fragment, 'fragment shader declares u_alpha');
  assert.match(fragment, /premultiplied \* u_alpha/);

  let mark = h.mark();
  h.renderer.draw(sc0);
  assert.deepEqual(h.uniformValues(mark, 'u_alpha'), [1, 1]);

  mark = h.mark();
  h.renderer.draw(sc0, 0.25);
  assert.deepEqual(h.uniformValues(mark, 'u_alpha'), [0.25, 0.25]);
  assert.equal(h.lastUniform('u_alpha'), 0.25);

  mark = h.mark();
  h.renderer.draw(sc0, 2.5);
  assert.deepEqual(h.uniformValues(mark, 'u_alpha'), [1, 1], 'alpha clamps to 1');

  mark = h.mark();
  h.renderer.draw(sc0, undefined);
  assert.deepEqual(h.uniformValues(mark, 'u_alpha'), [1, 1], 'omitted alpha is 1');
});

test('draw(sc1, 0.5) uses scene 1 textures, then beginFrame composites both scenes', async () => {
  const h = loadRenderer({
    files: { 'a.png': pngHeader(16, 16), 'b.png': pngHeader(16, 16) },
  });
  const sc0 = await h.createScene(fakeModel('a'), ['a.png']);
  const sc1 = await h.createScene(fakeModel('b'), ['b.png']);
  assert.ok(sc0 && sc1);
  const all = [sc0.textures[0], sc1.textures[0]];

  let mark = h.mark();
  h.renderer.draw(sc1, 0.5);
  assert.equal(h.lastUniform('u_alpha'), 0.5);
  const bound = h.since(mark, 'bindTexture').map((entry) => entry.args[1]);
  assert.equal(bound.length, 2);
  for (const texture of bound) {
    assert.ok(all.includes(texture), 'only scene textures are bound');
    assert.equal(texture, sc1.textures[0], 'scene 1 texture, not scene 0');
  }

  mark = h.mark();
  h.renderer.beginFrame();
  h.renderer.draw(sc0, 0.75);
  h.renderer.draw(sc1, 0.25);
  h.renderer.endFrame();
  assert.equal(h.since(mark, 'clear').length, 1, 'one clear for the whole frame');
  assert.deepEqual(h.uniformValues(mark, 'u_alpha'), [0.75, 0.75, 0.25, 0.25]);
});

test('draw(model) keeps working and selects the current or matching scene', async () => {
  const h = loadRenderer({
    files: { 'a.png': pngHeader(16, 16), 'b.png': pngHeader(16, 16) },
  });
  const modelA = fakeModel('a');
  const modelB = fakeModel('b');
  const prepared = await h.renderer.prepare(h.canvas, modelA, ['a.png']);
  assert.equal(prepared.ok, true);
  const created = h.since(0, 'createTexture').map((entry) => entry.result);
  assert.equal(created.length, 1);

  let mark = h.mark();
  h.renderer.draw(modelA);
  assert.equal(h.lastUniform('u_alpha'), 1);
  assert.deepEqual(
    h.since(mark, 'bindTexture').map((entry) => entry.args[1]),
    [created[0], created[0]],
    'legacy draw uses the scene prepare() created',
  );

  const sc1 = await h.createScene(modelB, ['b.png']);
  assert.ok(sc1);
  assert.equal(h.getContextCalls, 1, 'createScene reuses the prepared context');
  assert.notEqual(sc1.textures[0], created[0]);
  mark = h.mark();
  h.renderer.draw(modelB);
  assert.deepEqual(
    h.since(mark, 'bindTexture').map((entry) => entry.args[1]),
    [sc1.textures[0], sc1.textures[0]],
    'legacy draw finds the scene matching the model',
  );
});

test('disposeScene frees only that scene\'s buffers and textures', async () => {
  const h = loadRenderer({
    files: { 'a.png': pngHeader(16, 16), 'b.png': pngHeader(16, 16) },
  });
  const sc0 = await h.createScene(fakeModel('a'), ['a.png']);
  const sc1 = await h.createScene(fakeModel('b'), ['b.png']);
  assert.ok(sc0 && sc1);
  const sc1Texture = sc1.textures[0];
  const sc0Texture = sc0.textures[0];

  let mark = h.mark();
  assert.equal(h.renderer.disposeScene(sc1), true);
  assert.deepEqual(
    h.since(mark, 'deleteTexture').map((entry) => entry.args[0]),
    [sc1Texture],
  );
  assert.ok(h.since(mark, 'deleteBuffer').length > 0, 'geometry buffers freed');
  assert.equal(sc1.disposed, true);
  assert.equal(sc0.disposed, false);
  assert.equal(h.renderer.diagnostics().liveScenes, 1);
  assert.equal(h.renderer.totalLiveBytes(), sc0.bytes);
  assert.equal(h.renderer.sceneBytes(sc1), 0);

  mark = h.mark();
  h.renderer.draw(sc0);
  assert.deepEqual(
    h.since(mark, 'bindTexture').map((entry) => entry.args[1]),
    [sc0Texture, sc0Texture],
    'remaining scene still draws',
  );
  assert.equal(h.since(mark, 'deleteTexture').length, 0);
});

test('dispose frees every scene, both programs and the shared context', async () => {
  const h = loadRenderer({
    files: { 'a.png': pngHeader(16, 16), 'b.png': pngHeader(16, 16) },
  });
  const sc0 = await h.createScene(fakeModel('a'), ['a.png']);
  const sc1 = await h.createScene(fakeModel('b'), ['b.png']);
  assert.ok(sc0 && sc1);
  const textures = [sc0.textures[0], sc1.textures[0]];

  const mark = h.mark();
  h.renderer.dispose();
  const deleted = h.since(mark, 'deleteTexture').map((entry) => entry.args[0]);
  assert.deepEqual(deleted, textures);
  assert.equal(h.since(mark, 'deleteProgram').length, 2);
  assert.equal(h.renderer.diagnostics().liveScenes, 0);
  assert.equal(h.renderer.diagnostics().ready, false);
  assert.equal(h.renderer.diagnostics().textures, 0);
  assert.equal(h.renderer.totalLiveBytes(), 0);
  assert.equal(h.renderer.sceneBytes(sc0), 0);
});

test('a second scene is refused before decode/upload when the combined budget is full', async () => {
  const budgetBytes = 512 * 1024;
  const h = loadRenderer({
    files: { 'a.png': pngHeader(256, 256), 'b.png': pngHeader(256, 256) },
  });
  const sc0 = await h.createScene(fakeModel('a'), ['a.png'], {
    textureBudgetBytes: budgetBytes,
  });
  assert.ok(sc0);
  assert.equal(sc0.textureBytes, budget.estimateBytes([size(256, 256)]));

  const mark = h.mark();
  const sc1 = await h.createScene(fakeModel('b'), ['b.png'], {
    textureBudgetBytes: budgetBytes,
  });
  assert.equal(sc1, null, 'refused');
  assert.equal(h.renderer.lastError, 'texture_budget');
  assert.deepEqual(h.since(mark, 'texImage2D'), [], 'nothing uploaded');
  assert.deepEqual(h.since(mark, 'createTexture'), [], 'no texture created');
  assert.deepEqual(h.decodes, ['a.png'], 'second texture never decoded');
  assert.equal(h.renderer.diagnostics().liveScenes, 1);
  assert.equal(h.renderer.totalLiveBytes(), sc0.textureBytes);
  assert.match(h.warnings.join('\n'), /texture budget exceeded/);

  assert.equal(
    h.renderer.canBeAdded(sc0.textureBytes, { bytes: sc0.textureBytes }, budgetBytes),
    false,
  );
  assert.equal(
    h.renderer.canBeAdded(0, { textureBytes: 1024 }, budgetBytes),
    true,
  );
});

test('sceneBytes sums the live scenes and canBeAdded checks the shared budget', async () => {
  const h = loadRenderer({
    files: { 'a.png': pngHeader(64, 64), 'b.png': pngHeader(32, 32) },
  });
  const sc0 = await h.createScene(fakeModel('a'), ['a.png']);
  const sc1 = await h.createScene(fakeModel('b'), ['b.png']);
  assert.ok(sc0 && sc1);

  assert.equal(h.renderer.sceneBytes(sc0), sc0.textureBytes);
  assert.equal(h.renderer.sceneBytes(sc1), sc1.textureBytes);
  assert.equal(
    h.renderer.sceneBytes(sc0) + h.renderer.sceneBytes(sc1),
    h.renderer.totalLiveBytes(),
  );
  assert.equal(sc0.textureBytes, budget.estimateBytes([size(64, 64)]));
  assert.equal(sc1.textureBytes, budget.estimateBytes([size(32, 32)]));
  assert.equal(
    h.renderer.totalLiveBytes(),
    sc0.textureBytes + sc1.textureBytes,
    'per-scene estimates, each rounded up',
  );

  const total = h.renderer.totalLiveBytes();
  assert.equal(h.renderer.canBeAdded(total - sc1.textureBytes, sc1, total), true);
  assert.equal(h.renderer.canBeAdded(total - sc1.textureBytes, sc1, total - 1), false);
  assert.equal(h.renderer.diagnostics().totalTextureBytes, total);
});