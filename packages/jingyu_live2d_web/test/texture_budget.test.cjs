'use strict';

// Tests for web/live2d_texture_budget.js: PNG size probing and the single
// texture downscale plan that keeps large models inside phone GPU memory.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const BUDGET_FILE = path.join(__dirname, '..', 'web', 'live2d_texture_budget.js');
const budget = require(BUDGET_FILE);

const MiB = 1024 * 1024;

function size(width, height) {
  return { width, height };
}

// First 33 bytes of a PNG file: 8-byte signature, then the IHDR chunk (length
// 13, type, width, height, depth, colour type, 3 method bytes, CRC). The CRC
// stays zero because readPngSize does not check it.
function pngHeader(width, height, padding = 0) {
  const bytes = new Uint8Array(33 + padding);
  const view = new DataView(bytes.buffer);
  bytes.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], 0);
  view.setUint32(8, 13);
  bytes.set([0x49, 0x48, 0x44, 0x52], 12);
  view.setUint32(16, width);
  view.setUint32(20, height);
  bytes.set([8, 6, 0, 0, 0], 24);
  return bytes;
}

test('readPngSize reads width and height from the IHDR chunk', () => {
  assert.deepEqual(budget.readPngSize(pngHeader(4096, 2048)), size(4096, 2048));
  assert.deepEqual(budget.readPngSize(pngHeader(1, 1).buffer), size(1, 1));
  assert.deepEqual(budget.readPngSize(Buffer.from(pngHeader(300, 7, 100))), size(300, 7));
  const widest = pngHeader(0x7fffffff, 513);
  assert.deepEqual(budget.readPngSize(new DataView(widest.buffer)), size(0x7fffffff, 513));
  const file = new Uint8Array(64);
  file.set(pngHeader(640, 480), 11);
  assert.deepEqual(budget.readPngSize(file.subarray(11)), size(640, 480));
});

test('readPngSize rejects data that is not a PNG', () => {
  const jpeg = new Uint8Array(64);
  jpeg.set([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46], 0);
  const idatFirst = pngHeader(16, 16);
  idatFirst.set([0x49, 0x44, 0x41, 0x54], 12);
  const badLength = pngHeader(16, 16);
  new DataView(badLength.buffer).setUint32(8, 12);
  const cases = {
    jpeg,
    html: new TextEncoder().encode('<html><body>404 not found</body></html>'),
    empty: new Uint8Array(0),
    truncated: pngHeader(16, 16).subarray(0, 32),
    idatFirst,
    badLength,
    zeroWidth: pngHeader(0, 16),
    zeroHeight: pngHeader(16, 0),
    tooTall: pngHeader(16, 0x80000000),
  };
  for (const [name, bytes] of Object.entries(cases)) {
    assert.throws(() => budget.readPngSize(bytes), /PNG/, name);
  }
  for (const value of [null, undefined, 'PNG', 42, {}]) {
    assert.throws(() => budget.readPngSize(value), /PNG/, String(value));
  }
});

test('planUniformScale keeps scale 1 when everything fits', () => {
  const sizes = [size(2048, 2048), size(1024, 512)];
  assert.equal(budget.planUniformScale(sizes, 4096, 256 * MiB), 1);
  const plan = budget.planTextureSizes(sizes, 4096, 256 * MiB);
  assert.equal(plan.scale, 1);
  assert.deepEqual(plan.sizes, sizes);
  assert.equal(plan.bytes, ((2048 * 2048 + 1024 * 512) * 16) / 3);
  assert.deepEqual(budget.planTextureSizes([], 4096), {
    scale: 1,
    sizes: [],
    bytes: 0,
    maxTextureSize: 4096,
    budgetBytes: 256 * MiB,
  });
});

test('planUniformScale clamps every texture to maxTextureSize', () => {
  const sizes = [size(8192, 4096), size(4096, 4096), size(1000, 333)];
  assert.equal(budget.planUniformScale(sizes, 4096, Infinity), 0.5);
  assert.deepEqual(budget.planTextureSizes(sizes, 4096, Infinity).sizes, [
    size(4096, 2048),
    size(2048, 2048),
    size(500, 166),
  ]);
  // A limit that is not a power of two: dimensions round down, never below 1.
  const odd = budget.planTextureSizes([size(4096, 4096), size(1000, 333), size(3, 1)], 3000, Infinity);
  assert.equal(odd.scale, 3000 / 4096);
  assert.deepEqual(odd.sizes, [size(3000, 3000), size(732, 243), size(2, 1)]);
});

test('planUniformScale shrinks textures until the mipmapped total fits the budget', () => {
  const four = [size(4096, 4096), size(4096, 4096), size(4096, 4096), size(4096, 4096)];
  // 4 * 4096^2 * 4 bytes * 4/3 is about 341 MiB, over 256 MiB.
  const plan = budget.planTextureSizes(four, 8192, 256 * MiB);
  assert.equal(plan.scale, 3547 / 4096);
  assert.deepEqual(plan.sizes, four.map(() => size(3547, 3547)));
  assert.equal(plan.bytes, budget.estimateBytes(plan.sizes));
  assert.ok(plan.bytes <= 256 * MiB);
  // One more pixel on the edge would not fit.
  assert.ok(budget.estimateBytes(four.map(() => size(3548, 3548))) > 256 * MiB);
  assert.equal(budget.estimateBytes([size(1000, 1)]), 5334);
  assert.equal(budget.estimateBytes([size(1000, 1)], false), 4000);
});

test('planUniformScale defaults to a 256 MiB budget', () => {
  assert.equal(budget.DEFAULT_BUDGET_BYTES, 256 * MiB);
  assert.equal(budget.planUniformScale([size(16384, 16384)], 16384), 7094 / 16384);
  assert.equal(budget.planUniformScale([size(16384, 16384)], 16384, null), 7094 / 16384);
});

test('planUniformScale falls back to 1x1 and rejects budgets below that', () => {
  assert.deepEqual(budget.planTextureSizes([size(64, 64), size(8, 64)], 4096, 11).sizes, [
    size(1, 1),
    size(1, 1),
  ]);
  assert.throws(() => budget.planUniformScale([size(64, 64), size(8, 64)], 4096, 10), RangeError);
});

test('planUniformScale rejects invalid input', () => {
  assert.throws(() => budget.planUniformScale(null, 4096), TypeError);
  assert.throws(() => budget.planUniformScale([size(0, 10)], 4096), RangeError);
  assert.throws(() => budget.planUniformScale([size(10.5, 10)], 4096), RangeError);
  assert.throws(() => budget.planUniformScale([size(10, 10)], 0), RangeError);
  assert.throws(() => budget.planUniformScale([size(10, 10)], NaN), RangeError);
  assert.throws(() => budget.planUniformScale([size(10, 10)], 4096, 0), RangeError);
  assert.throws(() => budget.planUniformScale([size(10, 10)], 4096, -1), RangeError);
});

test('the script also defines window.Live2DTextureBudget for the viewer page', () => {
  const context = vm.createContext({});
  context.window = context;
  vm.runInContext(fs.readFileSync(BUDGET_FILE, 'utf8'), context, { filename: BUDGET_FILE });
  const api = context.window.Live2DTextureBudget;
  assert.equal(typeof api, 'object');
  assert.equal(api.planUniformScale([size(8, 8)], 4), 0.5);
  assert.deepEqual({ ...api.readPngSize(pngHeader(5, 6)) }, size(5, 6));
});

// ---------------------------------------------------------------------------
// web/live2d_renderer_webgl.js loads its textures through the budget.
// ---------------------------------------------------------------------------
const RENDERER_FILE = path.join(__dirname, '..', 'web', 'live2d_renderer_webgl.js');

function jpegBytes() {
  const bytes = new Uint8Array(64);
  bytes.set([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46], 0);
  return bytes;
}

// WebGL stand-in: upper-case members are distinct numeric constants (NO_ERROR
// is 0); any other member is a function that records the call and returns a
// fresh object. Enough for shader setup, an empty model and textures.
function fakeGl(maxTextureSize, log) {
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
          const result = { glCall: name, id: calls.length };
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

// Loads the budget script (unless withBudget is false) and the renderer into
// one VM window with fake fetch and createImageBitmap. files maps texture URLs
// to bytes; the fake decoder reads the PNG header size and applies resizes.
function loadRenderer({ files = {}, webgl2 = true, maxTextureSize = 4096, withBudget = true } = {}) {
  const h = { log: [], warnings: [], infos: [], decodeOptions: [], onDecode: null };
  const { gl, calls } = fakeGl(maxTextureSize, h.log);
  const blobUrls = new WeakMap();
  h.gl = gl;
  h.calls = calls;
  h.canvas = {
    width: 300,
    height: 150,
    clientWidth: 300,
    clientHeight: 150,
    getContext: (type) => (type === 'webgl2' && !webgl2 ? null : gl),
    addEventListener() {},
  };
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
      if (!Object.hasOwn(files, url)) return { ok: false, status: 404, blob: async () => new Blob([]) };
      const blob = new Blob([files[url]]);
      blobUrls.set(blob, url);
      return { ok: true, status: 200, blob: async () => blob };
    },
    createImageBitmap: async (blob, options) => {
      const url = blobUrls.get(blob);
      h.log.push('decode ' + url);
      h.decodeOptions.push({ ...options });
      if (h.onDecode) h.onDecode(url);
      const png = budget.readPngSize(new Uint8Array(await blob.slice(0, 33).arrayBuffer()));
      // h.ignoreResize mimics a decoder that ignores the resize options.
      const resize = !h.ignoreResize;
      return {
        url,
        width: (resize && options.resizeWidth) || png.width,
        height: (resize && options.resizeHeight) || png.height,
        close: () => h.log.push('close ' + url),
      };
    },
  });
  context.window = context;
  if (withBudget) {
    vm.runInContext(fs.readFileSync(BUDGET_FILE, 'utf8'), context, { filename: BUDGET_FILE });
  }
  vm.runInContext(fs.readFileSync(RENDERER_FILE, 'utf8'), context, { filename: RENDERER_FILE });
  h.renderer = context.Live2DRenderer;
  h.prepare = async (urls, options) => ({ ...(await h.renderer.prepare(h.canvas, {}, urls, options)) });
  h.uploads = () => calls.filter((c) => c.name === 'texImage2D').map((c) => c.args[5].url);
  h.minFilters = () =>
    calls
      .filter((c) => c.name === 'texParameteri' && c.args[1] === gl.TEXTURE_MIN_FILTER)
      .map((c) => c.args[2]);
  return h;
}

test('renderer reads every PNG size first, then decodes and uploads one texture at a time', async () => {
  const h = loadRenderer({ files: { 'a.png': pngHeader(1024, 1024), 'b.png': pngHeader(512, 256) } });
  const result = await h.prepare(['a.png', 'b.png']);
  assert.deepEqual(h.log, [
    'fetch a.png',
    'fetch b.png',
    'decode a.png',
    'upload a.png',
    'mipmap',
    'close a.png',
    'decode b.png',
    'upload b.png',
    'mipmap',
    'close b.png',
  ]);
  // Everything fits: no resize, straight alpha like the old Image upload.
  assert.deepEqual(h.decodeOptions, [{ premultiplyAlpha: 'none' }, { premultiplyAlpha: 'none' }]);
  assert.deepEqual(h.minFilters(), [h.gl.LINEAR_MIPMAP_LINEAR, h.gl.LINEAR_MIPMAP_LINEAR]);
  const bytes = budget.estimateBytes([size(1024, 1024), size(512, 256)]);
  assert.equal(result.ok, true);
  assert.equal(result.textures, 2);
  assert.equal(result.loadedTextures, 2);
  assert.equal(result.textureCount, 2);
  assert.equal(result.textureScale, 1);
  assert.equal(result.maxTextureSize, 4096);
  assert.equal(result.textureBytes, bytes);
  assert.equal(result.textureBudgetBytes, 256 * MiB);
  const diagnostics = h.renderer.diagnostics();
  assert.equal(diagnostics.textureScale, 1);
  assert.equal(diagnostics.maxTextureSize, 4096);
  assert.equal(diagnostics.textureBytes, bytes);
  assert.equal(diagnostics.textureCount, 2);
  assert.match(
    h.infos.join('\n'),
    new RegExp('textures=2/2 textureScale=1 textureBytes=' + bytes + ' maxTextureSize=4096'),
  );
  assert.deepEqual(h.warnings, []);
});

test('renderer downscales all textures with one plan for the size limit and the budget', async () => {
  const files = { 'big.png': pngHeader(4096, 4096), 'small.png': pngHeader(1000, 333) };
  const h = loadRenderer({ files, maxTextureSize: 2048 });
  const result = await h.prepare(['big.png', 'small.png']);
  assert.equal(result.textureScale, 0.5);
  assert.equal(result.maxTextureSize, 2048);
  assert.equal(result.textureBytes, budget.estimateBytes([size(2048, 2048), size(500, 166)]));
  assert.deepEqual(h.decodeOptions, [
    { premultiplyAlpha: 'none', resizeWidth: 2048, resizeHeight: 2048, resizeQuality: 'high' },
    { premultiplyAlpha: 'none', resizeWidth: 500, resizeHeight: 166, resizeQuality: 'high' },
  ]);
  assert.deepEqual(h.warnings, []);

  // Options can lower the budget and the size limit but never raise the limit.
  const plan = budget.planTextureSizes([size(4096, 4096), size(1000, 333)], 2048, 4 * MiB);
  const lowered = await h.prepare(['big.png', 'small.png'], {
    maxTextureSize: 8192,
    textureBudgetBytes: 4 * MiB,
  });
  assert.ok(plan.scale < 0.5);
  assert.equal(lowered.textureScale, plan.scale);
  assert.equal(lowered.maxTextureSize, 2048);
  assert.equal(lowered.textureBudgetBytes, 4 * MiB);
  assert.equal(lowered.textureBytes, plan.bytes);
  const capped = await h.prepare(['big.png'], { maxTextureSize: 1024 });
  assert.equal(capped.maxTextureSize, 1024);
  assert.equal(capped.textureScale, 0.25);
});

test('renderer skips textures that fail to load or are not PNG', async () => {
  const h = loadRenderer({ files: { 'photo.jpg': jpegBytes(), 'ok.png': pngHeader(64, 64) } });
  const result = await h.prepare(['missing.png', 'photo.jpg', 'ok.png']);
  assert.equal(result.ok, true);
  assert.equal(result.textures, 3);
  assert.equal(result.loadedTextures, 1);
  assert.equal(result.textureCount, 1);
  assert.equal(result.textureBytes, budget.estimateBytes([size(64, 64)]));
  assert.deepEqual(h.uploads(), ['ok.png']);
  assert.equal(h.warnings.length, 2);
  assert.equal(h.warnings[0], '[Live2DRenderer] texture load failed: missing.png');
  assert.match(h.warnings[1], /photo\.jpg.*not a PNG/);
});

test('renderer does not load textures without the budget script', async () => {
  const h = loadRenderer({ files: { 'a.png': pngHeader(8, 8) }, withBudget: false });
  assert.deepEqual(await h.prepare(['a.png']), { ok: false, reason: 'texture-budget-unavailable' });
  assert.deepEqual(h.log, []);
  assert.match(h.warnings.join('\n'), /live2d_texture_budget\.js/);
});

test('renderer builds mipmaps on WebGL1 only for power-of-two textures', async () => {
  const h = loadRenderer({
    files: { 'npot.png': pngHeader(1000, 500), 'pot.png': pngHeader(256, 256) },
    webgl2: false,
  });
  const result = await h.prepare(['npot.png', 'pot.png']);
  assert.equal(result.webgl, 1);
  assert.deepEqual(h.minFilters(), [h.gl.LINEAR, h.gl.LINEAR_MIPMAP_LINEAR]);
  assert.equal(h.log.filter((entry) => entry === 'mipmap').length, 1);
  assert.equal(result.textureBytes, 1000 * 500 * 4 + budget.estimateBytes([size(256, 256)]));
});

test('renderer deletes uploaded textures when disposed while loading', async () => {
  const h = loadRenderer({ files: { 'a.png': pngHeader(64, 64), 'b.png': pngHeader(64, 64) } });
  h.onDecode = (url) => {
    if (url === 'b.png') h.renderer.dispose();
  };
  assert.deepEqual(await h.prepare(['a.png', 'b.png']), { ok: false, reason: 'disposed' });
  const created = h.calls.filter((c) => c.name === 'createTexture').map((c) => c.result);
  const deleted = h.calls.filter((c) => c.name === 'deleteTexture').map((c) => c.args[0]);
  assert.equal(created.length, 1);
  assert.deepEqual(deleted, created);
  assert.equal(h.log.at(-1), 'close b.png');
  assert.equal(h.renderer.diagnostics().ready, false);
  assert.equal(h.renderer.diagnostics().loadedTextures, 0);
  assert.deepEqual(h.warnings, []);
});

test('renderer rejects a texture that decodes larger than planned', async () => {
  const h = loadRenderer({ files: { 'big.png': pngHeader(4096, 4096) }, maxTextureSize: 2048 });
  h.ignoreResize = true;
  const result = await h.prepare(['big.png']);
  assert.equal(result.ok, true);
  assert.equal(result.loadedTextures, 0);
  assert.equal(result.textureCount, 0);
  assert.equal(result.textureBytes, 0);
  assert.deepEqual(h.uploads(), []);
  assert.equal(h.log.at(-1), 'close big.png');
  assert.match(h.warnings.join('\n'), /big\.png decoded at 4096x4096, planned 2048x2048/);
});
