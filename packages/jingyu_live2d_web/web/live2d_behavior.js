/*
 * live2d_behavior.js: eye blink, focus with idle saccades, breath and envelope lip sync for
 * the Live2D viewer, applied in place by update() once per frame after motions and
 * expressions and before host overrides, physics, pose and model.update().
 *
 * The logic is ported to ES5 from these sources, each under the MIT License:
 *
 * - guansss/pixi-live2d-display@31317b37d5e22955a44d5b11f37f421e94a11269
 *   src/cubism-common/FocusController.ts L3-86 (focus interpolation)
 *   src/cubism4/Cubism4InternalModel.ts L239-249 (focus to parameter mapping)
 *   Copyright (c) 2020 Guan
 * - moeru-ai/airi@68b35a7b4e7f90fb5e3d6bcbe98c98b17c1cfa9f, under packages/stage-ui-live2d/src/
 *   composables/live2d/motion-manager.ts L317-507 (eye blink)
 *   composables/live2d/motion-manager.ts L791-840 (lip-sync release, without the hold)
 *   stores/motion-control.ts L100-106 and L148-215 (breath curve and its defaults)
 *   utils/eye-motions.ts L1-32 (saccade intervals)
 *   composables/live2d/animation.ts L19-23 (saccade targets)
 *   Copyright (c) 2024-PRESENT Neko Ayaka
 * - chyinan/Kokoro-Engine@0272b2f009011dace181570a4faf7455c7ba8426
 *   src/features/live2d/LipSyncProcessor.ts L80-88 (EMA formula only)
 *   Copyright (c) 2026 chyinan
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */
(function () {
  'use strict';

  // Focus interpolation (FocusController.ts).
  var FOCUS_EPSILON = 0.01;
  var FOCUS_MAX_SPEED = 40 / 7.5;
  var FOCUS_ACCELERATION_TIME = 1 / (0.15 * 1000);

  // Saccades: bucket i of the interval table (eye-motions.ts) has probability SACCADE_P[i]
  // and waits 800 + 400 * i ms plus up to 400 ms. Targets follow animation.ts.
  var SACCADE_P = [0.075, 0.110, 0.125, 0.140, 0.125, 0.050, 0.040, 0.030, 0.020, 1.000];
  var SACCADE_STEP_MS = 400;
  var SACCADE_SCALE = 0.5;
  var SACCADE_CDF = [];
  var SACCADE_BASE_MS = [];

  // Eye blink (motion-manager.ts).
  var BLINK_CLOSE_MS = 75;
  var BLINK_OPEN_MIN_MS = 150;
  var BLINK_OPEN_MAX_MS = 300;
  var BLINK_DELAY_MIN_MS = 3000;
  var BLINK_DELAY_MAX_MS = 8000;
  var BLINK_CLOSED_THRESHOLD = 0.15;
  var BLINK_IDLE = 0, BLINK_CLOSING = 1, BLINK_OPENING = 2;

  // airi's default breath options (motion-control.ts).
  var BREATH = Object.freeze({
    cycleSeconds: 2, exhaleDwellSeconds: 1.2, minimum: 0, maximum: 0.5, inhaleRatio: 0.4
  });

  // Lip sync: Kokoro's EMA with its default smoothing, then airi's smoothstep release.
  var LIP_SMOOTHING = 0.25;
  var LIP_SNAP = 0.001;
  var LIP_RELEASE_MS = 200;
  var LIP_MAX_LEVELS = 3000;
  var LIP_STEP_MIN_MS = 10;
  var LIP_STEP_MAX_MS = 100;
  var LIP_SILENT = 0, LIP_SPEAKING = 1, LIP_RELEASING = 2;

  var cumulative = 0;
  for (var bucket = 0; bucket < SACCADE_P.length; bucket++) {
    cumulative += SACCADE_P[bucket];
    SACCADE_CDF.push(cumulative);
    SACCADE_BASE_MS.push(800 + bucket * SACCADE_STEP_MS);
  }

  // Throws an error of the given type unless ok holds.
  function check(ok, Type, message) {
    if (!ok) { throw new Type('Live2DBehavior: ' + message); }
  }

  function hasOwn(object, key) { return Object.prototype.hasOwnProperty.call(object, key); }

  function isArrayLike(value) {
    return value !== null && typeof value === 'object' && typeof value.length === 'number';
  }

  function easeOutQuad(t) { return 1 - (1 - t) * (1 - t); }
  function easeInQuad(t) { return t * t; }
  function smoothstep(t) { return t * t * (3 - 2 * t); }

  // sampleLive2DBreath() with the default options, which need no normalising.
  function sampleBreath(elapsedSeconds) {
    var safeSeconds = isFinite(elapsedSeconds) ? Math.max(0, elapsedSeconds) : 0;
    var inRepeat = safeSeconds % (BREATH.cycleSeconds + BREATH.exhaleDwellSeconds);
    if (inRepeat >= BREATH.cycleSeconds) { return BREATH.minimum; }
    var phase = inRepeat / BREATH.cycleSeconds;
    var curve = phase < BREATH.inhaleRatio ?
      (1 - Math.cos(Math.PI * (phase / BREATH.inhaleRatio))) / 2 :
      (1 + Math.cos(Math.PI * ((phase - BREATH.inhaleRatio) / (1 - BREATH.inhaleRatio)))) / 2;
    return BREATH.minimum + (BREATH.maximum - BREATH.minimum) * curve;
  }

  function copyRange(values, count, name) {
    if (values === undefined || values === null) { return null; }
    check(isArrayLike(values) && values.length >= count, TypeError,
      'params.' + name + ' needs count entries');
    return new Float64Array(Array.prototype.slice.call(values, 0, count));
  }

  function readParams(params) {
    var count = params !== null && typeof params === 'object' ? params.count : NaN;
    check(typeof count === 'number' && Math.floor(count) === count && count >= 0, TypeError,
      'params.count must be an integer >= 0');
    check(isArrayLike(params.ids) && params.ids.length >= count, TypeError,
      'params.ids needs count entries');
    var index = Object.create(null);
    for (var i = 0; i < count; i++) {
      check(typeof params.ids[i] === 'string', TypeError, 'params.ids must hold strings');
      if (!hasOwn(index, params.ids[i])) { index[params.ids[i]] = i; }
    }
    return { count: count, index: index,
      min: copyRange(params.minimumValues, count, 'minimumValues'),
      max: copyRange(params.maximumValues, count, 'maximumValues') };
  }

  /*
   * create(params, options): params is {count, ids, minimumValues?, maximumValues?,
   * defaultValues?} (PurismCore model.parameters); ranges are copied, defaultValues is
   * unused, a missing minimum counts as 0 for blink and lip sync, and only parameters with
   * both range values finite are clamped. options.random returns [0, 1) (Math.random);
   * create() and reset() draw the blink delay, then the saccade bucket and jitter.
   * setBlinkIds/setMouthIds(ids): [] at first; an unknown or repeated ID throws an Error
   * and keeps the old list. blinkNow(): one blink unless one is running.
   * speak(levels, stepMs): up to 3000 levels in [0, 1], one per stepMs (integer 10-100),
   * from the next update(); speak([]) stops and releases (stepMs optional). Bad input
   * throws and changes nothing. update(values, dtMs, frame): dtMs finite and >= 0; frame
   * is {idle (default true), driven: null or a Uint8Array, 1 where a non-idle motion curve
   * wrote this frame}. reset(): no blink, focus centred and still, silent, timers resampled.
   */
  function create(params, options) {
    var model = readParams(params);
    var random = options && options.random !== undefined ? options.random : Math.random;
    check(typeof random === 'function', TypeError, 'options.random must be a function');
    var count = model.count, minimums = model.min, maximums = model.max;
    function find(id) { return hasOwn(model.index, id) ? model.index[id] : -1; }
    var eyeBallX = find('ParamEyeBallX'), eyeBallY = find('ParamEyeBallY');
    var angleX = find('ParamAngleX'), angleY = find('ParamAngleY'), angleZ = find('ParamAngleZ');
    var bodyAngleX = find('ParamBodyAngleX'), breathIndex = find('ParamBreath');

    var blinkIds = [], mouthIds = [];
    var touched = new Uint8Array(count); // 1 for each parameter this update() wrote
    var blink = { phase: BLINK_IDLE, progress: 0, delayMs: 0, openMs: BLINK_OPEN_MAX_MS };
    var focus = null, lip = null, saccadeWaitMs = 0, breathMs = 0;

    function minOf(id) { return minimums !== null && isFinite(minimums[id]) ? minimums[id] : 0; }
    function maxOf(id) { return maximums !== null && isFinite(maximums[id]) ? maximums[id] : NaN; }
    function randFloat(low, high) { return low + random() * (high - low); }

    function resolveIds(ids, name) {
      check(Array.isArray(ids), TypeError, name + '() needs an array of parameter IDs');
      var out = [];
      for (var i = 0; i < ids.length; i++) {
        check(typeof ids[i] === 'string' && hasOwn(model.index, ids[i]), Error,
          name + '(): unknown parameter ID ' + String(ids[i]));
        check(ids.indexOf(ids[i]) === i, Error, name + '(): repeated parameter ID ' + ids[i]);
        out.push(model.index[ids[i]]);
      }
      return out;
    }

    function startBlink() {
      blink.phase = BLINK_CLOSING;
      blink.progress = 0;
    }

    function resetBlink() {
      blink.phase = BLINK_IDLE;
      blink.progress = 0;
      blink.delayMs = BLINK_DELAY_MIN_MS + random() * (BLINK_DELAY_MAX_MS - BLINK_DELAY_MIN_MS);
    }

    // updateForcedBlink() with a base of 1: advances the blink and returns its factor.
    function advanceBlink(dt) {
      var eased;
      if (blink.phase === BLINK_IDLE) {
        blink.delayMs = Math.max(0, blink.delayMs - dt);
        if (blink.delayMs === 0) { startBlink(); }
        return 1;
      }
      if (blink.phase === BLINK_CLOSING) {
        blink.progress = Math.min(1, blink.progress + dt / BLINK_CLOSE_MS);
        eased = easeOutQuad(blink.progress);
        if (blink.progress >= 1) {
          blink.phase = BLINK_OPENING;
          blink.progress = 0;
          blink.openMs = BLINK_OPEN_MIN_MS + random() * (BLINK_OPEN_MAX_MS - BLINK_OPEN_MIN_MS);
        }
        return 1 - eased;
      }
      blink.progress = Math.min(1, blink.progress + dt / blink.openMs);
      eased = easeInQuad(blink.progress);
      if (blink.progress >= 1) { resetBlink(); }
      return eased;
    }

    function eyesClosed(values) {
      for (var i = 0; i < blinkIds.length; i++) {
        if (values[blinkIds[i]] - minOf(blinkIds[i]) > BLINK_CLOSED_THRESHOLD) { return false; }
      }
      return true;
    }

    function stepBlink(values, dt, idle, driven) {
      var i;
      if (blinkIds.length === 0) { return; }
      for (i = 0; !idle && driven !== null && i < blinkIds.length; i++) {
        if (driven[blinkIds[i]] === 1) {
          // A non-idle motion drives the eyes: no blink starts, a running one is dropped.
          if (blink.phase !== BLINK_IDLE) { resetBlink(); }
          return;
        }
      }
      var factor = advanceBlink(dt);
      // Nothing to write while open, or while every eye is closed already (an expression).
      if (factor >= 1 || eyesClosed(values)) { return; }
      for (i = 0; i < blinkIds.length; i++) {
        var low = minOf(blinkIds[i]);
        values[blinkIds[i]] = low + (values[blinkIds[i]] - low) * factor;
        touched[blinkIds[i]] = 1;
      }
    }

    function saccadeInterval() {
      var r = random();
      for (var i = 0; i < SACCADE_CDF.length; i++) {
        if (r <= SACCADE_CDF[i]) { return SACCADE_BASE_MS[i] + random() * SACCADE_STEP_MS; }
      }
      return SACCADE_BASE_MS[SACCADE_BASE_MS.length - 1] + random() * SACCADE_STEP_MS;
    }

    // FocusController.focus(x, y) without instant, then update(dt) with dt in ms.
    function focusOn(x, y) {
      focus.targetX = Math.min(1, Math.max(-1, x));
      focus.targetY = Math.min(1, Math.max(-1, y));
    }

    function advanceFocus(dt) {
      var dx = focus.targetX - focus.x;
      var dy = focus.targetY - focus.y;
      if (Math.abs(dx) < FOCUS_EPSILON && Math.abs(dy) < FOCUS_EPSILON) { return; }
      var d = Math.sqrt(dx * dx + dy * dy);
      var maxSpeed = FOCUS_MAX_SPEED / (1000 / dt);
      var ax = maxSpeed * (dx / d) - focus.vx;
      var ay = maxSpeed * (dy / d) - focus.vy;
      var a = Math.sqrt(ax * ax + ay * ay);
      var maxA = maxSpeed * FOCUS_ACCELERATION_TIME * dt;
      if (a > maxA) {
        ax *= maxA / a;
        ay *= maxA / a;
      }
      focus.vx += ax;
      focus.vy += ay;
      var v = Math.sqrt(focus.vx * focus.vx + focus.vy * focus.vy);
      var maxV = 0.5 * (Math.sqrt(maxA * maxA + 8 * maxA * d) - maxA);
      if (v > maxV) {
        focus.vx *= maxV / v;
        focus.vy *= maxV / v;
      }
      focus.x += focus.vx;
      focus.y += focus.vy;
    }

    function addTo(values, id, amount) {
      if (id >= 0) {
        values[id] += amount;
        touched[id] = 1;
      }
    }

    function stepFocus(values, dt, idle) {
      if (idle) {
        saccadeWaitMs -= dt;
        if (saccadeWaitMs <= 0) {
          var x = randFloat(-1, 1), y = randFloat(-1, 0.7);
          focusOn(x * SACCADE_SCALE, y * SACCADE_SCALE);
          saccadeWaitMs = saccadeInterval();
        }
      } else {
        focusOn(0, 0);
      }
      // A zero step would only clear the velocity (maxV is 0 then), so it is skipped.
      if (dt > 0) { advanceFocus(dt); }
      if (focus.x === 0 && focus.y === 0) { return; }
      addTo(values, eyeBallX, focus.x);
      addTo(values, eyeBallY, focus.y);
      addTo(values, angleX, focus.x * 30);
      addTo(values, angleY, focus.y * 30);
      addTo(values, angleZ, focus.x * focus.y * -30);
      addTo(values, bodyAngleX, focus.x * 10);
    }

    function stepBreath(values, dt, driven) {
      if (breathIndex < 0) { return; }
      breathMs += dt;
      if (driven !== null && driven[breathIndex] === 1) { return; }
      values[breathIndex] = sampleBreath(breathMs / 1000);
      touched[breathIndex] = 1;
    }

    // Lip sync state: elapsedMs is -1 until the first update of an envelope; last holds
    // the values written to the mouth IDs, the start of the release.
    function stopLip() {
      lip = { mode: LIP_SILENT, levels: null, stepMs: 0, elapsedMs: -1, level: 0,
        releaseMs: 0, last: new Float64Array(mouthIds.length), hasLast: false };
    }

    function startRelease() {
      if (!lip.hasLast) {
        stopLip();
        return;
      }
      lip.mode = LIP_RELEASING;
      lip.levels = null;
      lip.releaseMs = 0;
    }

    function stepLip(values, dt) {
      var i;
      if (lip.mode === LIP_SPEAKING) {
        lip.elapsedMs = lip.elapsedMs < 0 ? 0 : lip.elapsedMs + dt;
        var step = Math.floor(lip.elapsedMs / lip.stepMs);
        if (step < lip.levels.length) {
          // Kokoro: factor = 1 - e^(-smoothing * dt * 60) with dt in seconds.
          var factor = 1 - Math.exp(-LIP_SMOOTHING * (dt / 1000) * 60);
          lip.level = lip.level * (1 - factor) + lip.levels[step] * factor;
          if (lip.level < LIP_SNAP) { lip.level = 0; }
          for (i = 0; i < mouthIds.length; i++) {
            var low = minOf(mouthIds[i]);
            var span = isFinite(maxOf(mouthIds[i])) ? maxOf(mouthIds[i]) - low : 1;
            values[mouthIds[i]] = low + lip.level * span;
            lip.last[i] = values[mouthIds[i]];
            lip.hasLast = true;
            touched[mouthIds[i]] = 1;
          }
          return;
        }
        startRelease();
      }
      if (lip.mode === LIP_RELEASING) {
        lip.releaseMs += dt;
        if (lip.releaseMs >= LIP_RELEASE_MS) {
          stopLip(); // The incoming values are left alone from now on.
          return;
        }
        var blend = smoothstep(lip.releaseMs / LIP_RELEASE_MS);
        for (i = 0; i < mouthIds.length; i++) {
          values[mouthIds[i]] = lip.last[i] * (1 - blend) + values[mouthIds[i]] * blend;
          touched[mouthIds[i]] = 1;
        }
      }
    }

    function clampTouched(values) {
      for (var id = 0; id < count; id++) {
        if (touched[id] === 1 && minimums !== null && maximums !== null &&
          isFinite(minimums[id]) && isFinite(maximums[id])) {
          values[id] = Math.min(maximums[id], Math.max(minimums[id], values[id]));
        }
        touched[id] = 0;
      }
    }

    function speak(levels, stepMs) {
      check(Array.isArray(levels) || (ArrayBuffer.isView(levels) && !(levels instanceof DataView)),
        TypeError, 'speak() needs an array of levels');
      check(levels.length <= LIP_MAX_LEVELS, RangeError, 'speak() takes at most 3000 levels');
      check((levels.length === 0 && stepMs === undefined) || (typeof stepMs === 'number' &&
        Math.floor(stepMs) === stepMs && stepMs >= LIP_STEP_MIN_MS && stepMs <= LIP_STEP_MAX_MS),
        RangeError, 'speak() stepMs must be an integer from 10 to 100');
      var copy = new Float64Array(levels.length);
      for (var i = 0; i < levels.length; i++) {
        check(typeof levels[i] === 'number' && levels[i] >= 0 && levels[i] <= 1, RangeError,
          'speak() levels must be numbers in [0, 1]');
        copy[i] = levels[i];
      }
      if (copy.length === 0) {
        if (lip.mode === LIP_SPEAKING) { startRelease(); }
        return;
      }
      lip.mode = LIP_SPEAKING;
      lip.levels = copy;
      lip.stepMs = stepMs;
      lip.elapsedMs = -1;
    }

    function update(values, dtMs, frame) {
      check(isArrayLike(values) && values.length >= count, TypeError, 'update() values too short');
      check(typeof dtMs === 'number' && isFinite(dtMs) && dtMs >= 0, RangeError,
        'update() dtMs must be finite and >= 0');
      var idle = !(frame && frame.idle === false);
      var driven = frame && frame.driven ? frame.driven : null;
      check(driven === null || driven.length >= count, TypeError, 'update() driven too short');
      stepBlink(values, dtMs, idle, driven);
      stepFocus(values, dtMs, idle);
      stepBreath(values, dtMs, driven);
      stepLip(values, dtMs);
      clampTouched(values);
    }

    function reset() {
      resetBlink();
      focus = { targetX: 0, targetY: 0, x: 0, y: 0, vx: 0, vy: 0 };
      saccadeWaitMs = saccadeInterval();
      breathMs = 0;
      stopLip();
    }

    var behavior = Object.freeze({
      setBlinkIds: function (ids) { blinkIds = resolveIds(ids, 'setBlinkIds'); },
      setMouthIds: function (ids) {
        mouthIds = resolveIds(ids, 'setMouthIds');
        if (lip.mode === LIP_RELEASING) {
          stopLip();
        } else {
          lip.last = new Float64Array(mouthIds.length);
          lip.hasLast = false;
        }
      },
      blinkNow: function () {
        if (blink.phase === BLINK_IDLE) { startBlink(); }
      },
      speak: speak,
      update: update,
      reset: reset
    });
    reset();
    return behavior;
  }

  var api = Object.freeze({ create: create });

  if (typeof window !== 'undefined') { window.Live2DBehavior = api; }
  if (typeof module !== 'undefined' && module.exports) { module.exports = api; }
})();
