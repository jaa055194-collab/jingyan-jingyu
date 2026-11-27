// Renderer, scene, lights and the static shadow map. The renderer settings (ACES tone mapping,
// sRGB output, PCF soft shadows that are re-rendered only after a change) and the hemisphere +
// sun rig follow feiyu-room-template public/room/app.js and world.js (MIT, see CREDITS.md).
import * as THREE from 'three';

export const THEMES = Object.freeze({
  light: Object.freeze({ sky: 0xcfe6f2, hemiSky: 0xdcefff, hemiGround: 0x8a7a66, hemi: 1.15, sun: 0xfff0d8, sunIntensity: 2.4, exposure: 1.04 }),
  dark: Object.freeze({ sky: 0x121a24, hemiSky: 0x5a6f96, hemiGround: 0x1c1a20, hemi: 0.4, sun: 0xa9bde6, sunIntensity: 0.5, exposure: 1.0 }),
});

// The sun shines from above the -X, +Z side, so shadows fall toward +X and -Z.
const SUN_DIR = new THREE.Vector3(-0.45, 1, 0.55).normalize();
const SUN_DISTANCE = 80;

export function createStage(container, { onContextLost = () => {}, onContextRestored = () => {} } = {}) {
  // Throws when no WebGL context can be created; main.js reports webgl_unavailable.
  const renderer = new THREE.WebGLRenderer({ antialias: true, powerPreference: 'high-performance' });
  const canvas = renderer.domElement;
  container.appendChild(canvas);
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = THEMES.light.exposure;
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = THREE.PCFSoftShadowMap;
  renderer.shadowMap.autoUpdate = false;
  renderer.shadowMap.needsUpdate = true;

  const scene = new THREE.Scene();
  scene.background = new THREE.Color(THEMES.light.sky);
  scene.fog = new THREE.Fog(THEMES.light.sky, 120, 400);
  const camera = new THREE.PerspectiveCamera(50, 1, 0.5, 1200);

  const hemi = new THREE.HemisphereLight(THEMES.light.hemiSky, THEMES.light.hemiGround, THEMES.light.hemi);
  const sun = new THREE.DirectionalLight(THEMES.light.sun, THEMES.light.sunIntensity);
  sun.castShadow = true;
  sun.shadow.mapSize.set(2048, 2048);
  sun.shadow.bias = -0.00035;
  sun.shadow.normalBias = 0.03;
  scene.add(hemi, sun, sun.target);

  const v = new THREE.Vector3();
  const stage = {
    renderer, scene, camera, canvas,
    webgl: renderer.capabilities.isWebGL2 ? 2 : 1,
    lost: false,
    quality: 'high',
    theme: 'light',

    // high: pixel ratio up to 2 and a 2048 shadow map; low: pixel ratio 1 and 1024.
    setQuality(q) {
      stage.quality = q === 'low' ? 'low' : 'high';
      const size = stage.quality === 'low' ? 1024 : 2048;
      if (sun.shadow.mapSize.x !== size) {
        sun.shadow.mapSize.set(size, size);
        if (sun.shadow.map) { sun.shadow.map.dispose(); sun.shadow.map = null; }
      }
      renderer.shadowMap.needsUpdate = true;
      return stage.resize();
    },

    setTheme(mode) {
      const t = THEMES[mode] ?? THEMES.light;
      stage.theme = mode === 'dark' ? 'dark' : 'light';
      scene.background.setHex(t.sky);
      scene.fog.color.setHex(t.sky);
      hemi.color.setHex(t.hemiSky);
      hemi.groundColor.setHex(t.hemiGround);
      hemi.intensity = t.hemi;
      sun.color.setHex(t.sun);
      sun.intensity = t.sunIntensity;
      renderer.toneMappingExposure = t.exposure;
    },

    // Fog starts just behind what the camera looks at, so the far end of the street fades out.
    setViewDistance(d) {
      scene.fog.near = d * 1.1;
      scene.fog.far = d * 3.6;
    },

    // Fits the sun's orthographic shadow camera around a street rectangle up to `height` metres.
    fitShadow({ minX, maxX, minZ, maxZ }, height = 12) {
      const cx = (minX + maxX) / 2;
      const cz = (minZ + maxZ) / 2;
      sun.target.position.set(cx, 0, cz);
      sun.position.set(cx + SUN_DIR.x * SUN_DISTANCE, SUN_DIR.y * SUN_DISTANCE, cz + SUN_DIR.z * SUN_DISTANCE);
      sun.target.updateMatrixWorld();
      sun.updateMatrixWorld();
      const cam = sun.shadow.camera;
      cam.position.copy(sun.position);
      cam.lookAt(sun.target.position);
      cam.updateMatrixWorld();
      const inv = cam.matrixWorld.clone().invert();
      let l = Infinity; let r = -Infinity; let b = Infinity; let t = -Infinity; let n = Infinity; let f = -Infinity;
      for (const x of [minX, maxX]) for (const y of [0, height]) for (const z of [minZ, maxZ]) {
        v.set(x, y, z).applyMatrix4(inv);
        l = Math.min(l, v.x); r = Math.max(r, v.x);
        b = Math.min(b, v.y); t = Math.max(t, v.y);
        n = Math.min(n, -v.z); f = Math.max(f, -v.z);
      }
      cam.left = l - 1; cam.right = r + 1; cam.bottom = b - 1; cam.top = t + 1;
      cam.near = Math.max(0.5, n - 5); cam.far = f + 5;
      cam.updateProjectionMatrix();
      renderer.shadowMap.needsUpdate = true;
    },

    shadowsDirty() { renderer.shadowMap.needsUpdate = true; },

    resize() {
      const width = Math.max(1, container.clientWidth || window.innerWidth);
      const height = Math.max(1, container.clientHeight || window.innerHeight);
      renderer.setPixelRatio(stage.quality === 'low' ? 1 : Math.min(window.devicePixelRatio || 1, 2));
      renderer.setSize(width, height, false);
      camera.aspect = width / height;
      camera.updateProjectionMatrix();
      return { width, height };
    },

    // Returns the draw calls of this frame (shadow pass included).
    render() {
      renderer.render(scene, camera);
      return renderer.info.render.calls;
    },
  };

  // three.js calls preventDefault() on webglcontextlost itself and, on restore, re-creates its GL
  // state so every geometry and texture still in memory is uploaded again on the next render.
  canvas.addEventListener('webglcontextlost', () => { stage.lost = true; onContextLost(); });
  canvas.addEventListener('webglcontextrestored', () => {
    stage.lost = false;
    renderer.shadowMap.needsUpdate = true;
    onContextRestored();
  });
  stage.resize();
  return stage;
}
