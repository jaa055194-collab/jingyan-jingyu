// Live2D viewer protocol layer for the WebView shell.
// This file handles messages from Flutter, loads the model through PurismCore,
// updates parameters and delegates pixel drawing to an optional renderer
// adapter (`window.Live2DRenderer`). It carries no model data of its own.
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
    disposed: false,
  };

  function post(message) {
    var text = JSON.stringify(message);
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

  async function load(command) {
    if (!core) throw new Error('PurismCore runtime missing');
    if (state.disposed) throw new Error('viewer disposed');
    state.canvas = state.canvas || document.getElementById('stage');
    var model3Url = command.model3;
    var json = await (await fetch(model3Url, { cache: 'no-store' })).json();
    var refs = json.FileReferences || {};
    if (!refs.Moc) throw new Error('model3 has no Moc reference');
    var mocBytes = await fetchBytes(resolve(model3Url, refs.Moc));
    var moc = core.Moc.fromArrayBuffer(mocBytes);
    if (!moc) throw new Error('Moc rejected');
    var model = core.Model.fromMoc(moc);
    if (!model) throw new Error('Model creation failed, code=' + moc.getError());

    var textures = [];
    var list = Array.isArray(refs.Textures) ? refs.Textures : [];
    for (var i = 0; i < list.length; i++) {
      textures.push(resolve(model3Url, list[i]));
    }

    state.moc = moc;
    state.model = model;
    state.modelId = command.modelId;
    state.profileRev = command.profileRev;

    if (window.Live2DRenderer && window.Live2DRenderer.prepare) {
      await window.Live2DRenderer.prepare(state.canvas, model, textures);
    }
    tick();
    post({ event: 'ready', modelId: state.modelId, profileRev: state.profileRev });
  }

  function tick() {
    if (state.disposed || !state.model) return;
    try {
      state.model.update();
      if (window.Live2DRenderer && window.Live2DRenderer.draw) {
        window.Live2DRenderer.draw(state.model);
      }
    } catch (error) {
      fail(error);
      return;
    }
    state.raf = window.requestAnimationFrame(tick);
  }

  function setParam(command) {
    if (!state.model) throw new Error('model not ready');
    var parameters = state.model.parameters;
    if (!parameters) throw new Error('model has no parameters');
    for (var i = 0; i < parameters.count; i++) {
      if (parameters.ids[i] === command.name) {
        parameters.values[i] = command.value;
        return;
      }
    }
  }

  function applyExpression(command) {
    if (window.Live2DRenderer && window.Live2DRenderer.setExpression) {
      window.Live2DRenderer.setExpression(command.name);
    }
  }

  function applyMotion(command) {
    if (window.Live2DRenderer && window.Live2DRenderer.setMotion) {
      window.Live2DRenderer.setMotion(command.group, command.index);
    }
  }

  function dispose() {
    state.disposed = true;
    if (state.raf) window.cancelAnimationFrame(state.raf);
    if (state.model && state.model.release) state.model.release();
    if (state.moc && state.moc._release) state.moc._release();
    state.model = null;
    state.moc = null;
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
        applyExpression(message);
        break;
      case 'setMotion':
        applyMotion(message);
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
