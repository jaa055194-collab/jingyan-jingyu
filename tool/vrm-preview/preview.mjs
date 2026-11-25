// Developer-only probe: this is not a general VRM importer or a render loop.
import { OrthographicCamera, Scene, WebGLRenderer, LoadingManager } from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { VRMLoaderPlugin, VRMUtils } from '@pixiv/three-vrm';

export async function loadFirstFrame(canvas, modelUrl) {
  const url = new URL(modelUrl, location.href);
  if (url.origin !== location.origin || url.protocol !== 'http:' || url.hostname !== '127.0.0.1') {
    throw new Error('VRM must use the same loopback origin');
  }
  const response = await fetch(url, { redirect: 'error', credentials: 'omit' });
  if (!response.ok) throw new Error(`VRM load failed: HTTP ${response.status}`);

  // The smoke fixture has no sidecars. Do not let the glTF loader request any.
  const manager = new LoadingManager().setURLModifier(() => {
    throw new Error('external model resources are not allowed');
  });
  const loader = new GLTFLoader(manager).register((parser) => {
    const { buffers = [], images = [] } = parser.json;
    if ([...buffers, ...images].some((resource) => 'uri' in resource)) {
      throw new Error('external model resources are not allowed');
    }
    return new VRMLoaderPlugin(parser);
  });
  let gltf;
  try {
    const bytes = await response.arrayBuffer();
    const header = new DataView(bytes);
    if (bytes.byteLength < 20 || header.getUint32(0, true) !== 0x46546c67
        || header.getUint32(4, true) !== 2 || header.getUint32(8, true) !== bytes.byteLength) {
      throw new Error('not a complete GLB 2.0');
    }
    gltf = await loader.parseAsync(bytes, '');
  } catch (cause) {
    throw new Error(`VRM parse failed: ${cause.message}`, { cause });
  }

  let renderer, disposed = false;
  const dispose = () => {
    if (disposed) return;
    disposed = true;
    try {
      VRMUtils.deepDispose(gltf.scene);
    } finally {
      renderer?.dispose();
      renderer?.forceContextLoss();
    }
  };
  try {
    const vrm = gltf.userData.vrm;
    if (gltf.parser.json.extensions?.VRMC_vrm?.specVersion !== '1.0' || !vrm?.humanoid) {
      throw new Error('not a VRM 1.0 humanoid');
    }
    const { width, height } = canvas;
    renderer = new WebGLRenderer({ canvas, alpha: true, preserveDrawingBuffer: true });
    renderer.setSize(width, height, false);
    renderer.setClearColor(0x000000, 0);

    const scene = new Scene();
    scene.add(vrm.scene);
    // Fixed framing for the known 2 m tall synthetic fixture, viewed from +Z.
    const halfWidth = 1.2 * width / height;
    const camera = new OrthographicCamera(-halfWidth, halfWidth, 1.2, -1.2, 0.1, 10);
    camera.position.set(0, 1.12, 4);
    camera.lookAt(0, 1.05, 0);
    vrm.update(0);
    renderer.render(scene, camera);

    // The clear buffer is transparent; a successful loader alone is not success.
    const gl = renderer.getContext();
    const pixels = new Uint8Array(width * height * 4);
    gl.readPixels(0, 0, width, height, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
    if (gl.isContextLost() || gl.getError() !== gl.NO_ERROR) throw new Error('WebGL draw/readback failed');
    if (!pixels.some((channel, index) => index % 4 === 3 && channel > 0)) {
      throw new Error('blank WebGL frame');
    }
    return { vrm, dispose };
  } catch (error) {
    dispose();
    throw error;
  }
}
