// Live2D texture memory budget: PNG size probing and one shared downscale
// plan, so large models fit phone GPU memory. Browser global
// (window.Live2DTextureBudget) plus CommonJS for the node tests.
//
// Decoded to RGBA8 with a full mipmap chain (4/3 of the base level), four
// 4096x4096 atlases need about 341 MiB of GPU memory. The renderer reads every
// texture size from its PNG header first, plans one scale for all textures,
// then decodes them one at a time at the planned size.
//
// Sources (ideas only, no code copied):
// - Mochi2D (MIT), github.com/waifucave/Mochi2D at 4378a87535b0 (2026-11-22),
//   src/render/texture/budget.ts and src/lib/texture-budget.ts: plan sizes
//   before decoding, 256 MiB default budget for phones and tablets, resize
//   while decoding.
// - W3C PNG specification: 8-byte signature, IHDR first with length 13,
//   width and height big-endian four-byte integers in 1..2^31-1.
//
// The 256 MiB default and the 4/3 mipmap factor are estimates, not measured
// on our devices yet.
(function () {
  'use strict';

  var MiB = 1024 * 1024;
  var DEFAULT_BUDGET_BYTES = 256 * MiB;
  // Signature (8) plus the whole IHDR chunk: length (4), type (4), data (13)
  // and CRC (4). The CRC is not checked here; the import validator checks it.
  var PNG_HEADER_BYTES = 33;
  var PNG_SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  var IHDR_TYPE = [0x49, 0x48, 0x44, 0x52];
  var MAX_DIMENSION = 0x7fffffff;
  // Integer products up to 2^52 divide exactly in doubles; larger use BigInt.
  var EXACT_PRODUCT_LIMIT = 4503599627370496;

  function toBytes(data) {
    if (Object.prototype.toString.call(data) === '[object ArrayBuffer]') {
      return new Uint8Array(data);
    }
    if (data && ArrayBuffer.isView(data)) {
      return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    }
    throw new TypeError('readPngSize: expected PNG bytes as an ArrayBuffer or typed array');
  }

  function readUint32(bytes, offset) {
    return (
      bytes[offset] * 0x1000000 +
      ((bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3])
    );
  }

  function notPng(reason) {
    return new Error('readPngSize: not a PNG file (' + reason + ')');
  }

  // Width and height from the IHDR chunk. Needs the first PNG_HEADER_BYTES.
  function readPngSize(data) {
    var bytes = toBytes(data);
    var i;
    if (bytes.length < PNG_HEADER_BYTES) {
      throw notPng('only ' + bytes.length + ' bytes');
    }
    for (i = 0; i < PNG_SIGNATURE.length; i++) {
      if (bytes[i] !== PNG_SIGNATURE[i]) {
        throw notPng('bad signature');
      }
    }
    for (i = 0; i < IHDR_TYPE.length; i++) {
      if (bytes[12 + i] !== IHDR_TYPE[i]) {
        throw notPng('first chunk is not IHDR');
      }
    }
    if (readUint32(bytes, 8) !== 13) {
      throw notPng('IHDR length is not 13');
    }
    var width = readUint32(bytes, 16);
    var height = readUint32(bytes, 20);
    if (width < 1 || height < 1 || width > MAX_DIMENSION || height > MAX_DIMENSION) {
      throw notPng('invalid size ' + width + 'x' + height);
    }
    return { width: width, height: height };
  }

  function isDimension(value) {
    return (
      typeof value === 'number' &&
      value >= 1 &&
      value <= MAX_DIMENSION &&
      Math.floor(value) === value
    );
  }

  function checkSizes(sizes) {
    if (!Array.isArray(sizes)) {
      throw new TypeError('planUniformScale: sizes must be an array of {width, height}');
    }
    for (var i = 0; i < sizes.length; i++) {
      var size = sizes[i];
      if (!size || typeof size !== 'object') {
        throw new TypeError('planUniformScale: size ' + i + ' is not an object');
      }
      if (!isDimension(size.width) || !isDimension(size.height)) {
        throw new RangeError(
          'planUniformScale: size ' + i + ' needs integer width and height in 1..2^31-1'
        );
      }
    }
  }

  function checkMaxTextureSize(value) {
    if (typeof value !== 'number' || !(value >= 1)) {
      throw new RangeError('planUniformScale: maxTextureSize must be a number >= 1');
    }
    return Math.floor(value);
  }

  function checkBudget(value) {
    if (value === undefined || value === null) {
      return DEFAULT_BUDGET_BYTES;
    }
    if (typeof value !== 'number' || !(value > 0)) {
      throw new RangeError('planUniformScale: budgetBytes must be a number > 0');
    }
    return value;
  }

  // Bytes of RGBA8 textures. withMipmaps (default true) adds the third that a
  // full mipmap chain needs on top of the base level: w * h * 4 * 4 / 3.
  function estimateBytes(sizes, withMipmaps) {
    var pixels = 0;
    for (var i = 0; i < sizes.length; i++) {
      pixels += sizes[i].width * sizes[i].height;
    }
    return withMipmaps === false ? pixels * 4 : Math.ceil((pixels * 16) / 3);
  }

  // floor(value * edge / longest), at least 1, exact for any PNG size.
  function scaleDimension(value, edge, longest) {
    var product = value * edge;
    var scaled;
    if (product <= EXACT_PRODUCT_LIMIT || typeof BigInt !== 'function') {
      scaled = Math.floor(product / longest);
    } else {
      scaled = Number((BigInt(value) * BigInt(edge)) / BigInt(longest));
    }
    return scaled < 1 ? 1 : scaled;
  }

  function sizesAtEdge(sizes, edge, longest) {
    var out = [];
    for (var i = 0; i < sizes.length; i++) {
      var size = sizes[i];
      if (edge >= longest) {
        out.push({ width: size.width, height: size.height });
      } else {
        out.push({
          width: scaleDimension(size.width, edge, longest),
          height: scaleDimension(size.height, edge, longest),
        });
      }
    }
    return out;
  }

  // One scale for all textures. The longest edge of all textures becomes
  // `edge` and every dimension becomes d * edge / longest rounded down (at
  // least 1). Picks the largest integer edge that fits maxTextureSize and whose
  // mipmapped total fits budgetBytes (default 256 MiB), so scale is <= 1 and
  // exactly 1 when everything already fits. Throws RangeError when even 1x1
  // textures do not fit. Use plan.sizes for decoding: they are the exact
  // rounded sizes the budget was checked with.
  function planTextureSizes(sizes, maxTextureSize, budgetBytes) {
    checkSizes(sizes);
    var maxEdge = checkMaxTextureSize(maxTextureSize);
    var budget = checkBudget(budgetBytes);
    var plan = { scale: 1, sizes: [], bytes: 0, maxTextureSize: maxEdge, budgetBytes: budget };
    var longest = 0;
    for (var i = 0; i < sizes.length; i++) {
      longest = Math.max(longest, sizes[i].width, sizes[i].height);
    }
    if (longest === 0) {
      return plan;
    }
    var low = 1;
    var high = Math.min(longest, maxEdge);
    if (estimateBytes(sizesAtEdge(sizes, low, longest)) > budget) {
      throw new RangeError(
        'planUniformScale: ' + sizes.length + ' textures do not fit ' + budget +
          ' bytes even at 1x1'
      );
    }
    while (low < high) {
      var mid = low + Math.ceil((high - low) / 2);
      if (estimateBytes(sizesAtEdge(sizes, mid, longest)) <= budget) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    plan.scale = low / longest;
    plan.sizes = sizesAtEdge(sizes, low, longest);
    plan.bytes = estimateBytes(plan.sizes);
    return plan;
  }

  function planUniformScale(sizes, maxTextureSize, budgetBytes) {
    return planTextureSizes(sizes, maxTextureSize, budgetBytes).scale;
  }

  var api = Object.freeze({
    DEFAULT_BUDGET_BYTES: DEFAULT_BUDGET_BYTES,
    PNG_HEADER_BYTES: PNG_HEADER_BYTES,
    readPngSize: readPngSize,
    estimateBytes: estimateBytes,
    planTextureSizes: planTextureSizes,
    planUniformScale: planUniformScale,
  });

  if (typeof window !== 'undefined' && window) {
    window.Live2DTextureBudget = api;
  }
  if (typeof module !== 'undefined' && module && module.exports) {
    module.exports = api;
  }
})();
