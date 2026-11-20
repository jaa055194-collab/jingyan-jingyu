// Original synthetic test data only, not a production asset. See THIRD_PARTY_NOTICES.md.
// Absolute rest positions in meters, right-handed glTF coordinates; front is +Z.
const rig = [
  ['hips', null, 0, 1.00, 0],
  ['spine', 'hips', 0, 1.19, 0],
  ['head', 'spine', 0, 1.72, 0],
  ['leftUpperArm', 'spine', 0.29, 1.50, 0],
  ['leftLowerArm', 'leftUpperArm', 0.52, 1.39, 0],
  ['leftHand', 'leftLowerArm', 0.73, 1.29, 0],
  ['rightUpperArm', 'spine', -0.29, 1.50, 0],
  ['rightLowerArm', 'rightUpperArm', -0.52, 1.39, 0],
  ['rightHand', 'rightLowerArm', -0.73, 1.29, 0],
  ['leftUpperLeg', 'hips', 0.15, 0.96, 0],
  ['leftLowerLeg', 'leftUpperLeg', 0.15, 0.53, 0],
  ['leftFoot', 'leftLowerLeg', 0.15, 0.13, 0],
  ['rightUpperLeg', 'hips', -0.15, 0.96, 0],
  ['rightLowerLeg', 'rightUpperLeg', -0.15, 0.53, 0],
  ['rightFoot', 'rightLowerLeg', -0.15, 0.13, 0],
];

export function syntheticGlb(kind = 'visible') {
  const boneIndex = new Map(rig.map(([name], index) => [name, index]));
  const positions = [], colors = [], joints = [], weights = [], indices = [], inverseBind = [];
  const min = [Infinity, Infinity, Infinity], max = [-Infinity, -Infinity, -Infinity];
  const box = (bone, [cx, cy, cz], [w, h, d], rgb) => {
    const start = positions.length / 3;
    for (const iz of [-1, 1]) for (const iy of [-1, 1]) for (const ix of [-1, 1]) {
      const xyz = [cx + ix * w / 2, cy + iy * h / 2, cz + iz * d / 2].map(Math.fround);
      xyz.forEach((value, i) => {
        min[i] = Math.min(min[i], value);
        max[i] = Math.max(max[i], value);
      });
      positions.push(...xyz);
      colors.push(...rgb, 255);
      joints.push(boneIndex.get(bone), 0, 0, 0);
      weights.push(255, 0, 0, 0);
    }
    // Corner order is X first, then Y, then Z; every face winds outwards.
    for (const [a, b, c, d] of [[4, 5, 7, 6], [1, 0, 2, 3], [5, 1, 3, 7],
      [0, 4, 6, 2], [6, 7, 3, 2], [0, 1, 5, 4]]) {
      indices.push(start + a, start + b, start + c, start + a, start + c, start + d);
    }
  };
  const blue = [12, 85, 230], orange = [240, 62, 5], navy = [9, 18, 36];
  box('head', [0, 1.84, 0], [0.40, 0.36, 0.30], blue);
  box('spine', [0, 1.31, 0], [0.51, 0.48, 0.29], orange);
  box('hips', [0, 1.00, 0], [0.47, 0.17, 0.27], navy);
  for (const [side, sign] of [['left', 1], ['right', -1]]) {
    box('head', [sign * 0.095, 1.89, 0.151], [0.065, 0.055, 0.012], navy);
    box(`${side}UpperArm`, [sign * 0.38, 1.48, 0], [0.22, 0.16, 0.20], blue);
    box(`${side}LowerArm`, [sign * 0.57, 1.37, 0], [0.22, 0.14, 0.17], orange);
    box(`${side}Hand`, [sign * 0.74, 1.30, 0], [0.14, 0.14, 0.16], blue);
    box(`${side}UpperLeg`, [sign * 0.15, 0.75, 0], [0.20, 0.39, 0.21], blue);
    box(`${side}LowerLeg`, [sign * 0.15, 0.34, 0], [0.17, 0.40, 0.18], navy);
    box(`${side}Foot`, [sign * 0.15, 0.10, 0.035], [0.23, 0.13, 0.31], orange);
  }

  const nodes = rig.map(([name, parent, x, y, z]) => {
    const [, , px, py, pz] = parent ? rig[boneIndex.get(parent)] : [null, null, 0, 0, 0];
    inverseBind.push(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -x, -y, -z, 1);
    return { name, translation: [x - px, y - py, z - pz] };
  });
  for (const [index, [, parent]] of rig.entries()) {
    if (parent) (nodes[boneIndex.get(parent)].children ??= []).push(index);
  }
  nodes.push({ name: 'Synthetic calibration blocks (test only)', mesh: 0, skin: 0 });

  const accessors = [], bufferViews = [], parts = [];
  let offset = 0;
  const append = (array, componentType, count, type, extras = {}) => {
    const bytes = Buffer.from(array.buffer);
    bufferViews.push({ buffer: 0, byteOffset: offset, byteLength: bytes.length });
    accessors.push({ bufferView: bufferViews.length - 1, componentType, count, type, ...extras });
    parts.push(bytes);
    const padding = (4 - bytes.length % 4) % 4;
    if (padding) parts.push(Buffer.alloc(padding));
    offset += bytes.length + padding;
    return accessors.length - 1;
  };
  const n = positions.length / 3;
  const primitive = { attributes: {
    POSITION: append(new Float32Array(positions), 5126, n, 'VEC3', { min, max }),
    COLOR_0: append(new Uint8Array(colors), 5121, n, 'VEC4', { normalized: true }),
    JOINTS_0: append(new Uint8Array(joints), 5121, n, 'VEC4'),
    WEIGHTS_0: append(new Uint8Array(weights), 5121, n, 'VEC4', { normalized: true }),
  }, indices: append(new Uint16Array(indices), 5123, indices.length, 'SCALAR'), material: 0 };
  const inverseBindMatrices = append(new Float32Array(inverseBind), 5126, rig.length, 'MAT4');
  const binary = Buffer.concat(parts);
  const gltf = {
    asset: { version: '2.0', generator: 'Jingyu synthetic VRM first-frame test fixture' },
    extensionsUsed: ['KHR_materials_unlit'],
    scene: 0, scenes: [{ nodes: [0, rig.length] }], nodes,
    meshes: [{ primitives: [primitive] }],
    materials: [{
      extensions: { KHR_materials_unlit: {} },
      ...(kind === 'blank' && { alphaMode: 'BLEND', pbrMetallicRoughness: { baseColorFactor: [1, 1, 1, 0] } }),
    }],
    skins: [{ joints: rig.map((_, index) => index), skeleton: 0, inverseBindMatrices }],
    accessors, bufferViews, buffers: [{ byteLength: binary.length }],
  };
  if (kind !== 'plain') {
    gltf.extensionsUsed.push('VRMC_vrm');
    gltf.extensions = { VRMC_vrm: {
      specVersion: '1.0',
      humanoid: { humanBones: Object.fromEntries(rig.map(([name], node) => [name, { node }])) },
      meta: {
        name: 'Jingyu Synthetic Test Rig (not a production asset)',
        authors: ['Jingyu contributors'],
        licenseUrl: 'https://vrm.dev/licenses/1.0/',
        otherLicenseUrl: 'https://creativecommons.org/publicdomain/zero/1.0/',
        avatarPermission: 'everyone', commercialUsage: 'corporation', creditNotation: 'unnecessary',
        allowRedistribution: true, modification: 'allowModificationRedistribution',
      },
    } };
  }
  if (kind === 'external') gltf.buffers[0].uri = 'https://vrm-preview.invalid/sidecar.bin';

  const json = Buffer.from(JSON.stringify(gltf));
  const paddedJson = Buffer.concat([json, Buffer.alloc((4 - json.length % 4) % 4, 0x20)]);
  const chunk = (data, type) => {
    const header = Buffer.alloc(8);
    header.writeUInt32LE(data.length, 0);
    header.write(type, 4, 'ascii');
    return Buffer.concat([header, data]);
  };
  const header = Buffer.alloc(12);
  header.write('glTF');
  header.writeUInt32LE(2, 4);
  header.writeUInt32LE(12 + 16 + paddedJson.length + binary.length, 8);
  return Buffer.concat([header, chunk(paddedJson, 'JSON'), chunk(binary, 'BIN\0')]);
}
