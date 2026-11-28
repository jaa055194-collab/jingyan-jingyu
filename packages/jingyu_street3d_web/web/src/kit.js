// Shared low-poly kit for the street and the villas: cached unit geometries, per-owner material
// sets and the instancing batch. geometry() and batch() are adapted from feiyu-room-template
// public/room/garden-world.js (MIT, see CREDITS.md): every repeated part becomes one
// InstancedMesh per geometry + material pair, which keeps draw calls low on phones.
import * as THREE from 'three';

const UP = new THREE.Vector3(0, 1, 0);
const geometries = new Map();

function flat(g) {
  const out = g.toNonIndexed();
  out.computeVertexNormals();
  g.dispose();
  return out;
}

// Unit shapes. box, cyl, ball and cone are centred on the origin (cyl, ball and cone have radius 1);
// prism and hip stand on y = 0 and are 1 tall.
export function geometry(kind) {
  let g = geometries.get(kind);
  if (g) return g;
  if (kind === 'box') g = new THREE.BoxGeometry(1, 1, 1);
  else if (kind === 'cyl') g = new THREE.CylinderGeometry(1, 1, 1, 12);
  else if (kind === 'ball') g = new THREE.SphereGeometry(1, 12, 8);
  else if (kind === 'cone') g = new THREE.ConeGeometry(1, 1, 10);
  else if (kind === 'prism') {
    // Gable roof: a triangle across x (base 1, apex 1 high), extruded along z (the ridge).
    const s = new THREE.Shape();
    s.moveTo(-0.5, 0);
    s.lineTo(0.5, 0);
    s.lineTo(0, 1);
    s.closePath();
    g = new THREE.ExtrudeGeometry(s, { depth: 1, bevelEnabled: false });
    g.translate(0, 0, -0.5);
  } else if (kind === 'hip') {
    // Hip roof: a square frustum, 1 x 1 at the base and 0.3 x 0.3 at the top, flat-shaded.
    g = new THREE.CylinderGeometry(0.3, 1, 1, 4, 1);
    g.rotateY(Math.PI / 4);
    g.scale(Math.SQRT1_2, 1, Math.SQRT1_2);
    g.translate(0, 0.5, 0);
    g = flat(g);
  } else {
    throw new Error(`unknown geometry ${kind}`);
  }
  geometries.set(kind, g);
  return g;
}

// A colour blended toward another one: tint(0x336699, 0xffffff, 0.3) is 30% lighter.
export function tint(color, toward, k) {
  return new THREE.Color(color).lerp(new THREE.Color(toward), k).getHex();
}

// Materials owned by one street or one villa, so a rebuilt villa frees exactly its own.
export function materialSet() {
  const cache = new Map();
  return {
    get(color, { roughness = 0.85, metalness = 0, emissive = 0x000000, emissiveIntensity = 1 } = {}) {
      const key = `${color}|${roughness}|${metalness}|${emissive}|${emissiveIntensity}`;
      let m = cache.get(key);
      if (!m) {
        m = new THREE.MeshStandardMaterial({ color, roughness, metalness, emissive, emissiveIntensity });
        cache.set(key, m);
      }
      return m;
    },
    dispose() {
      for (const m of cache.values()) m.dispose();
      cache.clear();
    },
  };
}

// Collects transforms per geometry + material and turns each group into one InstancedMesh.
export function batch(parent, { castShadow = true, receiveShadow = true, name = 'part' } = {}) {
  const items = new Map();
  const o = new THREE.Object3D();
  const list = (kind, m) => {
    const key = `${kind}:${m.uuid}`;
    let it = items.get(key);
    if (!it) {
      it = { kind, m, matrices: [] };
      items.set(key, it);
    }
    return it.matrices;
  };
  const put = (kind, m, x, y, z, sx = 1, sy = 1, sz = 1, rx = 0, ry = 0, rz = 0) => {
    o.position.set(x, y, z);
    o.scale.set(sx, sy, sz);
    o.rotation.set(rx, ry, rz);
    o.updateMatrix();
    list(kind, m).push(o.matrix.clone());
  };
  // A cylinder of radius r from point a to point b.
  const rod = (m, a, b, r = 0.03) => {
    const av = new THREE.Vector3(...a);
    const dir = new THREE.Vector3(...b).sub(av);
    o.position.copy(av).addScaledVector(dir, 0.5);
    o.scale.set(r, dir.length(), r);
    o.quaternion.setFromUnitVectors(UP, dir.normalize());
    o.updateMatrix();
    list('cyl', m).push(o.matrix.clone());
  };
  const flush = () => {
    const meshes = [];
    for (const { kind, m, matrices } of items.values()) {
      const mesh = new THREE.InstancedMesh(geometry(kind), m, matrices.length);
      matrices.forEach((mx, i) => mesh.setMatrixAt(i, mx));
      mesh.instanceMatrix.needsUpdate = true;
      mesh.castShadow = castShadow;
      mesh.receiveShadow = receiveShadow;
      mesh.computeBoundingSphere();
      mesh.name = `${name}-${kind}`;
      parent.add(mesh);
      meshes.push(mesh);
    }
    items.clear();
    return meshes;
  };
  return { put, rod, flush };
}

// Frees the instance buffers under root; the shared unit geometries stay cached.
export function disposeInstances(root) {
  root.traverse((node) => {
    if (node.isInstancedMesh) node.dispose();
  });
}
