/*
 * Plain-JavaScript evaluator for Live2D motion3.json curves and exp3.json
 * expressions. It follows the public motion3.json and exp3.json format
 * descriptions (Live2D/CubismSpecs at e2de04dd4514, FileFormats/
 * motion3.json.md and exp3.json.md) without copying code or text.
 */
(function () {
  'use strict';

  var DEFAULT_FADE = 1.0;
  var MAX_CURVES = 4096;
  var MAX_NUMBERS = 1000000;
  var Priority = Object.freeze({
    NONE: 0,
    IDLE: 1,
    NORMAL: 2,
    FORCE: 3
  });

  function fail(message) {
    throw new Error('Live2DMotion: ' + message);
  }

  function isRecord(value) {
    return value !== null && typeof value === 'object' && !Array.isArray(value);
  }

  function isNumber(value) {
    return typeof value === 'number' && isFinite(value);
  }

  function isFade(value) {
    return isNumber(value) && value >= 0;
  }

  function fadeOr(value) {
    return isFade(value) ? value : DEFAULT_FADE;
  }

  function overrideFade(overrides, name) {
    if (overrides === undefined) {
      return null;
    }
    if (!isRecord(overrides)) {
      fail('overrides must be an object');
    }
    if (!(name in overrides) || overrides[name] === undefined) {
      return null;
    }
    if (!isFade(overrides[name])) {
      fail('invalid ' + name + ' override');
    }
    return overrides[name];
  }

  function clamp01(value) {
    if (!(value > 0)) {
      return 0;
    }
    return value > 1 ? 1 : value;
  }

  function ease(value) {
    var x = clamp01(value);
    return 0.5 - 0.5 * Math.cos(Math.PI * x);
  }

  function cubic(a, b, c, d, u) {
    var q = 1 - u;
    return q * q * q * a + 3 * q * q * u * b + 3 * q * u * u * c + u * u * u * d;
  }

  function compileCurve(source, restricted) {
    if (!isRecord(source)) {
      fail('curve must be an object');
    }
    if (source.Target !== 'Model' && source.Target !== 'Parameter' &&
        source.Target !== 'PartOpacity') {
      fail('unknown curve Target');
    }
    if (typeof source.Id !== 'string' || source.Id.length === 0) {
      fail('curve Id must be a non-empty string');
    }
    var segments = source.Segments;
    if (!Array.isArray(segments) || segments.length < 2) {
      fail('curve Segments must be an array with at least one point');
    }
    if (!isNumber(segments[0]) || !isNumber(segments[1])) {
      fail('non-finite point in Segments');
    }
    var previousValue = segments[1];
    var curve = {
      target: source.Target,
      id: source.Id,
      fadeIn: isFade(source.FadeInTime) ? source.FadeInTime : null,
      fadeOut: isFade(source.FadeOutTime) ? source.FadeOutTime : null,
      startTime: segments[0],
      startValue: previousValue,
      segments: []
    };
    var previousTime = segments[0];
    var i = 2;
    while (i < segments.length) {
      var type = segments[i++];
      if (!isNumber(type) || (type !== 0 && type !== 1 && type !== 2 && type !== 3)) {
        fail('unknown segment type');
      }
      var count = type === 1 ? 6 : 2;
      if (i + count > segments.length) {
        fail('truncated segment');
      }
      var startT = previousTime;
      var points = [];
      for (var j = 0; j < count; j++) {
        var number = segments[i + j];
        if (!isNumber(number)) {
          fail('non-finite number in segment');
        }
        if (j % 2 === 0 && number < previousTime) {
          fail('point time goes backwards');
        }
        if (j % 2 === 0) {
          previousTime = number;
        }
        points.push(number);
      }
      var segment = { type: type, t0: startT, v0: previousValue, restricted: restricted };
      if (type === 1) {
        segment.c1t = points[0];
        segment.c1v = points[1];
        segment.c2t = points[2];
        segment.c2v = points[3];
        segment.t1 = points[4];
        segment.v1 = points[5];
      } else {
        segment.t1 = points[0];
        segment.v1 = points[1];
      }
      curve.segments.push(segment);
      previousValue = segment.v1;
      i += count;
    }
    return curve;
  }

  function parseMotion(json, overrides) {
    if (!isRecord(json)) {
      fail('motion json must be an object');
    }
    var meta = json.Meta;
    if (!isRecord(meta)) {
      fail('missing or invalid Meta');
    }
    if (!Array.isArray(json.Curves)) {
      fail('missing or invalid Curves');
    }
    if (!isFade(meta.Duration)) {
      fail('Duration must be finite and non-negative');
    }
    if (json.Curves.length > MAX_CURVES) {
      fail('too many curves');
    }
    var inFade = overrideFade(overrides, 'fadeIn');
    var outFade = overrideFade(overrides, 'fadeOut');
    if (inFade === null) {
      inFade = fadeOr(meta.FadeInTime);
    }
    if (outFade === null) {
      outFade = fadeOr(meta.FadeOutTime);
    }
    var restricted = meta.AreBeziersRestricted === true;
    var totalNumbers = 0;
    var curves = [];
    for (var i = 0; i < json.Curves.length; i++) {
      var source = json.Curves[i];
      if (!isRecord(source) || !Array.isArray(source.Segments)) {
        fail('invalid curve Segments');
      }
      totalNumbers += source.Segments.length;
      if (totalNumbers > MAX_NUMBERS) {
        fail('too many segment numbers');
      }
      curves.push(compileCurve(source, restricted));
    }
    return {
      duration: meta.Duration,
      loop: meta.Loop === true,
      fadeIn: inFade,
      fadeOut: outFade,
      curves: curves
    };
  }

  function bezierParameter(segment, t) {
    var span = segment.t1 - segment.t0;
    if (!(span > 0)) {
      return 1;
    }
    var u = (t - segment.t0) / span;
    if (u <= 0) {
      return 0;
    }
    if (u >= 1) {
      return 1;
    }
    if (segment.restricted) {
      return u;
    }
    var low = 0;
    var high = 1;
    for (var i = 0; i < 48; i++) {
      var middle = (low + high) * 0.5;
      var x = cubic(segment.t0, segment.c1t, segment.c2t, segment.t1, middle);
      if (x < t) {
        low = middle;
      } else {
        high = middle;
      }
    }
    return (low + high) * 0.5;
  }

  function evaluateCurve(curve, t) {
    var segments = curve.segments;
    if (segments.length === 0 || t <= curve.startTime) {
      return curve.startValue;
    }
    for (var i = 0; i < segments.length; i++) {
      var segment = segments[i];
      if (t > segment.t1) {
        continue;
      }
      if (segment.type === 0) {
        var span = segment.t1 - segment.t0;
        var fraction = span > 0 ? clamp01((t - segment.t0) / span) : 1;
        return segment.v0 + (segment.v1 - segment.v0) * fraction;
      }
      if (segment.type === 2) {
        return t >= segment.t1 ? segment.v1 : segment.v0;
      }
      if (segment.type === 3) {
        return t > segment.t0 ? segment.v1 : segment.v0;
      }
      var u = bezierParameter(segment, t);
      return cubic(segment.v0, segment.c1v, segment.c2v, segment.v1, u);
    }
    return segments[segments.length - 1].v1;
  }

  function parseExpression(json) {
    if (!isRecord(json)) {
      fail('expression json must be an object');
    }
    if (json.Type !== undefined && json.Type !== 'Live2D Expression') {
      fail('unknown expression Type');
    }
    if (!Array.isArray(json.Parameters)) {
      fail('missing or invalid Parameters');
    }
    if (json.Parameters.length > MAX_CURVES) {
      fail('too many expression parameters');
    }
    var parameters = [];
    for (var i = 0; i < json.Parameters.length; i++) {
      var entry = json.Parameters[i];
      if (!isRecord(entry) || typeof entry.Id !== 'string' || entry.Id.length === 0) {
        fail('expression parameter Id must be a non-empty string');
      }
      if (!isNumber(entry.Value)) {
        fail('expression parameter Value must be finite');
      }
      var blend = entry.Blend === undefined ? 'Add' : entry.Blend;
      if (blend !== 'Add' && blend !== 'Multiply' && blend !== 'Overwrite') {
        fail('unknown expression Blend');
      }
      parameters.push({ id: entry.Id, value: entry.Value, blend: blend });
    }
    return {
      fadeIn: fadeOr(json.FadeInTime),
      fadeOut: fadeOr(json.FadeOutTime),
      parameters: parameters
    };
  }

  function makeLists(motion, resolve) {
    var lists = {
      parameters: [],
      opacities: [],
      eye: [],
      lip: [],
      blinks: resolve.blinkIndices() || [],
      mouths: resolve.mouthIndices() || []
    };
    for (var i = 0; i < motion.curves.length; i++) {
      var curve = motion.curves[i];
      if (curve.target === 'Parameter') {
        var parameter = resolve.parameterIndex(curve.id);
        if (parameter >= 0) {
          lists.parameters.push({ curve: curve, index: parameter });
        }
      } else if (curve.target === 'PartOpacity') {
        var part = resolve.partIndex(curve.id);
        if (part >= 0) {
          lists.opacities.push({ curve: curve, index: part });
        }
      } else if (curve.id === 'EyeBlink') {
        lists.eye.push(curve);
      } else if (curve.id === 'LipSync') {
        lists.lip.push(curve);
      }
    }
    return lists;
  }

  function curveWeight(entry, curve, nowS) {
    var inTime = curve.fadeIn === null ? entry.motion.fadeIn : curve.fadeIn;
    var outTime = curve.fadeOut === null ? entry.motion.fadeOut : curve.fadeOut;
    var inWeight = inTime === 0 ? 1 : ease((nowS - entry.start) / inTime);
    var outWeight = 1;
    if (entry.end !== Infinity) {
      outWeight = outTime === 0 ? 1 : ease((entry.end - nowS) / outTime);
    }
    return inWeight * outWeight;
  }

  function numberAt(array, index) {
    return typeof array[index] === 'number' ? array[index] : 0;
  }

  function markDriven(entry, driven, index, weight) {
    if (driven && entry.priority > Priority.IDLE && weight > 0) {
      driven[index] = 1;
    }
  }

  function localTime(entry, nowS) {
    var elapsed = nowS - entry.start;
    if (entry.motion.loop && entry.motion.duration > 0) {
      var duration = entry.motion.duration;
      return ((elapsed % duration) + duration) % duration;
    }
    return elapsed;
  }

  function createMotionQueue(resolve) {
    var entries = [];
    var lastNow = 0;

    function priorityAt(nowS) {
      for (var i = entries.length - 1; i >= 0; i--) {
        var entry = entries[i];
        if (!entry.fadingOut && entry.end > nowS) {
          return entry.priority;
        }
      }
      return Priority.NONE;
    }

    function applyEye(entry, curve, weight, t, values, driven) {
      var value = evaluateCurve(curve, t);
      for (var i = 0; i < entry.lists.blinks.length; i++) {
        var index = entry.lists.blinks[i];
        var current = numberAt(values, index);
        if (entry.written[index]) {
          values[index] = current + (current * value - current) * weight;
        } else {
          values[index] = current + (value - current) * weight;
        }
        markDriven(entry, driven, index, weight);
      }
    }

    function applyLip(entry, curve, weight, t, values, driven) {
      var value = evaluateCurve(curve, t);
      for (var i = 0; i < entry.lists.mouths.length; i++) {
        var index = entry.lists.mouths[i];
        var current = numberAt(values, index);
        if (entry.written[index]) {
          values[index] = current + value * weight;
        } else {
          values[index] = current + (value - current) * weight;
        }
        markDriven(entry, driven, index, weight);
      }
    }

    function update(values, opacities, nowS, driven) {
      lastNow = nowS;
      var alive = [];
      for (var e = 0; e < entries.length; e++) {
        var entry = entries[e];
        if (entry.end <= nowS) {
          continue;
        }
        alive.push(entry);
        var t = localTime(entry, nowS);
        var i;
        entry.written = Object.create(null);
        for (i = 0; i < entry.lists.parameters.length; i++) {
          var parameter = entry.lists.parameters[i];
          var weight = curveWeight(entry, parameter.curve, nowS);
          var value = evaluateCurve(parameter.curve, t);
          entry.written[parameter.index] = true;
          values[parameter.index] = numberAt(values, parameter.index) +
            (value - numberAt(values, parameter.index)) * weight;
          markDriven(entry, driven, parameter.index, weight);
        }
        for (i = 0; i < entry.lists.opacities.length; i++) {
          var opacity = entry.lists.opacities[i];
          var opacityWeight = curveWeight(entry, opacity.curve, nowS);
          var opacityValue = evaluateCurve(opacity.curve, t);
          opacities[opacity.index] = numberAt(opacities, opacity.index) +
            (opacityValue - numberAt(opacities, opacity.index)) * opacityWeight;
        }
        for (i = 0; i < entry.lists.eye.length; i++) {
          applyEye(entry, entry.lists.eye[i],
            curveWeight(entry, entry.lists.eye[i], nowS), t, values, driven);
        }
        for (i = 0; i < entry.lists.lip.length; i++) {
          applyLip(entry, entry.lists.lip[i],
            curveWeight(entry, entry.lists.lip[i], nowS), t, values, driven);
        }
      }
      entries = alive;
    }

    function start(motion, nowS, priority) {
      if (priority !== Priority.FORCE && priority < priorityAt(nowS)) {
        return false;
      }
      lastNow = nowS;
      for (var i = 0; i < entries.length; i++) {
        var entry = entries[i];
        if (!entry.fadingOut && entry.end > nowS) {
          entry.fadingOut = true;
          entry.end = Math.min(entry.end, nowS + entry.motion.fadeOut);
        }
      }
      entries.push({
        motion: motion,
        priority: priority,
        start: nowS,
        end: motion.loop ? Infinity : nowS + motion.duration,
        fadingOut: false,
        written: Object.create(null),
        lists: makeLists(motion, resolve)
      });
      return true;
    }

    function currentPriority() {
      return priorityAt(lastNow);
    }

    function isFinished() {
      for (var i = 0; i < entries.length; i++) {
        if (entries[i].end > lastNow) {
          return false;
        }
      }
      return true;
    }

    function stopAll() {
      entries.length = 0;
    }

    return Object.freeze({
      start: start,
      currentPriority: currentPriority,
      update: update,
      isFinished: isFinished,
      stopAll: stopAll
    });
  }

  function createExpressionQueue() {
    var current = null;
    var fading = [];

    function set(expression, nowS) {
      if (current) {
        fading.push({
          expression: current.expression,
          start: current.start,
          end: nowS + current.expression.fadeOut
        });
      }
      current = expression ? { expression: expression, start: nowS } : null;
    }

    function apply(entry, values, nowS, parameterIndex, fadingOut) {
      var expression = entry.expression;
      var inWeight = expression.fadeIn === 0 ? 1 :
        ease((nowS - entry.start) / expression.fadeIn);
      var outWeight = 1;
      if (fadingOut && entry.end !== Infinity) {
        outWeight = expression.fadeOut === 0 ? 1 :
          ease((entry.end - nowS) / expression.fadeOut);
      }
      var weight = inWeight * outWeight;
      for (var i = 0; i < expression.parameters.length; i++) {
        var parameter = expression.parameters[i];
        var index = parameterIndex(parameter.id);
        if (index < 0) {
          continue;
        }
        var value = numberAt(values, index);
        if (parameter.blend === 'Multiply') {
          value = value * (1 + (parameter.value - 1) * weight);
        } else if (parameter.blend === 'Overwrite') {
          value = value + (parameter.value - value) * weight;
        } else {
          value = value + parameter.value * weight;
        }
        values[index] = value;
      }
    }

    function update(values, nowS, parameterIndex) {
      var alive = [];
      for (var i = 0; i < fading.length; i++) {
        if (fading[i].end <= nowS) {
          continue;
        }
        alive.push(fading[i]);
        apply(fading[i], values, nowS, parameterIndex, true);
      }
      fading = alive;
      if (current) {
        apply(current, values, nowS, parameterIndex, false);
      }
    }

    function isEmpty() {
      return current === null && fading.length === 0;
    }

    return Object.freeze({
      set: set,
      update: update,
      isEmpty: isEmpty
    });
  }

  var api = Object.freeze({
    Priority: Priority,
    parseMotion: parseMotion,
    evaluateCurve: evaluateCurve,
    parseExpression: parseExpression,
    createMotionQueue: createMotionQueue,
    createExpressionQueue: createExpressionQueue
  });
  if (typeof window !== 'undefined' && window) { window.Live2DMotion = api; }
  if (typeof module !== 'undefined' && module && module.exports) { module.exports = api; }
}());
