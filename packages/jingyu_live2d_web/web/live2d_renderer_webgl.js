// Live2D WebGL renderer adapter for the WebView shell (`window.Live2DRenderer`).
//
// BEST-EFFORT ADAPTER — NOT A VISUAL-PARITY CLAIM.
//
// This file maps the drawable output exposed by PurismCore's `model.drawables`
// getters (vertex positions, UVs, indices, texture index, opacity, multiply /
// screen colors, constant flags, masks, and `model.renderOrders`) to simple
// textured-quad/triangle draw calls. It uses WebGL2 when available and falls
// back to WebGL1. Both contexts are fed GLSL ES 1.00 shaders so the same source
// compiles under either.
//
// What this adapter does NOT fully implement (all require on-device validation
// before any quality/parity claim):
//   * Clipping masks: a single-level stencil approximation is used per drawable.
//     Nested masks, channel-packed multi-mask groups and offscreen masks are
//     not reproduced, so masked edges can be wrong.
//   * Blend modes: v5 constant-flag additive/multiplicative are approximated;
//     v6 extended color+alpha blend modes and offscreen compositing are ignored.
//   * Physics, motions, expressions, breath/eye-blink and the model3 motion
//     pipeline are implemented by live2d_motion.js, live2d_behavior.js and the
//     viewer protocol layer, not by this pixel adapter.
//   * Texture color-space, premultiplied-alpha nuances and sustained frame
//     rate are untested here. Large atlases are downscaled to fit the GPU's
//     MAX_TEXTURE_SIZE and a memory budget (live2d_texture_budget.js), but
//     neither limit has been measured on our devices yet.
//
// Third-party code: portions of this file are adapted from the PurismCore
// v1.1.0 viewer sample (github.com/SakuraMotion/PurismCore, tag v1.1.0).
// The camera math in updateProjection() and computeFit() follows
// WorldToScreen() and FitView() in src/samples/viewer/graphics.c, and the
// multiply, screen and premultiply steps of DRAW_FRAGMENT_SHADER follow
// src/samples/viewer/shaders/draw.frag. Those portions are used under the
// MIT licence of the sample files:
//
//   Copyright (c) 2026 Sakura Motion Project
//   SPDX-License-Identifier: MIT
//
//   Permission is hereby granted, free of charge, to any person obtaining a
//   copy of this software and associated documentation files (the
//   "Software"), to deal in the Software without restriction, including
//   without limitation the rights to use, copy, modify, merge, publish,
//   distribute, sublicense, and/or sell copies of the Software, and to
//   permit persons to whom the Software is furnished to do so, subject to
//   the following conditions:
//
//   The above copyright notice and this permission notice shall be included
//   in all copies or substantial portions of the Software.
//
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
//   OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
//   MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
//   IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
//   CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
//   TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
//   SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//
// Defensive contract: if a PurismCore getter or array is unavailable, the
// affected drawable is skipped and a diagnostic is logged — draw() never throws
// out of the animation loop and reports problems through its console output.
(function () {
  'use strict';

  if (typeof window === 'undefined') return;

  // csmFlags bit helpers (constant flags). Matches PurismCore's Utils.*Bits.
  var BLEND_ADDITIVE = 1; // constantFlags bit 0
  var BLEND_MULTIPLICATIVE = 2; // constantFlags bit 1
  var DOUBLE_SIDED = 4; // constantFlags bit 2 (we never enable culling)
  var INVERTED_MASK = 8; // constantFlags bit 3

  // dynamicFlags bit 0: drawable is visible/enabled with non-zero opacity.
  var DYNAMIC_VISIBLE = 1;

  var state = {
    gl: null,
    version: 0,
    canvas: null,
    ready: false,
    disposed: true,
    contextLost: false,
    listenersAttached: false,
    pixelW: 0,
    pixelH: 0,
    drawProgram: null,
    maskProgram: null,
    drawU: null,
    drawA: null,
    maskU: null,
    maskA: null,
    // Live scenes share this one context, canvas and program. Each scene owns
    // its textures, geometry cache and camera fit (see createScene()).
    scenes: [],
    // Scene returned by prepare() or the last one created; draw(model) uses it.
    currentScene: null,
    // Reason of the last createScene()/prepare() failure; null after success.
    // 'texture_budget' means the request was refused before any texture upload.
    lastError: null,
    // True between beginFrame() and endFrame(). draw() opens an implicit frame.
    frameOpen: false,
    // Bumped by dispose() so an older prepare()/createScene() still loading
    // textures stops and deletes what it uploaded.
    generation: 0,
    warned: {},
  };

  // ---------------------------------------------------------------------------
  // Shaders (GLSL ES 1.00 — accepted by WebGL1 and WebGL2 contexts).
  // ---------------------------------------------------------------------------
  var VERTEX_SHADER = [
    'attribute vec2 aPos;', // model-space position (x, y), y up
    'attribute vec2 aUv;', // Live2D UV, bottom-left origin
    'uniform mat3 uProjection;', // model space -> clip space
    'varying vec2 vUv;',
    'void main() {',
    '  vec3 p = uProjection * vec3(aPos, 1.0);',
    '  gl_Position = vec4(p.xy, 0.0, 1.0);',
    '  vUv = vec2(aUv.x, 1.0 - aUv.y);', // bottom-left UV -> top-left texture row
    '}',
  ].join('\n');

  var DRAW_FRAGMENT_SHADER = [
    'precision mediump float;',
    'varying vec2 vUv;',
    'uniform sampler2D uTexture;',
    'uniform vec4 uBaseColor;', // rgb = 1, a = opacity
    'uniform vec4 uMultiplyColor;',
    'uniform vec4 uScreenColor;',
    'uniform float u_alpha;', // whole-scene fade, 1 = opaque
    'void main() {',
    '  vec4 t = texture2D(uTexture, vUv);',
    '  t.rgb *= uMultiplyColor.rgb;',
    '  t.rgb = t.rgb + uScreenColor.rgb - t.rgb * uScreenColor.rgb;',
    '  vec4 c = t * uBaseColor;',
    '  vec4 premultiplied = vec4(c.rgb * c.a, c.a);',
    '  gl_FragColor = premultiplied * u_alpha;', // fade the premultiplied output
    '}',
  ].join('\n');

  var MASK_FRAGMENT_SHADER = [
    'precision mediump float;',
    'varying vec2 vUv;',
    'uniform sampler2D uTexture;',
    'void main() {',
    '  vec4 t = texture2D(uTexture, vUv);',
    '  if (t.a < 0.01) discard;', // write stencil only where the mask covers
    '  gl_FragColor = vec4(1.0);',
    '}',
  ].join('\n');

  function warnOnce(key, message) {
    if (state.warned[key]) return;
    state.warned[key] = true;
    if (window.console && window.console.warn) {
      window.console.warn('[Live2DRenderer] ' + message);
    }
  }

  function compileShader(gl, type, source) {
    var shader = gl.createShader(type);
    if (!shader) throw new Error('gl.createShader failed');
    gl.shaderSource(shader, source);
    gl.compileShader(shader);
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
      var log = gl.getShaderInfoLog(shader) || 'unknown shader compile error';
      gl.deleteShader(shader);
      throw new Error('shader compile failed: ' + log);
    }
    return shader;
  }

  function buildProgram(gl, vertexSource, fragmentSource) {
    var vs = compileShader(gl, gl.VERTEX_SHADER, vertexSource);
    var fs = compileShader(gl, gl.FRAGMENT_SHADER, fragmentSource);
    var program = gl.createProgram();
    if (!program) throw new Error('gl.createProgram failed');
    gl.attachShader(program, vs);
    gl.attachShader(program, fs);
    gl.linkProgram(program);
    gl.deleteShader(vs);
    gl.deleteShader(fs);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      var log = gl.getProgramInfoLog(program) || 'unknown program link error';
      gl.deleteProgram(program);
      throw new Error('program link failed: ' + log);
    }
    return program;
  }

  function buildPrograms(gl) {
    state.drawProgram = buildProgram(gl, VERTEX_SHADER, DRAW_FRAGMENT_SHADER);
    state.maskProgram = buildProgram(gl, VERTEX_SHADER, MASK_FRAGMENT_SHADER);

    state.drawU = {
      uProjection: gl.getUniformLocation(state.drawProgram, 'uProjection'),
      uTexture: gl.getUniformLocation(state.drawProgram, 'uTexture'),
      uBaseColor: gl.getUniformLocation(state.drawProgram, 'uBaseColor'),
      uMultiplyColor: gl.getUniformLocation(state.drawProgram, 'uMultiplyColor'),
      uScreenColor: gl.getUniformLocation(state.drawProgram, 'uScreenColor'),
      u_alpha: gl.getUniformLocation(state.drawProgram, 'u_alpha'),
    };
    state.drawA = {
      aPos: gl.getAttribLocation(state.drawProgram, 'aPos'),
      aUv: gl.getAttribLocation(state.drawProgram, 'aUv'),
    };
    state.maskU = {
      uProjection: gl.getUniformLocation(state.maskProgram, 'uProjection'),
      uTexture: gl.getUniformLocation(state.maskProgram, 'uTexture'),
    };
    state.maskA = {
      aPos: gl.getAttribLocation(state.maskProgram, 'aPos'),
      aUv: gl.getAttribLocation(state.maskProgram, 'aUv'),
    };
  }

  // ---------------------------------------------------------------------------
  // Canvas / camera.
  // ---------------------------------------------------------------------------
  function resizeCanvas() {
    var canvas = state.canvas;
    if (!canvas) return;
    var dpr = window.devicePixelRatio || 1;
    var cssW = canvas.clientWidth || canvas.width || 300;
    var cssH = canvas.clientHeight || canvas.height || 150;
    var w = Math.max(1, Math.round(cssW * dpr));
    var h = Math.max(1, Math.round(cssH * dpr));
    if (canvas.width !== w || canvas.height !== h) {
      canvas.width = w;
      canvas.height = h;
      state.pixelW = w;
      state.pixelH = h;
      invalidateFits();
    } else if (!state.pixelW) {
      state.pixelW = canvas.width;
      state.pixelH = canvas.height;
    }
  }

  function newFit() {
    return {
      // camera (matches the upstream viewer's WorldToScreen / FitView math)
      cx: 0,
      cy: 0,
      zoom: 100,
      panX: 0,
      panY: 0,
      fitDone: false,
      projection: new Float32Array([1, 0, 0, 0, 1, 0, 0, 0, 1]),
    };
  }

  // A canvas resize changes every scene's fit (keyboard-driven resizes included).
  function invalidateFits() {
    for (var i = 0; i < state.scenes.length; i++) state.scenes[i].fit.fitDone = false;
  }

  function updateProjection(scene) {
    var sw = state.pixelW || 1;
    var sh = state.pixelH || 1;
    var fit = scene.fit;
    // Derived from the upstream viewer WorldToScreen(): model y is flipped to
    // screen y (down), scaled by zoom, centred on (cx, cy) with optional pan.
    var a = (2 * fit.zoom) / sw;
    var b = (2 * fit.zoom) / sh;
    var tx = -a * fit.cx + (2 * fit.panX) / sw;
    var ty = b * fit.cy - (2 * fit.panY) / sh;
    fit.projection = new Float32Array([a, 0, 0, 0, b, 0, tx, ty, 1]);
  }

  // Fit the camera to the model's current AABB (mirrors upstream FitView()).
  // Each scene keeps its own fit, so two models of different sizes can be drawn
  // in the same frame without sharing one camera.
  function computeFit(scene) {
    var sw = state.pixelW || 1;
    var sh = state.pixelH || 1;
    var fit = scene.fit;
    var model = scene.model;
    var dw = model && model.drawables;
    var minx = 1e30;
    var miny = 1e30;
    var maxx = -1e30;
    var maxy = -1e30;
    var any = false;
    if (dw && dw.vertexPositions && typeof dw.count === 'number') {
      for (var i = 0; i < dw.count; i++) {
        var positions = dw.vertexPositions[i];
        if (!positions) continue;
        for (var j = 0; j + 1 < positions.length; j += 2) {
          var x = positions[j];
          var y = -positions[j + 1]; // world y is flipped
          if (x < minx) minx = x;
          if (x > maxx) maxx = x;
          if (y < miny) miny = y;
          if (y > maxy) maxy = y;
          any = true;
        }
      }
    }
    if (!any || maxx <= minx || maxy <= miny) {
      fit.cx = 0;
      fit.cy = 0;
      fit.zoom = 100;
    } else {
      fit.cx = (minx + maxx) * 0.5;
      fit.cy = (miny + maxy) * 0.5;
      var zx = (sw * 0.8) / (maxx - minx);
      var zy = (sh * 0.8) / (maxy - miny);
      fit.zoom = zx < zy ? zx : zy;
    }
    fit.panX = 0;
    fit.panY = 0;
    fit.fitDone = true;
    updateProjection(scene);
  }

  // ---------------------------------------------------------------------------
  // Textures.
  //
  // A model's textures can need more GPU memory than a phone has: four
  // 4096x4096 atlases with mipmaps take about 341 MiB. loadTextures() fetches
  // every texture, reads its size from the PNG header, plans one downscale for
  // all of them (live2d_texture_budget.js), then decodes, uploads and closes
  // them one at a time so only one decoded bitmap is alive at once.
  // ---------------------------------------------------------------------------
  // Used when getParameter() gives no MAX_TEXTURE_SIZE (lost context).
  var FALLBACK_MAX_TEXTURE_SIZE = 2048;

  function emptyTextureInfo() {
    return { scale: 1, maxTextureSize: 0, bytes: 0, count: 0, budgetBytes: 0 };
  }

  function isPowerOfTwo(value) {
    return value > 0 && (value & (value - 1)) === 0;
  }

  // Clears pending GL errors and returns the first one (0 when there is none).
  function takeGlError(gl) {
    var first = 0;
    for (var i = 0; i < 8; i++) {
      var error = gl.getError();
      if (!error || error === gl.NO_ERROR) break;
      if (!first) first = error;
    }
    return first;
  }

  function deleteTextures(gl, textures) {
    for (var i = 0; i < textures.length; i++) {
      if (!textures[i]) continue;
      try {
        gl.deleteTexture(textures[i]);
      } catch (deleteError) {
        /* ignore */
      }
    }
  }

  // Fetches one texture file and reads its size from the PNG header.
  // Resolves {url, blob, width, height}, or null after a warning.
  async function fetchTexture(url, budgetApi) {
    var blob;
    try {
      var response = await window.fetch(url, { cache: 'no-store' });
      if (!response || !response.ok) throw new Error('status ' + (response && response.status));
      blob = await response.blob();
    } catch (loadError) {
      warnOnce('tex-load', 'texture load failed: ' + url);
      return null;
    }
    try {
      var header = await blob.slice(0, budgetApi.PNG_HEADER_BYTES).arrayBuffer();
      var size = budgetApi.readPngSize(header);
      return { url: url, blob: blob, width: size.width, height: size.height };
    } catch (formatError) {
      warnOnce('tex-format', 'texture rejected for ' + url + ': ' + formatError);
      return null;
    }
  }

  // Decodes one fetched texture at its planned size, uploads it and closes the
  // bitmap. Mipmaps on WebGL2, and on WebGL1 only for power-of-two sizes.
  // Resolves {texture, mipmaps}, or null when the texture is skipped or the
  // renderer was disposed while decoding.
  async function uploadTexture(gl, entry, planned, generation) {
    // Straight alpha like the old Image upload: ImageBitmap uploads ignore
    // UNPACK_PREMULTIPLY_ALPHA_WEBGL, and the shaders premultiply themselves.
    var options = { premultiplyAlpha: 'none' };
    if (planned.width !== entry.width || planned.height !== entry.height) {
      options.resizeWidth = planned.width;
      options.resizeHeight = planned.height;
      options.resizeQuality = 'high';
    }
    var bitmap;
    try {
      bitmap = await window.createImageBitmap(entry.blob, options);
    } catch (decodeError) {
      warnOnce('tex-load', 'texture load failed: ' + entry.url);
      return null;
    }
    var texture = null;
    try {
      if (generation !== state.generation) return null;
      if (bitmap.width !== planned.width || bitmap.height !== planned.height) {
        // A decoder that ignores the resize options would break the budget.
        warnOnce(
          'tex-size',
          'texture ' + entry.url + ' decoded at ' + bitmap.width + 'x' + bitmap.height +
            ', planned ' + planned.width + 'x' + planned.height
        );
        return null;
      }
      takeGlError(gl);
      texture = gl.createTexture();
      gl.bindTexture(gl.TEXTURE_2D, texture);
      // Keep source orientation; the vertex shader flips V for Live2D UV.
      gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, bitmap);
      var mipmaps =
        state.version >= 2 || (isPowerOfTwo(planned.width) && isPowerOfTwo(planned.height));
      if (mipmaps) gl.generateMipmap(gl.TEXTURE_2D);
      gl.texParameteri(
        gl.TEXTURE_2D,
        gl.TEXTURE_MIN_FILTER,
        mipmaps ? gl.LINEAR_MIPMAP_LINEAR : gl.LINEAR
      );
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      var glError = takeGlError(gl);
      if (glError) throw new Error('GL error ' + glError);
      return { texture: texture, mipmaps: mipmaps };
    } catch (uploadError) {
      if (texture) deleteTextures(gl, [texture]);
      warnOnce('tex-upload', 'texture upload failed for ' + entry.url + ': ' + uploadError);
      return null;
    } finally {
      try {
        bitmap.close();
      } catch (closeError) {
        /* ignore */
      }
    }
  }

  // Loads the model textures within the GPU memory budget. Resolves
  // {textures, info} with one slot per URL (null when that texture failed),
  // null when dispose() ran meanwhile (uploaded textures are then deleted), or
  // {rejected: true} when the scene plus the already-live scenes would exceed
  // the budget — checked after planning, before any decode/upload. Throws when
  // no plan fits (the budget is too small even for 1x1).
  async function loadTextures(urls, budgetApi, options, generation, existingBytes) {
    var gl = state.gl;
    // 1. Fetch every file and read its size before decoding any texture.
    var entries = [];
    for (var i = 0; i < urls.length; i++) {
      entries.push(await fetchTexture(urls[i], budgetApi));
      if (generation !== state.generation) return null;
    }
    // 2. One scale for all textures. options can lower the GPU limit only.
    var maxTextureSize = Number(gl.getParameter(gl.MAX_TEXTURE_SIZE));
    if (!(maxTextureSize >= 1)) maxTextureSize = FALLBACK_MAX_TEXTURE_SIZE;
    if (typeof options.maxTextureSize === 'number' && options.maxTextureSize >= 1) {
      maxTextureSize = Math.min(maxTextureSize, Math.floor(options.maxTextureSize));
    }
    var sizes = [];
    for (var s = 0; s < entries.length; s++) {
      if (entries[s]) sizes.push({ width: entries[s].width, height: entries[s].height });
    }
    var plan = budgetApi.planTextureSizes(sizes, maxTextureSize, options.textureBudgetBytes);
    // The budget covers every live scene, not just this one. Refuse before
    // uploading so a hot-switch preload never peaks over the GPU memory limit.
    var existing = typeof existingBytes === 'number' && existingBytes > 0 ? existingBytes : 0;
    if (existing + plan.bytes > plan.budgetBytes) {
      warnOnce(
        'texture-budget',
        'texture budget exceeded: live ' + existing + ' + new ' + plan.bytes +
          ' > ' + plan.budgetBytes + ' bytes; scene refused'
      );
      return { rejected: true };
    }
    // 3. Decode, upload and close one texture at a time.
    var textures = [];
    var mipmapped = [];
    var flat = [];
    var next = 0;
    for (var t = 0; t < entries.length; t++) {
      var entry = entries[t];
      entries[t] = null; // drop the encoded bytes once they are decoded
      if (!entry) {
        textures.push(null);
        continue;
      }
      var planned = plan.sizes[next++];
      var uploaded = await uploadTexture(gl, entry, planned, generation);
      textures.push(uploaded ? uploaded.texture : null);
      if (generation !== state.generation) {
        deleteTextures(gl, textures);
        return null;
      }
      if (uploaded && uploaded.mipmaps) mipmapped.push(planned);
      else if (uploaded) flat.push(planned);
    }
    return {
      textures: textures,
      info: {
        scale: plan.scale,
        maxTextureSize: plan.maxTextureSize,
        bytes: budgetApi.estimateBytes(mipmapped) + budgetApi.estimateBytes(flat, false),
        count: mipmapped.length + flat.length,
        budgetBytes: plan.budgetBytes,
      },
    };
  }

  function textureFor(scene, index) {
    if (!scene || !scene.textures || typeof index !== 'number' || index < 0) return null;
    return scene.textures[index] || null;
  }

  // ---------------------------------------------------------------------------
  // GPU geometry cache (built once per prepare).
  // ---------------------------------------------------------------------------
  function buildCache(model) {
    var cache = { list: [], count: 0, skipped: 0, withIndex: 0, modelRef: model };
    var gl = state.gl;
    var drawables = model && model.drawables;
    if (!drawables || typeof drawables.count !== 'number') {
      return cache;
    }
    var count = drawables.count | 0;
    cache.count = count;
    var positions = drawables.vertexPositions;
    var uvs = drawables.vertexUvs;
    var indices = drawables.indices;
    var textureIndices = drawables.textureIndices;
    var constantFlags = drawables.constantFlags;
    var masks = drawables.masks;

    for (var i = 0; i < count; i++) {
      var entry = { ok: false };
      try {
        var posArray = positions && positions[i];
        var uvArray = uvs && uvs[i];
        var idxArray = indices && indices[i];
        if (!posArray || !uvArray || !idxArray) {
          cache.skipped++;
          cache.list.push(entry);
          continue;
        }
        if (posArray.length < 2 || uvArray.length < 2 || idxArray.length < 3) {
          cache.skipped++;
          cache.list.push(entry);
          continue;
        }
        var vertexCount = posArray.length >> 1;
        var posBuf = gl.createBuffer();
        var uvBuf = gl.createBuffer();
        var idxBuf = gl.createBuffer();
        gl.bindBuffer(gl.ARRAY_BUFFER, uvBuf);
        gl.bufferData(gl.ARRAY_BUFFER, uvArray, gl.STATIC_DRAW);
        gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, idxBuf);
        gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, idxArray, gl.STATIC_DRAW);
        gl.bindBuffer(gl.ARRAY_BUFFER, posBuf);
        gl.bufferData(gl.ARRAY_BUFFER, posArray, gl.DYNAMIC_DRAW);

        var maskArray = masks && masks[i] ? masks[i] : null;
        var flags = constantFlags && i < constantFlags.length ? constantFlags[i] : 0;
        entry = {
          ok: true,
          posBuf: posBuf,
          uvBuf: uvBuf,
          idxBuf: idxBuf,
          vertexCount: vertexCount,
          indexCount: idxArray.length,
          textureIndex: textureIndices && i < textureIndices.length ? textureIndices[i] : 0,
          constantFlags: flags,
          invertedMask: (flags & INVERTED_MASK) !== 0,
          masks: maskArray,
        };
        cache.withIndex++;
      } catch (buildError) {
        cache.skipped++;
        entry = { ok: false };
        warnOnce('cache-build', 'could not cache drawable ' + i + ': ' + buildError);
      }
      cache.list.push(entry);
    }
    return cache;
  }

  function uploadPositions(entry, positions) {
    var gl = state.gl;
    gl.bindBuffer(gl.ARRAY_BUFFER, entry.posBuf);
    if (positions.length === entry.vertexCount * 2) {
      gl.bufferSubData(gl.ARRAY_BUFFER, 0, positions);
    } else {
      // Non-conforming length: fall back to a full re-upload of a valid slice.
      var expected = entry.vertexCount * 2;
      gl.bufferData(gl.ARRAY_BUFFER, positions.subarray(0, expected), gl.DYNAMIC_DRAW);
    }
  }

  function bindGeometry(program, attribs, entry) {
    var gl = state.gl;
    if (attribs.aPos >= 0) {
      gl.bindBuffer(gl.ARRAY_BUFFER, entry.posBuf);
      gl.enableVertexAttribArray(attribs.aPos);
      gl.vertexAttribPointer(attribs.aPos, 2, gl.FLOAT, false, 0, 0);
    }
    if (attribs.aUv >= 0) {
      gl.bindBuffer(gl.ARRAY_BUFFER, entry.uvBuf);
      gl.enableVertexAttribArray(attribs.aUv);
      gl.vertexAttribPointer(attribs.aUv, 2, gl.FLOAT, false, 0, 0);
    }
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, entry.idxBuf);
  }

  // ---------------------------------------------------------------------------
  // Mask stencil pre-pass (single level, best-effort).
  // ---------------------------------------------------------------------------
  function beginMask(scene, mainEntry) {
    var gl = state.gl;
    if (!gl || !mainEntry.masks || mainEntry.masks.length === 0) return false;
    gl.enable(gl.STENCIL_TEST);
    gl.clear(gl.STENCIL_BUFFER_BIT);
    gl.colorMask(false, false, false, false);
    gl.disable(gl.BLEND);
    gl.useProgram(state.maskProgram);
    gl.uniformMatrix3fv(state.maskU.uProjection, false, scene.fit.projection);
    gl.stencilFunc(gl.ALWAYS, 1, 0xff);
    gl.stencilOp(gl.KEEP, gl.KEEP, gl.REPLACE);
    var drewMask = false;
    for (var m = 0; m < mainEntry.masks.length; m++) {
      try {
        var maskIndex = mainEntry.masks[m] | 0;
        var maskEntry = scene.cache.list[maskIndex];
        if (!maskEntry || !maskEntry.ok) continue;
        var maskPositions = scene.lastPositions && scene.lastPositions[maskIndex];
        if (!maskPositions || maskPositions.length < maskEntry.vertexCount * 2) continue;
        var maskTexture = textureFor(scene, maskEntry.textureIndex);
        if (!maskTexture) continue;
        uploadPositions(maskEntry, maskPositions);
        bindGeometry(state.maskProgram, state.maskA, maskEntry);
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, maskTexture);
        gl.uniform1i(state.maskU.uTexture, 0);
        gl.drawElements(gl.TRIANGLES, maskEntry.indexCount, gl.UNSIGNED_SHORT, 0);
        drewMask = true;
      } catch (maskError) {
        warnOnce('mask', 'mask pre-pass skipped a mask: ' + maskError);
      }
    }
    gl.colorMask(true, true, true, true);
    gl.enable(gl.BLEND);
    if (!drewMask) {
      // No usable mask geometry: draw the main drawable unclipped.
      gl.disable(gl.STENCIL_TEST);
      return false;
    }
    if (mainEntry.invertedMask) {
      gl.stencilFunc(gl.NOTEQUAL, 1, 0xff);
    } else {
      gl.stencilFunc(gl.EQUAL, 1, 0xff);
    }
    gl.stencilOp(gl.KEEP, gl.KEEP, gl.KEEP);
    return true;
  }

  function endMask(applied) {
    if (!applied) return;
    var gl = state.gl;
    if (gl) gl.disable(gl.STENCIL_TEST);
  }

  function applyBlend(constantFlags) {
    var gl = state.gl;
    if (!gl) return;
    gl.enable(gl.BLEND);
    if ((constantFlags & BLEND_ADDITIVE) !== 0) {
      gl.blendFunc(gl.ONE, gl.ONE);
    } else if ((constantFlags & BLEND_MULTIPLICATIVE) !== 0) {
      // Approximate multiplicative; not a faithful Cubism multiply blend.
      gl.blendFunc(gl.DST_COLOR, gl.ONE_MINUS_SRC_ALPHA);
    } else {
      gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA); // premultiplied "over"
    }
  }

  // ---------------------------------------------------------------------------
  // Public API.
  //
  // One canvas/context and one pair of shader programs are shared by every
  // scene. A scene owns its model, textures, geometry cache, texture-budget
  // estimate and camera fit, so a hot switch can preload a second model while
  // the first keeps drawing. Pattern (consulted, no code copied): three.js
  // WebGLRenderer (MIT) renders several scenes into one context with a
  // controlled clear, and PixiJS (MIT) scales a container's whole output by a
  // propagated alpha value.
  // ---------------------------------------------------------------------------
  var sceneId = 0;
  var FALLBACK_BUDGET_BYTES = 256 * 1024 * 1024;

  // options (all optional): textureBudgetBytes, the GPU memory budget for ALL
  // live scenes together (default 256 MiB, see live2d_texture_budget.js), and
  // maxTextureSize, which can only lower the GPU's MAX_TEXTURE_SIZE.
  function budgetApi() {
    var api = window.Live2DTextureBudget;
    if (!api || typeof api.planTextureSizes !== 'function') {
      warnOnce(
        'no-texture-budget',
        'window.Live2DTextureBudget is missing; load live2d_texture_budget.js before the renderer'
      );
      return null;
    }
    return api;
  }

  function defaultBudgetBytes() {
    var api = window.Live2DTextureBudget;
    return api && typeof api.DEFAULT_BUDGET_BYTES === 'number'
      ? api.DEFAULT_BUDGET_BYTES
      : FALLBACK_BUDGET_BYTES;
  }

  // Gets the shared context, or creates it once for the first scene. Returns
  // {ok:true} or {ok:false, reason} without throwing.
  function initContext(canvas) {
    if (state.gl) {
      if (canvas && state.canvas && canvas !== state.canvas) {
        warnOnce(
          'canvas-mismatch',
          'createScene() must reuse the prepare() canvas; a renderer owns one context'
        );
        return { ok: false, reason: 'canvas-mismatch' };
      }
      return { ok: true };
    }
    if (!canvas || typeof canvas.getContext !== 'function') {
      warnOnce('no-canvas', 'scene creation called without a usable canvas');
      return { ok: false, reason: 'no-canvas' };
    }
    try {
      var attributes = {
        alpha: true,
        premultipliedAlpha: true,
        antialias: true,
        depth: false,
        stencil: true,
        preserveDrawingBuffer: false,
      };
      var gl = canvas.getContext('webgl2', attributes);
      var version = 2;
      if (!gl) {
        gl = canvas.getContext('webgl', attributes);
        version = 1;
      }
      if (!gl) {
        warnOnce('no-webgl', 'WebGL2 and WebGL1 are both unavailable');
        return { ok: false, reason: 'webgl-unavailable' };
      }
      state.gl = gl;
      state.version = version;
      state.canvas = canvas;

      if (!state.listenersAttached) {
        state.listenersAttached = true;
        canvas.addEventListener(
          'webglcontextlost',
          function (event) {
            if (event && event.preventDefault) event.preventDefault();
            state.contextLost = true;
            state.ready = false;
            state.frameOpen = false;
            warnOnce('ctx-lost', 'WebGL context lost; rendering paused');
          },
          false
        );
        canvas.addEventListener(
          'webglcontextrestored',
          function () {
            state.contextLost = false;
            warnOnce('ctx-restored', 'WebGL context restored; reload the model to re-prepare');
          },
          false
        );
      }

      buildPrograms(gl);
      resizeCanvas();
      return { ok: true };
    } catch (contextError) {
      state.gl = null;
      state.drawProgram = null;
      state.maskProgram = null;
      warnOnce('context', 'could not create the WebGL context: ' + contextError);
      return {
        ok: false,
        reason: String((contextError && contextError.message) || contextError),
      };
    }
  }

  function liveSceneCount() {
    var count = 0;
    for (var i = 0; i < state.scenes.length; i++) {
      if (!state.scenes[i].disposed) count++;
    }
    return count;
  }

  function totalLiveBytes() {
    var total = 0;
    for (var i = 0; i < state.scenes.length; i++) {
      var scene = state.scenes[i];
      if (!scene.disposed && typeof scene.bytes === 'number') total += scene.bytes;
    }
    return total;
  }

  // Estimated texture bytes of one scene (0 for null/disposed).
  function sceneBytes(scene) {
    if (!scene || scene.disposed) return 0;
    return typeof scene.textureBytes === 'number' ? scene.textureBytes : 0;
  }

  function infoBytes(info) {
    if (typeof info === 'number') {
      return info >= 0 && info !== Infinity ? info : Infinity;
    }
    if (!info || typeof info !== 'object') return Infinity;
    var value = typeof info.bytes === 'number' ? info.bytes : info.textureBytes;
    return typeof value === 'number' && value >= 0 && value !== Infinity ? value : Infinity;
  }

  // Pure budget helper: true when existing scene bytes + the new scene estimate
  // still fit. newSceneInfo may be a number or {bytes|textureBytes}.
  function canBeAdded(existingBytes, newSceneInfo, budget) {
    var limit =
      typeof budget === 'number' && budget > 0 ? budget : defaultBudgetBytes();
    var existing =
      typeof existingBytes === 'number' && existingBytes > 0 ? existingBytes : 0;
    return existing + infoBytes(newSceneInfo) <= limit;
  }

  // Shared scene creation. The caller owns the generation token so a dispose()
  // during texture loading aborts this scene and deletes anything it uploaded.
  async function createSceneInternal(canvas, model, textureUrls, options, generation) {
    var api = budgetApi();
    if (!api) {
      state.lastError = 'texture-budget-unavailable';
      return null;
    }
    if (state.disposed) state.disposed = false;
    var init = initContext(canvas);
    if (!init.ok) {
      state.lastError = init.reason;
      return null;
    }
    var sceneOptions = options || {};
    var urls = Array.isArray(textureUrls) ? textureUrls : [];
    var loadResult;
    try {
      loadResult = await loadTextures(
        urls,
        api,
        sceneOptions,
        generation,
        totalLiveBytes()
      );
    } catch (loadError) {
      state.lastError = String((loadError && loadError.message) || loadError);
      warnOnce('scene-load', 'scene creation failed: ' + loadError);
      return null;
    }
    if (!loadResult) {
      // dispose() ran while fetching/decoding; uploaded textures were deleted.
      state.lastError = 'disposed';
      return null;
    }
    if (loadResult.rejected) {
      // Budget refusal happened before any decode/upload for this scene.
      state.lastError = 'texture_budget';
      return null;
    }

    var scene = {
      isLive2DScene: true,
      id: ++sceneId,
      model: model || null,
      canvas: state.canvas,
      glVersion: state.version,
      textures: loadResult.textures,
      cache: buildCache(model),
      fit: newFit(),
      textureInfo: loadResult.info,
      // Both names are kept: `.bytes` for internal sums, `.textureBytes` for the
      // documented public estimate.
      bytes: loadResult.info.bytes,
      textureBytes: loadResult.info.bytes,
      lastPositions: null,
      disposed: false,
    };
    computeFit(scene);
    state.scenes.push(scene);
    if (!state.currentScene) state.currentScene = scene;
    state.ready = true;
    state.lastError = null;
    return scene;
  }

  // Creates another scene on the shared canvas/context. Resolves the scene, or
  // null with Live2DRenderer.lastError set ('texture_budget' when refused before
  // any texture upload, 'canvas-mismatch', 'texture-budget-unavailable',
  // 'webgl-unavailable', 'no-canvas' or 'disposed').
  async function createScene(canvas, model, textureUrls, options) {
    return await createSceneInternal(
      canvas,
      model,
      textureUrls,
      options,
      state.generation
    );
  }

  // Backward-compatible single-scene entry point. Disposes everything, creates
  // one scene, makes it current and returns the same summary as before.
  async function prepare(canvas, model, textureUrls, options) {
    dispose();
    state.disposed = false;
    state.canvas = canvas || null;
    var generation = state.generation;
    if (!canvas || typeof canvas.getContext !== 'function') {
      state.lastError = 'no-canvas';
      warnOnce('no-canvas', 'prepare() called without a usable canvas');
      return { ok: false, reason: 'no-canvas' };
    }
    if (!budgetApi()) {
      state.lastError = 'texture-budget-unavailable';
      return { ok: false, reason: 'texture-budget-unavailable' };
    }
    try {
      var scene = await createSceneInternal(canvas, model, textureUrls, options, generation);
      if (!scene) {
        state.ready = false;
        return { ok: false, reason: state.lastError || 'scene-failed' };
      }
      state.currentScene = scene;
      var info = scene.textureInfo;
      var loaded = scene.textures;
      var summary = {
        ok: true,
        webgl: state.version,
        drawables: scene.cache.count,
        cached: scene.cache.withIndex,
        skipped: scene.cache.skipped,
        textures: loaded.length,
        loadedTextures: loaded.filter(Boolean).length,
        textureScale: info.scale,
        maxTextureSize: info.maxTextureSize,
        textureBytes: info.bytes,
        textureCount: info.count,
        textureBudgetBytes: info.budgetBytes,
      };
      if (window.console && window.console.info) {
        window.console.info(
          '[Live2DRenderer] prepare webgl' +
            state.version +
            ' drawables=' +
            summary.drawables +
            ' cached=' +
            summary.cached +
            ' skipped=' +
            summary.skipped +
            ' textures=' +
            summary.loadedTextures +
            '/' +
            summary.textures +
            ' textureScale=' +
            summary.textureScale +
            ' textureBytes=' +
            summary.textureBytes +
            ' maxTextureSize=' +
            summary.maxTextureSize
        );
      }
      return summary;
    } catch (prepareError) {
      state.ready = false;
      state.lastError = String((prepareError && prepareError.message) || prepareError);
      warnOnce('prepare', 'prepare failed: ' + prepareError);
      return { ok: false, reason: state.lastError };
    }
  }

  // Starts one frame: resize, viewport, one transparent clear. Call it before
  // drawing a cross-fade, then draw each scene with an alpha and endFrame().
  // draw() opens an implicit frame when the caller did not, so a single-scene
  // draw still clears (the legacy viewer's draw(model) contract).
  function beginFrame() {
    if (!state.gl || state.disposed) return false;
    if (state.frameOpen) return true;
    var gl = state.gl;
    try {
      if (state.contextLost || (gl.isContextLost && gl.isContextLost())) return false;
      resizeCanvas();
      gl.viewport(0, 0, state.pixelW, state.pixelH);
      gl.clearColor(0, 0, 0, 0); // transparent background for the WebView shell
      gl.clear(gl.COLOR_BUFFER_BIT | gl.STENCIL_BUFFER_BIT);
      gl.disable(gl.DEPTH_TEST);
      gl.disable(gl.CULL_FACE);
      gl.enable(gl.BLEND);
      gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
      state.frameOpen = true;
      return true;
    } catch (frameError) {
      warnOnce('frame', 'beginFrame() failed: ' + frameError);
      return false;
    }
  }

  function endFrame() {
    state.frameOpen = false;
  }

  function normalizeAlpha(alpha) {
    if (typeof alpha !== 'number' || !isFinite(alpha)) return 1; // default 1
    if (alpha <= 0) return 0;
    if (alpha >= 1) return 1;
    return alpha;
  }

  // draw(model) backwards compatibility: the scene that was made current by
  // prepare(), or the last live scene whose model matches the argument.
  function sceneForModel(model) {
    var current = state.currentScene;
    if (current && !current.disposed && current.model === model) return current;
    for (var i = state.scenes.length - 1; i >= 0; i--) {
      var scene = state.scenes[i];
      if (!scene.disposed && scene.model === model) return scene;
    }
    if (current && !current.disposed) return current;
    return state.scenes.length ? state.scenes[state.scenes.length - 1] : null;
  }

  function drawScene(scene, alpha) {
    if (!scene || scene.disposed) return;
    var gl = state.gl;
    var drawables = scene.model && scene.model.drawables;
    if (!drawables || typeof drawables.count !== 'number') return;

    if (!scene.cache || scene.cache.modelRef !== scene.model) {
      // Geometry cache does not match this model (defensive; createScene
      // normally handles this). Rebuild so we never index stale buffers.
      scene.cache = buildCache(scene.model);
      scene.cache.modelRef = scene.model;
      scene.fit.fitDone = false;
    }

    if (!scene.fit.fitDone) computeFit(scene);
    scene.lastPositions = drawables.vertexPositions;

    var count = drawables.count | 0;
    var renderOrders = scene.model.renderOrders;
    var order = [];
    for (var i = 0; i < count; i++) {
      var entryCheck = scene.cache.list[i];
      if (!entryCheck || !entryCheck.ok) continue;
      if (renderOrders && i < renderOrders.length) {
        order.push({ index: i, key: renderOrders[i] });
      } else {
        order.push({ index: i, key: i });
      }
    }
    order.sort(function (a, b) { return a.key - b.key; });

    var positions = drawables.vertexPositions;
    var opacities = drawables.opacities;
    var dynamicFlags = drawables.dynamicFlags;
    var multiplyColors = drawables.multiplyColors;
    var screenColors = drawables.screenColors;

    for (var k = 0; k < order.length; k++) {
      var drawableIndex = order[k].index;
      var entry = scene.cache.list[drawableIndex];
      try {
        if (dynamicFlags && drawableIndex < dynamicFlags.length) {
          if ((dynamicFlags[drawableIndex] & DYNAMIC_VISIBLE) !== DYNAMIC_VISIBLE) continue;
        }
        if (opacities && drawableIndex < opacities.length && opacities[drawableIndex] <= 0) continue;

        var positionArray = positions && positions[drawableIndex];
        if (!positionArray || positionArray.length < entry.vertexCount * 2) continue;

        var texture = textureFor(scene, entry.textureIndex);
        if (!texture) continue; // texture failed to load: skip, do not throw

        uploadPositions(entry, positionArray);

        var maskApplied = beginMask(scene, entry);
        applyBlend(entry.constantFlags);

        gl.useProgram(state.drawProgram);
        gl.uniformMatrix3fv(state.drawU.uProjection, false, scene.fit.projection);
        gl.uniform1f(state.drawU.u_alpha, alpha);
        bindGeometry(state.drawProgram, state.drawA, entry);
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, texture);
        gl.uniform1i(state.drawU.uTexture, 0);

        var opacity = opacities && drawableIndex < opacities.length ? opacities[drawableIndex] : 1;
        gl.uniform4f(state.drawU.uBaseColor, 1, 1, 1, opacity);

        var mr = 1;
        var mg = 1;
        var mb = 1;
        var sr = 0;
        var sg = 0;
        var sb = 0;
        var co = drawableIndex * 4;
        if (multiplyColors && co + 2 < multiplyColors.length) {
          mr = multiplyColors[co];
          mg = multiplyColors[co + 1];
          mb = multiplyColors[co + 2];
        }
        if (screenColors && co + 2 < screenColors.length) {
          sr = screenColors[co];
          sg = screenColors[co + 1];
          sb = screenColors[co + 2];
        }
        gl.uniform4f(state.drawU.uMultiplyColor, mr, mg, mb, 1);
        gl.uniform4f(state.drawU.uScreenColor, sr, sg, sb, 0);

        gl.drawElements(gl.TRIANGLES, entry.indexCount, gl.UNSIGNED_SHORT, 0);
        endMask(maskApplied);
      } catch (drawableError) {
        // A single bad drawable must never break the animation loop.
        warnOnce('drawable', 'drawable ' + drawableIndex + ' skipped: ' + drawableError);
        endMask(false);
        gl.disable(gl.STENCIL_TEST);
      }
    }
  }

  // draw(scene, alpha) draws that scene; draw(model) keeps the old single-scene
  // call working by drawing the tracked current/last scene at alpha 1.
  function draw(target, alpha) {
    if (state.disposed || !state.gl) return;
    var gl = state.gl;
    try {
      if (state.contextLost || (gl.isContextLost && gl.isContextLost())) return;
      var scene = null;
      var drawAlpha = 1;
      var autoFrame;
      if (target && target.isLive2DScene) {
        scene = target;
        drawAlpha = normalizeAlpha(alpha);
        autoFrame = !state.frameOpen;
      } else {
        // Legacy call: always clear once and draw at full opacity.
        if (!state.ready) return;
        scene = sceneForModel(target);
        state.frameOpen = false;
        autoFrame = true;
      }
      if (!scene || scene.disposed) return;
      if (!beginFrame()) return;
      drawScene(scene, drawAlpha);
      if (autoFrame) endFrame();
    } catch (error) {
      // Never throw out of draw(); report once and keep the loop alive.
      if (autoFrame) endFrame();
      warnOnce('draw', 'draw() error: ' + error);
    }
  }

  function freeSceneResources(scene, gl) {
    if (!scene || scene.disposed) return;
    scene.disposed = true;
    try {
      if (gl && scene.cache) {
        var list = scene.cache.list || [];
        for (var i = 0; i < list.length; i++) {
          var entry = list[i];
          if (!entry || !entry.ok) continue;
          try {
            if (entry.posBuf) gl.deleteBuffer(entry.posBuf);
            if (entry.uvBuf) gl.deleteBuffer(entry.uvBuf);
            if (entry.idxBuf) gl.deleteBuffer(entry.idxBuf);
          } catch (bufferError) {
            /* ignore individual buffer cleanup errors */
          }
        }
      }
    } catch (cacheError) {
      /* ignore */
    }
    try {
      if (gl && scene.textures) deleteTextures(gl, scene.textures);
    } catch (textureError) {
      /* ignore */
    }
    scene.cache = null;
    scene.textures = [];
    scene.textureInfo = emptyTextureInfo();
    scene.lastPositions = null;
  }

  function forgetScene(scene) {
    var index = state.scenes.indexOf(scene);
    if (index >= 0) state.scenes.splice(index, 1);
    if (state.currentScene === scene) {
      state.currentScene = state.scenes.length
        ? state.scenes[state.scenes.length - 1]
        : null;
    }
    state.ready = state.scenes.length > 0;
  }

  // Frees only this scene's geometry buffers and textures. The shared context
  // and programs stay usable for the remaining scenes (fade-out then dispose).
  function disposeScene(scene) {
    if (!scene || !scene.isLive2DScene) return false;
    if (!scene.disposed) freeSceneResources(scene, state.gl);
    forgetScene(scene);
    return true;
  }

  function dispose() {
    state.disposed = true;
    state.ready = false;
    state.frameOpen = false;
    // Stops a prepare()/createScene() that is still loading textures.
    state.generation++;
    var gl = state.gl;
    try {
      for (var i = 0; i < state.scenes.length; i++) {
        freeSceneResources(state.scenes[i], gl);
      }
      if (gl) {
        if (state.drawProgram) {
          try { gl.deleteProgram(state.drawProgram); } catch (programError) { /* ignore */ }
        }
        if (state.maskProgram) {
          try { gl.deleteProgram(state.maskProgram); } catch (programError2) { /* ignore */ }
        }
      }
    } catch (disposeError) {
      /* dispose must never throw */
    }
    state.scenes = [];
    state.currentScene = null;
    state.gl = null;
    state.canvas = null;
    state.drawProgram = null;
    state.maskProgram = null;
    state.drawU = null;
    state.drawA = null;
    state.maskU = null;
    state.maskA = null;
  }

  // Public surface used by live2d_viewer.js and the native WebView shell.
  window.Live2DRenderer = {
    version: '0.2.0-webgl-multi-scene',
    prepare: prepare,
    createScene: createScene,
    draw: draw,
    beginFrame: beginFrame,
    endFrame: endFrame,
    disposeScene: disposeScene,
    dispose: dispose,
    sceneBytes: sceneBytes,
    totalLiveBytes: totalLiveBytes,
    canBeAdded: canBeAdded,
    get lastError() {
      return state.lastError;
    },
    // Exposed for debugging / device validation only.
    diagnostics: function () {
      var scene = state.currentScene;
      if (scene && scene.disposed) scene = null;
      var info = scene ? scene.textureInfo : emptyTextureInfo();
      var textures = scene ? scene.textures : [];
      var cache = scene ? scene.cache : null;
      return {
        ready: state.ready,
        webgl: state.version,
        contextLost: state.contextLost,
        drawables: cache ? cache.count : 0,
        cached: cache ? cache.withIndex : 0,
        skipped: cache ? cache.skipped : 0,
        textures: textures.length,
        loadedTextures: textures.filter(Boolean).length,
        textureScale: info.scale,
        maxTextureSize: info.maxTextureSize,
        textureBytes: info.bytes,
        textureCount: info.count,
        textureBudgetBytes: info.budgetBytes,
        liveScenes: liveSceneCount(),
        totalTextureBytes: totalLiveBytes(),
      };
    },
  };
})();
