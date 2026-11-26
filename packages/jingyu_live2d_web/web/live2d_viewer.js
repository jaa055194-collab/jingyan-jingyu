// Live2D viewer protocol layer for the WebView shell.
// This file handles messages from Flutter, loads the model through PurismCore,
// updates parameters and delegates pixel drawing to a renderer adapter
// (`window.Live2DRenderer`). It carries no model data of its own.
//
// Protocol (kept in sync with `Live2DRendererBridge` in jingyu_client_kit and
// the Android host in apps/client_flutter):
//   Flutter -> viewer: load, setParam, setExpression, setMotion, dispose
//   viewer -> Flutter: boot (once, before any other event), ready, error
// `ready` means the renderer adapter prepared and the first draw returned
// without throwing. A core-only update is never reported as ready.
// `ready` carries modelId and profileRev, and also `parameters` (runtime
// order, each {id, min, max, default}, a range value only when it is a finite
// number) and `parts` (part ID strings) when the runtime provides them. Each
// list is whole or absent, never cut short: a missing or malformed source, or
// one with more than 4096 entries, leaves that field out.
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

  async function load(command) {
    if (state.disposed) throw codedError('bad_command', 'viewer disposed');
    if (state.loading) throw codedError('bad_command', 'load already in progress');
    if (!core) throw new Error('PurismCore runtime missing');
    if (!window.Live2DRenderer ||
        typeof window.Live2DRenderer.prepare !== 'function' ||
        typeof window.Live2DRenderer.draw !== 'function') {
      throw new Error('renderer adapter missing');
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

  // Runs one core update + renderer draw. Returns false when no frame ran or
  // the frame failed; a failure is reported once and releases the model.
  function tick() {
    state.raf = 0;
    if (state.disposed || !state.model) return false;
    try {
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

  function setParam(command) {
    if (!state.ready || !state.model) throw new Error('model not ready');
    var parameters = state.model.parameters;
    if (!parameters) throw new Error('model has no parameters');
    for (var i = 0; i < parameters.count; i++) {
      if (parameters.ids[i] === command.name) {
        parameters.values[i] = command.value;
        return;
      }
    }
    throw new Error('unknown parameter ' + command.name);
  }

  function applyExpression(command) {
    if (!state.ready) throw new Error('model not ready');
    window.Live2DRenderer.setExpression(command.name);
  }

  function applyMotion(command) {
    if (!state.ready) throw new Error('model not ready');
    window.Live2DRenderer.setMotion(command.group, command.index);
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
        try { setParam(message); } catch (e) { fail(e, 'bad_command'); }
        break;
      case 'setExpression':
        try { applyExpression(message); } catch (e) { fail(e, 'bad_command'); }
        break;
      case 'setMotion':
        try { applyMotion(message); } catch (e) { fail(e, 'bad_command'); }
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
