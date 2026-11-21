// Live2D viewer protocol layer for the WebView shell.
// This file handles messages from Flutter, loads the model through PurismCore,
// updates parameters and delegates pixel drawing to a renderer adapter
// (`window.Live2DRenderer`). It carries no model data of its own.
//
// Protocol (kept in sync with `Live2DRendererBridge` in jingyu_client_kit):
//   Flutter -> viewer: load, setParam, setExpression, setMotion, dispose
//   viewer -> Flutter: ready, error
// `ready` means the renderer adapter prepared and the first draw returned
// without throwing. A core-only update is never reported as ready.
(function () {
  'use strict';

  var core = window.PurismCore || null;
  var state = {
    model: null,
    moc: null,
    modelId: null,
    profileRev: null,
    canvas: null,
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

  function fail(error) {
    post({ event: 'error', message: String(error && error.message ? error.message : error) });
  }

  async function fetchBytes(url) {
    var response = await fetch(url, { cache: 'no-store' });
    if (!response.ok) throw new Error('HTTP ' + response.status + ' for ' + url);
    return await response.arrayBuffer();
  }

  function resolve(base, relative) {
    return new URL(relative, base).toString();
  }

  function releaseModel() {
    if (state.model && state.model.release) state.model.release();
    if (state.moc && state.moc._release) state.moc._release();
    state.model = null;
    state.moc = null;
    state.ready = false;
  }

  async function load(command) {
    if (state.disposed) throw new Error('viewer disposed');
    if (state.loading) throw new Error('load already in progress');
    if (!core) throw new Error('PurismCore runtime missing');
    if (!window.Live2DRenderer ||
        typeof window.Live2DRenderer.prepare !== 'function' ||
        typeof window.Live2DRenderer.draw !== 'function') {
      throw new Error('renderer adapter missing');
    }

    state.loading = true;
    var moc = null;
    var model = null;
    try {
      state.canvas = state.canvas || document.getElementById('stage');
      var model3Url = command.model3;
      var json = await (await fetch(model3Url, { cache: 'no-store' })).json();
      var refs = json.FileReferences || {};
      if (!refs.Moc) throw new Error('model3 has no Moc reference');
      var mocBytes = await fetchBytes(resolve(model3Url, refs.Moc));
      moc = core.Moc.fromArrayBuffer(mocBytes);
      if (!moc) throw new Error('Moc rejected');
      model = core.Model.fromMoc(moc);
      if (!model) throw new Error('Model creation failed, code=' + moc.getError());

      var textures = [];
      var list = Array.isArray(command.textureUrls) && command.textureUrls.length
        ? command.textureUrls
        : (Array.isArray(refs.Textures) ? refs.Textures : []);
      for (var i = 0; i < list.length; i++) {
        textures.push(resolve(model3Url, list[i]));
      }

      releaseModel();
      state.moc = moc;
      state.model = model;
      state.modelId = command.modelId;
      state.profileRev = command.profileRev;

      await window.Live2DRenderer.prepare(state.canvas, model, textures);
      if (state.disposed) throw new Error('viewer disposed');

      state.ready = true;
      if (!tick()) {
        // tick() reported the first-frame error; never claim ready.
        releaseModel();
        return;
      }
      post({ event: 'ready', modelId: state.modelId, profileRev: state.profileRev });
    } catch (error) {
      releaseModel();
      throw error;
    } finally {
      state.loading = false;
    }
  }

  // Runs one core update + renderer draw. Returns false when the frame failed.
  function tick() {
    if (state.disposed || !state.model) return false;
    try {
      state.model.update();
      window.Live2DRenderer.draw(state.model);
    } catch (error) {
      fail(error);
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
    if (state.raf) window.cancelAnimationFrame(state.raf);
    state.raf = 0;
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
        load(message).catch(fail);
        break;
      case 'setParam':
        try { setParam(message); } catch (e) { fail(e); }
        break;
      case 'setExpression':
        try { applyExpression(message); } catch (e) { fail(e); }
        break;
      case 'setMotion':
        try { applyMotion(message); } catch (e) { fail(e); }
        break;
      case 'dispose':
        dispose();
        break;
      default:
        fail('unknown cmd ' + message.cmd);
    }
  }

  window.addEventListener('message', function (event) {
    var data = event.data;
    if (typeof data === 'string') {
      try { data = JSON.parse(data); } catch (_) { return; }
    }
    handle(data);
  });

  window.__live2dReceive = handle;
})();
