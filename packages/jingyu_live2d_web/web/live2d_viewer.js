// Live2D viewer protocol layer for the WebView shell.
// This file handles messages from Flutter, loads the model through PurismCore,
// updates parameters and delegates pixel drawing to a renderer adapter
// (`window.Live2DRenderer`). It carries no model data of its own.
//
// Protocol (kept in sync with `Live2DRendererBridge` in jingyu_client_kit and
// the Android host in apps/client_flutter):
//   Flutter -> viewer: load, setParam, clearParam, setExpression, setMotion,
//                      behavior, blink, speak, dispose
//   viewer -> Flutter: boot (once, before any other event), ready, error
// `ready` means the renderer adapter prepared and the first draw returned
// without throwing. A core-only update is never reported as ready.
// `ready` carries modelId and profileRev, and also `parameters` (runtime
// order, each {id, min, max, default}, a range value only when it is a finite
// number) and `parts` (part ID strings) when the runtime provides them. Each
// list is whole or absent, never cut short: a missing or malformed source, or
// one with more than 4096 entries, leaves that field out.
// `ready` also carries `expressions` (the Name of each staged model3
// FileReferences.Expressions entry whose exp3 file loaded and compiled for
// playback, in model3 order) and `motions` ({group, count} for each
// FileReferences.Motions group whose motion3 files all did). A model3 without
// the key reports an empty list.
// A malformed list, or one over the caps (1024 expressions, 4096 groups, 1024
// motions in a group, 4096 motions), leaves that field out, and so does a page
// without TextDecoder when the list has files to check. A file that does not
// load or compile only shapes the lists; it never fails the load.
// Each `error` carries `message` and one of these `code` values:
//   load_failed         the model could not be fetched, created or prepared
//   render_failed       a frame update or draw threw, first frame or later
//   webgl_context_lost  the canvas lost its WebGL context; a load that saw a
//                       loss fails with it even if the context came back
//   bad_command         a command was malformed or came at the wrong time
// render_failed and webgl_context_lost release the model and stop the frame
// loop. A later `load` starts over, but fails with webgl_context_lost until
// the browser restores the context. `dispose` is terminal.
//
// Animation (live2d_motion.js and live2d_behavior.js; a load fails without
// either). Each frame restores the parameter values saved after the previous
// frame's motions, plays the motion queue, saves, then applies the
// expression, blink, gaze, breath and lip sync, and last the values setParam
// holds. Part opacities keep their values from frame to frame. Whenever no
// other motion plays, a random motion of the first group named Idle (in any
// letter case) starts. A load takes the blink and mouth parameters from the
// model3 EyeBlink and LipSync groups. These commands need a ready model; a
// malformed one is a bad_command that changes nothing:
//   setParam {name, value}    holds a finite value, kept within the
//                             parameter's range, until clearParam {name} or
//                             the next load
//   setExpression {name}      fades to a listed expression; null fades out
//   setMotion {group, index}  plays a listed motion at force priority, from
//                             its start even when it is playing; a looping
//                             one plays until another motion replaces it
//   behavior {blink, mouth}   replaces the blink and mouth parameter ID lists
//                             (at most 64 model parameters each, no
//                             duplicates, [] for none)
//   blink {}                  blinks once now
//   speak {levels, step}      plays a mouth envelope, one 0..1 level per
//                             `step` ms (10..100, at most 3000); [] stops
//
// Transports. Viewer -> Flutter tries `Live2DBridge.postMessage` (an Android
// web message listener or a webview_flutter JavaScript channel), then the
// flutter_inappwebview `live2d` handler, then `parent.postMessage`.
// Flutter -> viewer arrives as `message` events on `Live2DBridge` (the
// Android reply proxy, which exists only after the boot message), as window
// `message` events, or through `window.__live2dReceive`.
(function () {
  'use strict';

  var core = window.PurismCore || null;
  var state = {
    model: null,
    moc: null,
    modelId: null,
    profileRev: null,
    canvas: null,
    canvasWatched: false,
    contextLost: false,
    contextLosses: 0,
    raf: 0,
    loading: false,
    ready: false,
    disposed: false,
    anim: null, // the shown model's animation (createAnimation)
    lastFrameTime: null, // the previous animation frame's timestamp, in ms
  };

  function post(message) {
    var text = JSON.stringify(message);
    try {
      if (window.Live2DBridge && window.Live2DBridge.postMessage) {
        window.Live2DBridge.postMessage(text);
        return;
      }
    } catch (_) {
      // fall through to the next transport
    }
    try {
      if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
        window.flutter_inappwebview.callHandler('live2d', text);
        return;
      }
    } catch (_) {
      // fall through to postMessage
    }
    if (window.parent && window.parent !== window) {
      window.parent.postMessage(message, '*');
    }
  }

  function codedError(code, message) {
    var error = new Error(message);
    error.viewerCode = code;
    return error;
  }

  function contextLostError() {
    return codedError('webgl_context_lost', 'WebGL context lost');
  }

  // Posts one error event. A code set by codedError wins over the caller's
  // code for its kind of failure.
  function fail(error, code) {
    post({
      event: 'error',
      code: error && error.viewerCode ? error.viewerCode : code,
      message: String(error && error.message ? error.message : error),
    });
  }

  async function fetchBytes(url) {
    var response = await fetch(url, { cache: 'no-store' });
    if (!response.ok) throw new Error('HTTP ' + response.status + ' for ' + url);
    return await response.arrayBuffer();
  }

  function resolve(base, relative) {
    return new URL(relative, base).toString();
  }

  function stopLoop() {
    if (state.raf) window.cancelAnimationFrame(state.raf);
    state.raf = 0;
  }

  function releaseModel() {
    if (state.model && state.model.release) state.model.release();
    if (state.moc && state.moc._release) state.moc._release();
    state.model = null;
    state.moc = null;
    state.anim = null;
    state.lastFrameTime = null;
    state.ready = false;
  }

  // A loss while a model is shown is reported here, once. A running load
  // reports the loss itself; an idle viewer reports it on the next load.
  // preventDefault asks the browser to restore the context later: without it
  // a lost context never comes back (Khronos WebGL wiki, HandlingContextLost).
  function onContextLost(event) {
    if (state.disposed) return;
    if (event && typeof event.preventDefault === 'function') event.preventDefault();
    if (state.contextLost) return;
    state.contextLost = true;
    state.contextLosses += 1;
    if (state.loading || !state.model) return;
    stopLoop();
    releaseModel();
    fail(contextLostError());
  }

  function onContextRestored() {
    state.contextLost = false;
  }

  function acquireCanvas() {
    if (!state.canvas) state.canvas = document.getElementById('stage');
    var canvas = state.canvas;
    if (canvas && !state.canvasWatched && typeof canvas.addEventListener === 'function') {
      state.canvasWatched = true;
      canvas.addEventListener('webglcontextlost', onContextLost, false);
      canvas.addEventListener('webglcontextrestored', onContextRestored, false);
    }
    return canvas;
  }

  // ID lists for `ready`. The host checks its mapping against complete ID
  // sets, so each list is reported whole or left out, never cut short. They
  // are read after the first frame and any failure only drops the field, so
  // they cannot fail a load or change when `ready` is sent.
  var MAX_READY_IDS = 4096;

  // Copies the IDs of a PurismCore {count, ids} object (Parameters, Parts), or
  // returns null when the source is missing, its count is not an integer in
  // [0, MAX_READY_IDS], it has fewer than count IDs, or an ID is not a
  // non-empty string.
  function reportableIds(source) {
    if (!source) return null;
    var count = source.count;
    if (!Number.isInteger(count) || count < 0 || count > MAX_READY_IDS) return null;
    var ids = source.ids;
    if (!ids || typeof ids !== 'object' || !(ids.length >= count)) return null;
    var copy = [];
    for (var i = 0; i < count; i++) {
      var id = ids[i];
      if (typeof id !== 'string' || id === '') return null;
      copy.push(id);
    }
    return copy;
  }

  function finiteAt(values, index) {
    var value = values ? values[index] : undefined;
    return Number.isFinite(value) ? value : undefined;
  }

  // Runtime-order [{id, min, max, default}]; a range value is present only
  // when it is a finite number. Null when the list is left out.
  function readyParameters(model) {
    try {
      var source = model.parameters;
      var ids = reportableIds(source);
      if (!ids) return null;
      var list = [];
      for (var i = 0; i < ids.length; i++) {
        var entry = { id: ids[i] };
        var min = finiteAt(source.minimumValues, i);
        var max = finiteAt(source.maximumValues, i);
        var def = finiteAt(source.defaultValues, i);
        if (min !== undefined) entry.min = min;
        if (max !== undefined) entry.max = max;
        if (def !== undefined) entry.default = def;
        list.push(entry);
      }
      return list;
    } catch (_) {
      return null;
    }
  }

  // Part ID strings in runtime order. Null when the list is left out.
  function readyParts(model) {
    try {
      return reportableIds(model.parts);
    } catch (_) {
      return null;
    }
  }

  // Expression and motion lists for `ready`, read from the staged model3:
  // Expressions [{Name, File}] and Motions {group: [{File, ...}]}. The caps
  // match Live2DModelInfo in jingyu_client_kit.
  var MAX_READY_EXPRESSIONS = 1024;
  var MAX_READY_MOTION_GROUPS = 4096;
  var MAX_READY_GROUP_MOTIONS = 1024;
  var MAX_READY_MOTIONS = 4096;
  var MAX_READY_NAME_LENGTH = 256;
  // The staging check's nesting limit (Live2DPackageLimits.maxJsonDepth).
  var MAX_JSON_DEPTH = 64;
  var MAX_PARALLEL_FETCHES = 4;

  function isObject(value) {
    return !!value && typeof value === 'object' && !Array.isArray(value);
  }

  // The URL of an entry's File, a non-empty string resolved against the
  // model3, or null when the entry is malformed.
  function entryUrl(base, entry) {
    if (!isObject(entry) || typeof entry.File !== 'string' || entry.File === '') {
      return null;
    }
    try {
      return resolve(base, entry.File);
    } catch (_) {
      return null;
    }
  }

  // [{name, urls}] in model3 order. [] without the key; null when the list is
  // malformed (an entry not an object, a File not a non-empty string, a Name
  // not a unique non-empty string of at most 256 units) or over the cap.
  function expressionEntries(base, refs) {
    if (!Object.prototype.hasOwnProperty.call(refs, 'Expressions')) return [];
    var list = refs.Expressions;
    if (!Array.isArray(list) || list.length > MAX_READY_EXPRESSIONS) return null;
    var seen = Object.create(null);
    var entries = [];
    for (var i = 0; i < list.length; i++) {
      var url = entryUrl(base, list[i]);
      var name = url ? list[i].Name : null;
      if (typeof name !== 'string' || name === '' ||
          name.length > MAX_READY_NAME_LENGTH || seen[name]) {
        return null;
      }
      seen[name] = true;
      entries.push({ name: name, urls: [url] });
    }
    return entries;
  }

  // [{group, urls, fades}] in model3 order, fades[j] holding entry j's fade
  // overrides (entryFades). [] without the key; null when the map is
  // malformed (a group name over 256 units, a group not a list, an entry not
  // an object, a File not a non-empty string) or over the caps. A group
  // without motions is left out, since a reported count is at least 1.
  function motionEntries(base, refs) {
    if (!Object.prototype.hasOwnProperty.call(refs, 'Motions')) return [];
    var groups = refs.Motions;
    if (!isObject(groups)) return null;
    var names = Object.keys(groups);
    if (names.length > MAX_READY_MOTION_GROUPS) return null;
    var total = 0;
    var entries = [];
    for (var i = 0; i < names.length; i++) {
      var list = groups[names[i]];
      if (names[i].length > MAX_READY_NAME_LENGTH || !Array.isArray(list) ||
          list.length > MAX_READY_GROUP_MOTIONS) {
        return null;
      }
      total += list.length;
      if (total > MAX_READY_MOTIONS) return null;
      var urls = [];
      var fades = [];
      for (var j = 0; j < list.length; j++) {
        var url = entryUrl(base, list[j]);
        if (!url) return null;
        urls.push(url);
        fades.push(entryFades(list[j]));
      }
      if (urls.length) entries.push({ group: names[i], urls: urls, fades: fades });
    }
    return entries;
  }

  // True when more than `limit` objects and arrays are open at once, counted
  // outside strings like the staging check.
  function exceedsJsonDepth(text, limit) {
    var depth = 0;
    var inString = false;
    for (var i = 0; i < text.length; i++) {
      var c = text.charCodeAt(i);
      if (inString) {
        if (c === 0x5c) i++; // skip the escaped character
        else if (c === 0x22) inString = false;
      } else if (c === 0x22) {
        inString = true;
      } else if (c === 0x7b || c === 0x5b) {
        if (++depth > limit) return true;
      } else if ((c === 0x7d || c === 0x5d) && depth > 0) {
        depth--;
      }
    }
    return false;
  }

  // The file as a JSON object, or null when it does not load as one: fetched,
  // valid UTF-8 (a leading BOM is dropped), nested at most MAX_JSON_DEPTH
  // deep, with an object root. Never throws.
  async function loadJsonObject(url) {
    try {
      var bytes = await fetchBytes(url);
      var text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
      if (exceedsJsonDepth(text, MAX_JSON_DEPTH)) return null;
      var json = JSON.parse(text);
      return isObject(json) ? json : null;
    } catch (_) {
      return null;
    }
  }

  // What `parser` of the live2d_motion.js API makes of a file's JSON, or null
  // when it rejects it.
  function compile(api, parser, json, extra) {
    try {
      return api[parser](json, extra) || null;
    } catch (_) {
      return null;
    }
  }

  // A model3 motion entry's FadeInTime or FadeOutTime, as the overrides
  // parseMotion takes: only a finite number >= 0 is kept.
  function entryFades(entry) {
    var fades = {};
    if (Number.isFinite(entry.FadeInTime) && entry.FadeInTime >= 0) {
      fades.fadeIn = entry.FadeInTime;
    }
    if (Number.isFinite(entry.FadeOutTime) && entry.FadeOutTime >= 0) {
      fades.fadeOut = entry.FadeOutTime;
    }
    return fades;
  }

  // Compiled expressions by Name and motion lists by group, for playback.
  function emptyPlay() {
    return { expressions: Object.create(null), motions: Object.create(null) };
  }

  // {expressions, motions, play}: the lists for `ready`, where a null list is
  // left out, and the compiled entries (emptyPlay) for playback. An
  // expression is listed when its file loads and compiles, and a motion group
  // when all of its files do, so a Name or a {group, index} keeps addressing
  // the staged model3. Each distinct file is loaded once, at most
  // MAX_PARALLEL_FETCHES at a time. Never throws.
  async function readyExpressionsAndMotions(base, refs, motionApi) {
    var play = emptyPlay();
    try {
      var expressions = expressionEntries(base, refs);
      var motions = motionEntries(base, refs);
      // Without TextDecoder no file can be checked, so a list with files is
      // left out rather than reported without them.
      if (typeof TextDecoder !== 'function') {
        if (expressions && expressions.length) expressions = null;
        if (motions && motions.length) motions = null;
      }
      var loaded = Object.create(null);
      var pending = [];
      [expressions || [], motions || []].forEach(function (entries) {
        entries.forEach(function (entry) {
          entry.urls.forEach(function (url) {
            if (!(url in loaded)) {
              loaded[url] = false;
              pending.push(url);
            }
          });
        });
      });
      var next = 0;
      var worker = async function () {
        while (next < pending.length) {
          var url = pending[next++];
          loaded[url] = await loadJsonObject(url);
        }
      };
      var workers = [];
      for (var i = 0; i < MAX_PARALLEL_FETCHES && i < pending.length; i++) {
        workers.push(worker());
      }
      await Promise.all(workers);
      var lists = { expressions: null, motions: null, play: play };
      if (expressions) {
        lists.expressions = [];
        expressions.forEach(function (entry) {
          var json = loaded[entry.urls[0]];
          var expression = json ? compile(motionApi, 'parseExpression', json) : null;
          if (!expression) return;
          play.expressions[entry.name] = expression;
          lists.expressions.push(entry.name);
        });
      }
      if (motions) {
        lists.motions = [];
        motions.forEach(function (entry) {
          var compiled = entry.urls.map(function (url, j) {
            var json = loaded[url];
            return json ? compile(motionApi, 'parseMotion', json, entry.fades[j]) : null;
          });
          if (!compiled.every(Boolean)) return;
          play.motions[entry.group] = compiled;
          lists.motions.push({ group: entry.group, count: compiled.length });
        });
      }
      return lists;
    } catch (_) {
      return { expressions: null, motions: null, play: emptyPlay() };
    }
  }

  // The model3's physics3 and pose3 files, parsed for evaluation. Either is
// null when the model3 does not reference it, it does not load, or the
// evaluator rejects it; such a model still loads, without that effect.
  async function loadEffects(base, refs) {
    var effects = { physics: null, pose: null };
    await Promise.all(['Physics', 'Pose'].map(async function (key) {
      if (typeof refs[key] !== 'string' || refs[key] === '') return;
      try {
        var json = await loadJsonObject(resolve(base, refs[key]));
        if (!json) return;
        var parsed = key === 'Physics'
          ? window.Live2DPhysics.parse(json)
          : window.Live2DPose.parse(json);
        if (parsed) effects[key.toLowerCase()] = parsed;
      } catch (_) {
        // A broken effect only drops that effect.
      }
    }));
    return effects;
  }

  // At most this many blink or mouth parameters, like the host's mapping.
  var MAX_BEHAVIOR_IDS = 64;

  // Index by ID of a PurismCore {count, ids} object; the first of a repeated
  // ID wins.
  function indexIds(source) {
    var index = Object.create(null);
    var count = source && Number.isInteger(source.count) ? source.count : 0;
    for (var i = 0; i < count; i++) {
      var id = source.ids[i];
      if (typeof id === 'string' && !(id in index)) index[id] = i;
    }
    return index;
  }

  // The IDs the model has, once each, of the first model3 Groups entry with
  // this Name; [] without one, or when it lists more than MAX_BEHAVIOR_IDS.
  function groupIds(model3, name, index) {
    var groups = Array.isArray(model3.Groups) ? model3.Groups : [];
    for (var i = 0; i < groups.length; i++) {
      if (!isObject(groups[i]) || groups[i].Name !== name) continue;
      var ids = Array.isArray(groups[i].Ids) ? groups[i].Ids : [];
      var list = [];
      for (var j = 0; j < ids.length; j++) {
        if (typeof ids[j] === 'string' && ids[j] in index && list.indexOf(ids[j]) < 0) {
          list.push(ids[j]);
        }
      }
      return list.length <= MAX_BEHAVIOR_IDS ? list : [];
    }
    return [];
  }

  // A copy of a behavior command's ID list, or an error: at most
  // MAX_BEHAVIOR_IDS parameter IDs the model has, each once.
  function behaviorIds(list, label, index) {
    if (!Array.isArray(list) || list.length > MAX_BEHAVIOR_IDS) {
      throw new Error(label + ' must list at most ' + MAX_BEHAVIOR_IDS + ' parameter IDs');
    }
    for (var i = 0; i < list.length; i++) {
      if (typeof list[i] !== 'string' || !(list[i] in index)) {
        throw new Error('unknown ' + label + ' parameter ' + list[i]);
      }
      if (list.indexOf(list[i]) !== i) throw new Error('repeated ' + label + ' parameter ' + list[i]);
    }
    return list.slice();
  }

  // The shown model's animation: the motion and expression queues of
  // live2d_motion.js, the procedural layer of live2d_behavior.js and the
  // values setParam holds. frame(dtMs) runs one frame's steps on the core's
  // parameter values and part opacities; the other methods are the commands.
  // Throws when the model's parameters cannot be read.
  function createAnimation(model, play, model3, effects) {
    var motionApi = window.Live2DMotion;
    var Priority = motionApi.Priority;
    var params = model.parameters;
    if (!params || !Number.isInteger(params.count) || !params.values) {
      throw new Error('model parameters unreadable');
    }
    var baseCount = params.count;
    var values = params.values;
    var baseIndex = indexIds(params);
    var paramIndex = Object.create(null);
    for (var key in baseIndex) paramIndex[key] = baseIndex[key];
    var parts = model.parts && model.parts.opacities ? model.parts : null;
    var opacities = parts ? parts.opacities : new Float32Array(0);
    var partIndex = parts ? indexIds(parts) : Object.create(null);
    var behavior = window.Live2DBehavior.create(params);
    var physics = null;
    var pose = null;
    if (effects && effects.physics) {
      try {
        physics = window.Live2DPhysics.create(effects.physics, params.ids,
          params.minimumValues, params.maximumValues, params.defaultValues);
      } catch (_) {
        physics = null;
      }
    }
    if (effects && effects.pose) {
      try {
        pose = window.Live2DPose.create(effects.pose, parts ? parts.ids : [],
          params.ids);
      } catch (_) {
        pose = null;
      }
    }
    // Part-id parameters the moc does not have live after the model's own:
    // motions and setParam can drive them, and pose reads them back.
    var extraIds = pose ? Object.keys(pose.extraParams) : [];
    var count = baseCount + extraIds.length;
    var extraIndex = Object.create(null);
    var workValues = new Float32Array(count);
    for (var i = 0; i < baseCount; i++) workValues[i] = values[i];
    for (i = 0; i < extraIds.length; i++) {
      var at = baseCount + i;
      extraIndex[extraIds[i]] = at;
      paramIndex[extraIds[i]] = at;
      workValues[at] = pose.extraParams[extraIds[i]];
    }
    var saved = new Float32Array(count);
    var driven = new Uint8Array(count);
    var held = Object.create(null); // parameter index -> value from setParam
    var blinkIndices = [];
    var mouthIndices = [];
    var now = 0; // seconds of animation time

    function lookup(index) {
      return function (id) { return typeof id === 'string' && id in index ? index[id] : -1; };
    }
    var parameterIndex = lookup(paramIndex);
    var queue = motionApi.createMotionQueue({
      parameterIndex: parameterIndex,
      partIndex: lookup(partIndex),
      blinkIndices: function () { return blinkIndices; },
      mouthIndices: function () { return mouthIndices; },
    });
    var expressions = motionApi.createExpressionQueue();

    function useBehaviorIds(blink, mouth) {
      behavior.setBlinkIds(blink);
      behavior.setMouthIds(mouth);
      blinkIndices = blink.map(parameterIndex);
      mouthIndices = mouth.map(parameterIndex);
    }
    useBehaviorIds(groupIds(model3, 'EyeBlink', baseIndex),
      groupIds(model3, 'LipSync', baseIndex));

    var idleMotions = null;
    Object.keys(play.motions).some(function (group) {
      if (group.toLowerCase() !== 'idle') return false;
      idleMotions = play.motions[group];
      return true;
    });

    if (pose) pose.reset(workValues, opacities);
    if (physics) physics.stabilize(workValues);
    for (i = 0; i < extraIds.length; i++) {
      workValues[baseCount + i] = pose ? pose.extraParams[extraIds[i]] : workValues[baseCount + i];
    }
    for (i = 0; i < count; i++) saved[i] = workValues[i];
    for (i = 0; i < baseCount; i++) values[i] = workValues[i];
    // Part opacities as loaded, restored before each frame's motions like
    // the parameter values, so a curve blends from the same base each frame.
    var savedOpacities = new Float32Array(opacities.length);
    for (i = 0; i < opacities.length; i++) savedOpacities[i] = opacities[i];

    function rangeValue(source, index) {
      var value = source ? source[index] : undefined;
      return Number.isFinite(value) ? value : null;
    }

    return {
      frame: function (dtMs) {
        now += dtMs / 1000;
        var dtS = dtMs / 1000;
        var k;
        for (k = 0; k < count; k++) workValues[k] = saved[k];
        for (k = 0; k < opacities.length; k++) opacities[k] = savedOpacities[k];
        if (idleMotions && queue.isFinished()) {
          var pick = Math.floor(Math.random() * idleMotions.length);
          queue.start(idleMotions[pick], now, Priority.IDLE);
        }
        driven.fill(0);
        queue.update(workValues, opacities, now, driven);
        for (k = 0; k < count; k++) saved[k] = workValues[k];
        expressions.update(workValues, now, parameterIndex);
        var idle = queue.currentPriority() <= Priority.IDLE;
        behavior.update(workValues, dtMs, { idle: idle, driven: idle ? null : driven });
        for (var key in held) workValues[key] = held[key];
        if (physics) physics.evaluate(workValues, dtS);
        if (pose) {
          for (k = 0; k < extraIds.length; k++) {
            pose.extraParams[extraIds[k]] = workValues[baseCount + k];
          }
          pose.evaluate(workValues, opacities, dtS);
        }
        for (k = 0; k < baseCount; k++) values[k] = workValues[k];
        // Pose changes part opacities each frame, so the next frame restores
        // the ones it left rather than the motion-only snapshot.
        for (k = 0; k < opacities.length; k++) savedOpacities[k] = opacities[k];
      },
      setParam: function (name, value) {
        var index = parameterIndex(name);
        if (index < 0) throw new Error('unknown parameter ' + name);
        if (typeof value !== 'number' || !Number.isFinite(value)) {
          throw new Error('parameter value must be a finite number');
        }
        var min = rangeValue(params.minimumValues, index);
        var max = rangeValue(params.maximumValues, index);
        if (min !== null && value < min) value = min;
        if (max !== null && value > max) value = max;
        held[index] = value;
      },
      clearParam: function (name) {
        var index = parameterIndex(name);
        if (index < 0) throw new Error('unknown parameter ' + name);
        delete held[index];
      },
      setExpression: function (name) {
        if (name === null) {
          expressions.set(null, now);
          return;
        }
        if (typeof name !== 'string' || !(name in play.expressions)) {
          throw new Error('unknown expression ' + name);
        }
        expressions.set(play.expressions[name], now);
      },
      setMotion: function (group, index) {
        var list = typeof group === 'string' && group in play.motions ? play.motions[group] : null;
        if (!list || !Number.isInteger(index) || index < 0 || index >= list.length) {
          throw new Error('unknown motion ' + group + ' ' + index);
        }
        queue.start(list[index], now, Priority.FORCE);
      },
      setBehavior: function (blink, mouth) {
        useBehaviorIds(behaviorIds(blink, 'blink', baseIndex),
          behaviorIds(mouth, 'mouth', baseIndex));
      },
      blink: function () {
        behavior.blinkNow();
      },
      speak: function (levels, step) {
        behavior.speak(levels, step === null ? undefined : step);
      },
    };
  }

  // Milliseconds since the previous animation frame, at most 100 so a stall
  // does not jump the animation; 0 for a first frame or one without a time.
  function frameDelta(time) {
    if (typeof time !== 'number' || !Number.isFinite(time)) return 0;
    var last = state.lastFrameTime;
    state.lastFrameTime = time;
    return last === null ? 0 : Math.min(100, Math.max(0, time - last));
  }

  async function load(command) {
    if (state.disposed) throw codedError('bad_command', 'viewer disposed');
    if (state.loading) throw codedError('bad_command', 'load already in progress');
    if (!core) throw new Error('PurismCore runtime missing');
    if (!window.Live2DRenderer ||
        typeof window.Live2DRenderer.prepare !== 'function' ||
        typeof window.Live2DRenderer.draw !== 'function') {
      throw new Error('renderer adapter missing');
    }
    if (!window.Live2DMotion || !window.Live2DBehavior ||
        !window.Live2DPhysics || !window.Live2DPose) {
      throw new Error('animation modules missing');
    }

    state.loading = true;
    var moc = null;
    var model = null;
    var adopted = false;
    // GL objects made before a loss stay unusable after a restore, so a load
    // that saw any loss must not claim ready.
    var losses = state.contextLosses;
    try {
      var canvas = acquireCanvas();
      if (state.contextLost) throw contextLostError();
      var model3Url = command.model3;
      var json = await (await fetch(model3Url, { cache: 'no-store' })).json();
      var refs = json.FileReferences || {};
      if (!refs.Moc) throw new Error('model3 has no Moc reference');
      var mocBytes = await fetchBytes(resolve(model3Url, refs.Moc));
      moc = core.Moc.fromArrayBuffer(mocBytes);
      if (!moc) throw new Error('Moc rejected');
      model = core.Model.fromMoc(moc);
      if (!model) throw new Error('Model creation failed, code=' + moc.getError());
      if (state.disposed) throw new Error('viewer disposed');

      // Loaded before the swap, so the shown model stays up meanwhile. Never
      // throws; a list that cannot be reported whole comes back null.
      var ready = await Promise.all([
        readyExpressionsAndMotions(model3Url, refs, window.Live2DMotion),
        loadEffects(model3Url, refs),
      ]);
      var lists = ready[0];
      var effects = ready[1];
      if (state.disposed) throw new Error('viewer disposed');

      var textures = [];
      var list = Array.isArray(command.textureUrls) && command.textureUrls.length
        ? command.textureUrls
        : (Array.isArray(refs.Textures) ? refs.Textures : []);
      for (var i = 0; i < list.length; i++) {
        textures.push(resolve(model3Url, list[i]));
      }

      // One frame loop at a time: stop the shown model's loop before the swap.
      stopLoop();
      releaseModel();
      state.moc = moc;
      state.model = model;
      adopted = true;
      state.modelId = command.modelId;
      state.profileRev = command.profileRev;
      // A model whose parameters cannot be read is shown without animation.
      try {
        state.anim = createAnimation(model, lists.play, json, effects);
      } catch (_) {
        state.anim = null;
      }

      var prepared = await window.Live2DRenderer.prepare(canvas, model, textures);
      if (state.disposed) throw new Error('viewer disposed');
      if (state.contextLost || state.contextLosses !== losses) throw contextLostError();
      if (!prepared || prepared.ok !== true) {
        throw new Error('renderer prepare failed: ' +
          (prepared && prepared.reason ? prepared.reason : 'no result'));
      }

      state.ready = true;
      // tick() reports a failed first frame and releases the model itself;
      // never claim ready after it.
      if (!tick()) return;
      var readyEvent = { event: 'ready', modelId: state.modelId, profileRev: state.profileRev };
      // The ID lists are optional: each helper returns null instead of
      // throwing, and a null list is left out of the event.
      var parameterList = readyParameters(model);
      if (parameterList) readyEvent.parameters = parameterList;
      var partList = readyParts(model);
      if (partList) readyEvent.parts = partList;
      if (lists.expressions) readyEvent.expressions = lists.expressions;
      if (lists.motions) readyEvent.motions = lists.motions;
      post(readyEvent);
    } catch (error) {
      stopLoop();
      if (!adopted) {
        if (model && model.release) model.release();
        if (moc && moc._release) moc._release();
      }
      releaseModel();
      if (state.disposed) return; // dispose ended this load; nothing to report
      // A step that failed because the context went away reports the loss,
      // so the host knows a retry can work once the context is restored.
      if (state.contextLost || state.contextLosses !== losses) throw contextLostError();
      throw error;
    } finally {
      state.loading = false;
    }
  }

  // Runs one animation frame, core update and renderer draw. `time` is the
  // requestAnimationFrame timestamp. Returns false when no frame ran or the
  // frame failed; a failure is reported once and releases the model.
  function tick(time) {
    state.raf = 0;
    if (state.disposed || !state.model) return false;
    try {
      var dt = frameDelta(time);
      if (state.anim) state.anim.frame(dt);
      state.model.update();
      window.Live2DRenderer.draw(state.model);
    } catch (error) {
      releaseModel();
      fail(error, 'render_failed');
      return false;
    }
    state.raf = window.requestAnimationFrame(tick);
    return true;
  }

  // Runs an animation command on the ready model. A malformed command throws
  // before it changes anything.
  function animate(command) {
    if (!state.ready || !state.model) throw new Error('model not ready');
    var anim = state.anim;
    if (!anim) throw new Error('animation unavailable for this model');
    switch (command.cmd) {
      case 'setParam': anim.setParam(command.name, command.value); break;
      case 'clearParam': anim.clearParam(command.name); break;
      case 'setExpression':
        anim.setExpression(command.name === undefined ? undefined : command.name);
        break;
      case 'setMotion': anim.setMotion(command.group, command.index); break;
      case 'behavior': anim.setBehavior(command.blink, command.mouth); break;
      case 'blink': anim.blink(); break;
      case 'speak': anim.speak(command.levels, command.step); break;
    }
  }

  function dispose() {
    state.disposed = true;
    state.loading = false;
    stopLoop();
    try {
      if (window.Live2DRenderer && window.Live2DRenderer.dispose) {
        window.Live2DRenderer.dispose();
      }
    } catch (_) {
      // best-effort cleanup; the bridge is already terminal
    }
    releaseModel();
    state.modelId = null;
    state.profileRev = null;
  }

  function handle(message) {
    if (!message || typeof message.cmd !== 'string') return;
    switch (message.cmd) {
      case 'load':
        load(message).catch(function (error) { fail(error, 'load_failed'); });
        break;
      case 'setParam':
      case 'clearParam':
      case 'setExpression':
      case 'setMotion':
      case 'behavior':
      case 'blink':
      case 'speak':
        try { animate(message); } catch (e) { fail(e, 'bad_command'); }
        break;
      case 'dispose':
        dispose();
        break;
      default:
        fail('unknown cmd ' + message.cmd, 'bad_command');
    }
  }

  function receive(data) {
    if (typeof data === 'string') {
      try { data = JSON.parse(data); } catch (_) { return; }
    }
    handle(data);
  }

  window.addEventListener('message', function (event) {
    receive(event.data);
  });

  // Android web message listener: host commands arrive as message events on
  // the injected object, through the reply proxy of the page's latest message.
  var bridge = window.Live2DBridge;
  if (bridge && typeof bridge.addEventListener === 'function') {
    bridge.addEventListener('message', function (event) {
      receive(event && event.data);
    });
  }

  window.__live2dReceive = handle;
  post({ event: 'boot' });
})();
