import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdir, readFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { fileURLToPath } from 'node:url';
import { after, before, test } from 'node:test';
import { chromium } from 'playwright-core';

const local = (path) => new URL(path, import.meta.url);
const scratch = fileURLToPath(local('.cache/'));
const routes = new Map([
  ['/', ['text/html', () => `<!doctype html><meta charset="utf-8">
    <title>VRM first-frame smoke (synthetic test data)</title>
    <link rel="icon" href="data:,">
    <script type="importmap">{"imports":{
      "three":"/three/build/three.module.js",
      "three/addons/":"/three/examples/jsm/",
      "@pixiv/three-vrm":"/three-vrm.module.js"
    }}</script>
    <canvas width="320" height="240"></canvas>`]],
  ...Object.entries({
    '/preview.mjs': './preview.mjs',
    '/three/build/three.module.js': './node_modules/three/build/three.module.js',
    '/three/build/three.core.js': './node_modules/three/build/three.core.js',
    '/three/examples/jsm/loaders/GLTFLoader.js': './node_modules/three/examples/jsm/loaders/GLTFLoader.js',
    '/three/examples/jsm/utils/BufferGeometryUtils.js': './node_modules/three/examples/jsm/utils/BufferGeometryUtils.js',
    '/three-vrm.module.js': './node_modules/@pixiv/three-vrm/lib/three-vrm.module.js',
  }).map(([path, file]) => [path, ['text/javascript', () => readFile(local(file))]]),
  ...Object.entries({
    '/synthetic.vrm': 'visible',
    '/blank.vrm': 'blank',
    '/plain.glb': 'plain',
    '/external.vrm': 'external',
  }).map(([path, kind]) => [path, ['model/gltf-binary', async () => {
    const { syntheticGlb } = await import('./synthetic-fixture.mjs');
    return syntheticGlb(kind);
  }]]),
  ['/malformed.vrm', ['model/gltf-binary', () => 'not a GLB']],
]);
const missing = '/missing.vrm';
let server, origin, browser;

before(async () => {
  await mkdir(scratch, { recursive: true });
  process.env.TMP = process.env.TEMP = scratch;
  server = createServer(async (request, response) => {
    const route = request.method === 'GET' && routes.get(request.url);
    const [type, body] = route || [];
    response.setHeader('Content-Security-Policy', [
      "default-src 'none'", "script-src 'self' 'unsafe-inline'", "connect-src 'self'",
      "img-src data:", "base-uri 'none'", "frame-ancestors 'none'", "form-action 'none'",
    ].join('; '));
    response.setHeader('Cache-Control', 'no-store');
    try {
      if (!route) return response.writeHead(404).end();
      const bytes = await body();
      response.writeHead(200, { 'Content-Type': type }).end(bytes);
    } catch (error) {
      if (error.code !== 'ENOENT') console.error(error);
      response.writeHead(error.code === 'ENOENT' ? 404 : 500).end();
    }
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  origin = `http://127.0.0.1:${server.address().port}`;
  browser = await chromium.launch({
    channel: 'msedge',
    chromiumSandbox: true,
    args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--disable-background-networking',
      '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1', '--no-proxy-server'],
  });
});

after(async () => {
  try {
    await browser?.close();
  } finally {
    if (server?.listening) await new Promise((resolve, reject) => {
      server.close((error) => error ? reject(error) : resolve());
    });
  }
});

async function openPage(t) {
  const context = await browser.newContext({
    viewport: { width: 640, height: 480 }, deviceScaleFactor: 1, serviceWorkers: 'block',
  });
  t.after(() => context.close());
  const blocked = [], pageErrors = [], requested = [];
  await context.route('**/*', (route) => {
    const url = new URL(route.request().url());
    if (url.origin !== origin || url.search || (!routes.has(url.pathname) && url.pathname !== missing)) {
      blocked.push(url.href);
      return route.abort('blockedbyclient');
    }
    requested.push(url.pathname);
    return route.continue();
  });
  const page = await context.newPage();
  page.on('pageerror', (error) => pageErrors.push(error.message));
  await page.addInitScript(() => {
    globalThis.cspViolations = [];
    document.addEventListener('securitypolicyviolation', ({ blockedURI }) => cspViolations.push(blockedURI));
  });
  await page.goto(origin);
  const checkLocal = async () => {
    assert.deepEqual(blocked, [], 'no requests outside the exact loopback allowlist');
    assert.deepEqual(await page.evaluate(() => cspViolations), [], 'no CSP-blocked resource attempts');
    assert.deepEqual(pageErrors, [], 'no uncaught browser errors');
  };
  return { page, requested, checkLocal };
}

test('a local VRM rig paints a framed, nonblank WebGL2 first frame', { timeout: 30_000 }, async (t) => {
  const { page, requested, checkLocal } = await openPage(t);
  const model = page.waitForResponse(`${origin}/synthetic.vrm`, { timeout: 10_000 });
  // An import failure must fail the behavior assertion, not leave a pending request waiter.
  const modelResult = model.then((response) => response, () => null);
  const result = await page.evaluate(async () => {
    try {
      const { loadFirstFrame } = await import('/preview.mjs');
      const canvas = document.querySelector('canvas');
      globalThis.preview = await loadFirstFrame(canvas, '/synthetic.vrm');
      const gl = canvas.getContext('webgl2');
      const width = gl.drawingBufferWidth, height = gl.drawingBufferHeight;
      const pixels = new Uint8Array(width * height * 4);
      gl.readPixels(0, 0, width, height, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
      const pixel = (x, y) => Array.from(pixels.subarray((y * width + x) * 4, (y * width + x) * 4 + 4));
      let covered = 0, minX = width, minY = height, maxX = -1, maxY = -1;
      for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
        if (pixels[(y * width + x) * 4 + 3] === 0) continue;
        covered++;
        minX = Math.min(minX, x); maxX = Math.max(maxX, x);
        minY = Math.min(minY, y); maxY = Math.max(maxY, y);
      }
      const debug = gl.getExtension('WEBGL_debug_renderer_info');
      return {
        width, height, covered, bounds: [minX, minY, maxX, maxY],
        head: pixel(160, 198), torso: pixel(160, 146), corner: pixel(4, 4),
        errorCode: gl.getError(), webgl: gl.getParameter(gl.VERSION),
        renderer: gl.getParameter(debug ? debug.UNMASKED_RENDERER_WEBGL : gl.RENDERER),
        vendor: gl.getParameter(debug ? debug.UNMASKED_VENDOR_WEBGL : gl.VENDOR),
        metaVersion: preview.vrm.meta.metaVersion,
        headBone: preview.vrm.humanoid.getRawBoneNode('head')?.name,
        skinned: Boolean(preview.vrm.scene.getObjectByProperty('isSkinnedMesh', true)),
      };
    } catch (error) {
      return { failure: String(error) };
    }
  });
  assert.equal(result.failure, undefined, 'the local renderer produces a first frame');
  const response = await modelResult;
  assert.ok(response?.ok(), 'the browser fetched the same-origin VRM bytes');
  const fixture = await response.body();
  assert.equal(fixture.toString('ascii', 0, 4), 'glTF');
  assert.equal(result.metaVersion, '1');
  assert.equal(result.headBone, 'head');
  assert.equal(result.skinned, true);
  assert.deepEqual([result.width, result.height, result.errorCode], [320, 240, 0]);
  assert.ok(result.covered > 3_000 && result.covered < 25_000, `visible silhouette: ${result.covered} pixels`);
  const [left, bottom, right, top] = result.bounds;
  assert.ok(left > 12 && bottom > 8 && right < 307 && top < 232, `not clipped: ${result.bounds}`);
  const [hr, hg, hb, ha] = result.head;
  assert.ok(hb > hg && hb > hr + 80 && ha === 255, `blue head probe: ${result.head}`);
  const [tr, tg, tb, ta] = result.torso;
  assert.ok(tr > tg && tg > tb && tr > tb + 80 && ta === 255, `orange torso probe: ${result.torso}`);
  assert.deepEqual(result.corner, [0, 0, 0, 0]);

  await page.locator('canvas').screenshot({ path: fileURLToPath(local('.cache/first-frame.png')) });
  const disposal = await page.evaluate(() => {
    const gl = document.querySelector('canvas').getContext('webgl2');
    const mesh = preview.vrm.scene.getObjectByProperty('isSkinnedMesh', true);
    let geometry = 0, material = 0;
    mesh.geometry.addEventListener('dispose', () => geometry++);
    mesh.material.addEventListener('dispose', () => material++);
    preview.dispose();
    preview.dispose();
    return { contextLost: gl.isContextLost(), geometry, material };
  });
  assert.deepEqual(disposal, { contextLost: true, geometry: 1, material: 1 },
    'dispose releases model resources and this preview context once');
  await checkLocal();
  t.diagnostic(JSON.stringify({ edge: browser.version(), ...result, fixtureBytes: fixture.length,
    fixtureSha256: createHash('sha256').update(fixture).digest('hex'), requests: requested, disposal }));
});

for (const [description, url, why] of [
  ['missing file', missing, /HTTP 404/],
  ['malformed GLB', '/malformed.vrm', /VRM parse failed/],
  ['plain glTF', '/plain.glb', /not a VRM 1\.0 humanoid/],
  ['transparent rig', '/blank.vrm', /blank WebGL frame/],
  ['non-local model URL', 'https://vrm-preview.invalid/synthetic.vrm', /same loopback origin/],
  ['external buffer in a GLB', '/external.vrm', /external model resources are not allowed/],
]) {
  test(`rejects ${description} without producing a first frame`, { timeout: 15_000 }, async (t) => {
    const { page, requested, checkLocal } = await openPage(t);
    const result = await page.evaluate(async (modelUrl) => {
      const { loadFirstFrame } = await import('/preview.mjs');
      const canvas = document.querySelector('canvas');
      try {
        const frame = await loadFirstFrame(canvas, modelUrl);
        frame.dispose();
        return { ok: true };
      } catch (error) {
        const gl = canvas.getContext('webgl2');
        return { ok: false, error: error.message, leakedFrame: gl !== null && !gl.isContextLost()
          && gl.getParameter(gl.CURRENT_PROGRAM) !== null };
      }
    }, url);
    assert.equal(result.ok, false);
    assert.match(result.error, why);
    assert.equal(result.leakedFrame, false);
    assert.equal(requested.includes(url), !url.startsWith('https:'), 'only local URLs reach the server');
    await checkLocal();
  });
}
