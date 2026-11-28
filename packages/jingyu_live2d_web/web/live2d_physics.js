/*
 * live2d_physics.js: physics3.json evaluator for the Live2D viewer. Each
 * physics setting hangs a particle strand from a root that its inputs push
 * sideways and tilt; its outputs read the strand back into model parameters.
 * It runs once per frame, after motions, expressions and host overrides, and
 * before pose and model.update(). Call stabilize() once after load (or after a
 * model reset) so the strand starts at rest instead of swinging into place.
 *
 * The logic is ported to ES5 from Eatgrapes/Mocari @29a4792f93b7075049cee080ba11a3c834efd01c,
 * src/core/physics.rs, under the MIT License:
 *   L155-193 normalize_physics_parameter
 *   L195-204 weighted_normalized_value
 *   L206-240 translation and angle outputs
 *   L242-294 update_physics_particles
 *   L296-327 stabilize_physics_particles
 *   L329-352 vector helpers
 *   L354-382 constants and options
 *   L384-478 runtime construction
 *   L480-498 set_options / reset
 *   L500-599 evaluate (fixed-rate stepping and interpolation)
 *   L601-626 stabilize
 *   L629-705 evaluate_setting
 *   L707-779 stabilize_setting
 *   L781-830 accumulate_inputs
 *   L832-846 update_output_parameter
 *   L848-912 physics_range, particles_from_vertices, reset_particles,
 *              parent_gravity_for_particles
 *   Copyright (c) 2026 Eatgrapes
 *
 * directionToRadian's wrap loop follows psd2live
 * @f6d27de4baebe2f25144e1cc2422dc50a34b5e01, runtime/src/physics.rs L44-53,
 * under the MIT License:
 *   Copyright (c) 2026 PSD2Live contributors
 *
 * The physics3.json format is described by Live2D/CubismSpecs
 * @e2de04dd4514, FileFormats/physics3.json.md (format reference only; no text
 * copied).
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

  var MAXIMUM_WEIGHT = 100;
  var AIR_RESISTANCE = 5;
  var MAXIMUM_DELTA_TIME = 5;
  var MOVEMENT_THRESHOLD = 0.001;

  function isRecord(value) {
    return value !== null && typeof value === 'object' && !Array.isArray(value);
  }

  function isNumber(value) {
    return typeof value === 'number' && isFinite(value);
  }

  function hasOwn(object, key) {
    return Object.prototype.hasOwnProperty.call(object, key);
  }

  function copy(value) { return { x: value.x, y: value.y }; }
  function add(a, b) { return { x: a.x + b.x, y: a.y + b.y }; }
  function sub(a, b) { return { x: a.x - b.x, y: a.y - b.y }; }
  function mul(value, factor) { return { x: value.x * factor, y: value.y * factor }; }
  function div(value, factor) { return { x: value.x / factor, y: value.y / factor }; }

  function normalize(value) {
    var length = Math.sqrt(value.x * value.x + value.y * value.y);
    if (length === 0) { return value; }
    return { x: value.x / length, y: value.y / length };
  }

  function degreesToRadian(degrees) { return degrees * Math.PI / 180; }
  function radianToDirection(radian) { return { x: Math.sin(radian), y: Math.cos(radian) }; }

  function directionToRadian(from, to) {
    var radian = Math.atan2(to.y, to.x) - Math.atan2(from.y, from.x);
    while (radian < -Math.PI) { radian += 2 * Math.PI; }
    while (radian > Math.PI) { radian -= 2 * Math.PI; }
    return radian;
  }

  function parseKind(type) {
    return type === 'X' || type === 'Y' || type === 'Angle' ? type : null;
  }

  function parseRange(source) {
    if (!isRecord(source)) { return null; }
    if (!isNumber(source.Minimum) || !isNumber(source.Default) || !isNumber(source.Maximum)) {
      return null;
    }
    return { minimum: source.Minimum, maximum: source.Maximum, default: source.Default };
  }

  function parseInput(source) {
    if (!isRecord(source) || !isRecord(source.Source)) { return null; }
    if (source.Source.Target !== 'Parameter' || typeof source.Source.Id !== 'string') {
      return null;
    }
    if (!isNumber(source.Weight)) { return null; }
    var kind = parseKind(source.Type);
    if (kind === null) { return null; }
    if (source.Reflect !== undefined && typeof source.Reflect !== 'boolean') { return null; }
    return { id: source.Source.Id, kind: kind, reflect: source.Reflect === true,
      weight: source.Weight };
  }

  function parseOutput(source) {
    if (!isRecord(source) || !isRecord(source.Destination)) { return null; }
    if (source.Destination.Target !== 'Parameter' ||
        typeof source.Destination.Id !== 'string') {
      return null;
    }
    if (!isNumber(source.VertexIndex) || source.VertexIndex < 0 ||
        Math.floor(source.VertexIndex) !== source.VertexIndex) {
      return null;
    }
    if (!isNumber(source.Scale) || !isNumber(source.Weight)) { return null; }
    var kind = parseKind(source.Type);
    if (kind === null) { return null; }
    if (source.Reflect !== undefined && typeof source.Reflect !== 'boolean') { return null; }
    return { id: source.Destination.Id, vertexIndex: source.VertexIndex,
      scale: source.Scale, weight: source.Weight, kind: kind,
      reflect: source.Reflect === true };
  }

  function parseVertex(source) {
    if (!isRecord(source) || !isRecord(source.Position)) { return null; }
    if (!isNumber(source.Position.X) || !isNumber(source.Position.Y)) { return null; }
    if (!isNumber(source.Mobility) || !isNumber(source.Delay) ||
        !isNumber(source.Acceleration) || !isNumber(source.Radius)) {
      return null;
    }
    return { position: { x: source.Position.X, y: source.Position.Y },
      mobility: source.Mobility, delay: source.Delay,
      acceleration: source.Acceleration, radius: source.Radius };
  }

  function parseSetting(source) {
    if (!isRecord(source) || typeof source.Id !== 'string') { return null; }
    if (!Array.isArray(source.Input) || !Array.isArray(source.Output) ||
        !Array.isArray(source.Vertices)) {
      return null;
    }
    if (!isRecord(source.Normalization) || !isRecord(source.Normalization.Position) ||
        !isRecord(source.Normalization.Angle)) {
      return null;
    }
    var position = parseRange(source.Normalization.Position);
    var angle = parseRange(source.Normalization.Angle);
    if (position === null || angle === null) { return null; }
    var inputs = [];
    var outputs = [];
    var vertices = [];
    var i;
    for (i = 0; i < source.Input.length; i++) {
      var input = parseInput(source.Input[i]);
      if (input === null) { return null; }
      inputs.push(input);
    }
    for (i = 0; i < source.Output.length; i++) {
      var output = parseOutput(source.Output[i]);
      if (output === null) { return null; }
      outputs.push(output);
    }
    for (i = 0; i < source.Vertices.length; i++) {
      var vertex = parseVertex(source.Vertices[i]);
      if (vertex === null) { return null; }
      vertices.push(vertex);
    }
    return { id: source.Id, inputs: inputs, outputs: outputs, vertices: vertices,
      positionNormalization: position, angleNormalization: angle };
  }

  function parse(json) {
    if (!isRecord(json)) { return null; }
    if (json.Version !== undefined && json.Version !== 3) { return null; }
    if (!Array.isArray(json.PhysicsSettings) || json.PhysicsSettings.length === 0) {
      return null;
    }
    var meta = json.Meta;
    if (meta !== undefined && !isRecord(meta)) { return null; }
    var fps = 0;
    if (meta && meta.Fps !== undefined) {
      if (!isNumber(meta.Fps)) { return null; }
      fps = meta.Fps;
    }
    var gravity = { x: 0, y: -1 };
    var wind = { x: 0, y: 0 };
    if (meta && meta.EffectiveForces !== undefined) {
      var forces = meta.EffectiveForces;
      if (!isRecord(forces)) { return null; }
      if (forces.Gravity !== undefined) {
        if (!isRecord(forces.Gravity) || !isNumber(forces.Gravity.X) ||
            !isNumber(forces.Gravity.Y)) {
          return null;
        }
        gravity = { x: forces.Gravity.X, y: forces.Gravity.Y };
      }
      if (forces.Wind !== undefined) {
        if (!isRecord(forces.Wind) || !isNumber(forces.Wind.X) ||
            !isNumber(forces.Wind.Y)) {
          return null;
        }
        wind = { x: forces.Wind.X, y: forces.Wind.Y };
      }
    }
    var settings = [];
    for (var i = 0; i < json.PhysicsSettings.length; i++) {
      var setting = parseSetting(json.PhysicsSettings[i]);
      if (setting === null) { return null; }
      settings.push(setting);
    }
    return { fps: fps, gravity: gravity, wind: wind, settings: settings };
  }

  function normalizeParameter(value, parameter, normalized, reflect) {
    var maximum = Math.max(parameter.maximum, parameter.minimum);
    var minimum = Math.min(parameter.maximum, parameter.minimum);
    var clamped = Math.min(maximum, Math.max(minimum, value));
    var normalizedMinimum = Math.min(normalized.minimum, normalized.maximum);
    var normalizedMaximum = Math.max(normalized.minimum, normalized.maximum);
    var normalizedMiddle = normalized.default;
    var middle = minimum + Math.abs(maximum - minimum) / 2;
    var offset = clamped - middle;
    var result;
    if (offset > 0) {
      var normalizedLength = normalizedMaximum - normalizedMiddle;
      var parameterLength = maximum - middle;
      result = parameterLength === 0 ? 0 :
        offset * (normalizedLength / parameterLength) + normalizedMiddle;
    } else if (offset < 0) {
      var normalizedLengthDown = normalizedMinimum - normalizedMiddle;
      var parameterLengthDown = minimum - middle;
      result = parameterLengthDown === 0 ? 0 :
        offset * (normalizedLengthDown / parameterLengthDown) + normalizedMiddle;
    } else {
      result = normalizedMiddle;
    }
    if (result === 0) { return 0; }
    return reflect ? result : -result;
  }

  function weightedNormalizedValue(value, parameter, normalized, reflect, weightPercent) {
    return normalizeParameter(value, parameter, normalized, reflect) *
      (weightPercent / MAXIMUM_WEIGHT);
  }

  function outputTranslationX(translation, reflect) {
    return reflect ? -translation.x : translation.x;
  }

  function outputTranslationY(translation, reflect) {
    return reflect ? -translation.y : translation.y;
  }

  function outputAngle(translation, parentGravity, reflect) {
    var value = directionToRadian(parentGravity, translation);
    return reflect ? -value : value;
  }

  function parentGravityForParticles(particles, particleIndex, parentGravity) {
    if (particleIndex >= 2) {
      return sub(particles[particleIndex - 1].position,
        particles[particleIndex - 2].position);
    }
    return { x: -parentGravity.x, y: -parentGravity.y };
  }

  // Mocari L852-874 and psd2live Strand::new L87 both start lastGravity at
  // (0, 1); findings.md 2.3 says (0, -1), but the two sources agree, so the
  // port follows the sources.
  function particlesFromVertices(vertices) {
    var particles = [];
    var position = { x: 0, y: 0 };
    for (var i = 0; i < vertices.length; i++) {
      var vertex = vertices[i];
      if (i !== 0) { position = add(position, { x: 0, y: vertex.radius }); }
      particles.push({
        position: copy(position),
        lastPosition: copy(position),
        velocity: { x: 0, y: 0 },
        force: { x: 0, y: 0 },
        lastGravity: { x: 0, y: 1 },
        mobility: vertex.mobility,
        delay: vertex.delay,
        acceleration: vertex.acceleration,
        radius: vertex.radius
      });
    }
    return particles;
  }

  function resetParticles(particles) {
    var result = [];
    var position = { x: 0, y: 0 };
    for (var i = 0; i < particles.length; i++) {
      var particle = particles[i];
      if (i !== 0) { position = add(position, { x: 0, y: particle.radius }); }
      result.push({
        position: copy(position),
        lastPosition: copy(position),
        velocity: { x: 0, y: 0 },
        force: { x: 0, y: 0 },
        lastGravity: { x: 0, y: 1 },
        mobility: particle.mobility,
        delay: particle.delay,
        acceleration: particle.acceleration,
        radius: particle.radius
      });
    }
    return result;
  }

  function updateParticles(particles, totalTranslation, totalAngle, wind, threshold,
    deltaTime, airResistance) {
    if (particles.length === 0) { return; }
    var first = particles[0];
    first.position = copy(totalTranslation);
    var currentGravity = normalize(radianToDirection(degreesToRadian(totalAngle)));
    var previousPosition = copy(first.position);
    for (var i = 1; i < particles.length; i++) {
      var particle = particles[i];
      particle.force = add(mul(currentGravity, particle.acceleration), wind);
      particle.lastPosition = copy(particle.position);
      var delay = particle.delay * deltaTime * 30;
      var direction = sub(particle.position, previousPosition);
      var radian = directionToRadian(particle.lastGravity, currentGravity) /
        airResistance;
      var directionX = Math.cos(radian) * direction.x - direction.y * Math.sin(radian);
      var directionY = Math.sin(radian) * directionX + direction.y * Math.cos(radian);
      direction = { x: directionX, y: directionY };
      particle.position = add(previousPosition, direction);
      var velocity = mul(particle.velocity, delay);
      var force = mul(particle.force, delay * delay);
      particle.position = add(add(particle.position, velocity), force);
      var newDirection = normalize(sub(particle.position, previousPosition));
      particle.position = add(previousPosition, mul(newDirection, particle.radius));
      if (Math.abs(particle.position.x) < threshold) {
        particle.position = { x: 0, y: particle.position.y };
      }
      if (delay !== 0) {
        particle.velocity = mul(
          div(sub(particle.position, particle.lastPosition), delay),
          particle.mobility);
      }
      particle.force = { x: 0, y: 0 };
      particle.lastGravity = copy(currentGravity);
      previousPosition = copy(particle.position);
    }
  }

  function stabilizeParticles(particles, totalTranslation, totalAngle, wind, threshold) {
    if (particles.length === 0) { return; }
    var first = particles[0];
    first.position = copy(totalTranslation);
    var currentGravity = normalize(radianToDirection(degreesToRadian(totalAngle)));
    var previousPosition = copy(first.position);
    for (var i = 1; i < particles.length; i++) {
      var particle = particles[i];
      particle.force = add(mul(currentGravity, particle.acceleration), wind);
      particle.lastPosition = copy(particle.position);
      particle.velocity = { x: 0, y: 0 };
      var force = mul(normalize(particle.force), particle.radius);
      particle.position = add(previousPosition, force);
      if (Math.abs(particle.position.x) < threshold) {
        particle.position = { x: 0, y: particle.position.y };
      }
      particle.force = { x: 0, y: 0 };
      particle.lastGravity = copy(currentGravity);
      previousPosition = copy(particle.position);
    }
  }

  function updateOutputParameter(parameterValue, minimum, maximum, translation, output) {
    var low = Math.min(minimum, maximum);
    var high = Math.max(minimum, maximum);
    var value = Math.min(high, Math.max(low, translation * output.scale));
    var weight = output.weight / MAXIMUM_WEIGHT;
    if (weight >= 1) { return value; }
    return parameterValue * (1 - weight) + value * weight;
  }

  function accumulateInputs(setting, parameterValues, minimumValues, maximumValues,
    defaultValues) {
    var translationX = 0;
    var translationY = 0;
    var angle = 0;
    for (var i = 0; i < setting.inputs.length; i++) {
      var source = setting.inputs[i];
      var index = source.parameterIndex;
      if (index < 0 || index >= parameterValues.length ||
          index >= minimumValues.length || index >= maximumValues.length ||
          index >= defaultValues.length) {
        continue;
      }
      var parameter = { minimum: minimumValues[index], maximum: maximumValues[index],
        default: defaultValues[index] };
      var value = parameterValues[index];
      if (source.kind === 'X') {
        translationX += weightedNormalizedValue(value, parameter,
          setting.positionNormalization, source.reflect, source.weight);
      } else if (source.kind === 'Y') {
        translationY += weightedNormalizedValue(value, parameter,
          setting.positionNormalization, source.reflect, source.weight);
      } else {
        angle += weightedNormalizedValue(value, parameter,
          setting.angleNormalization, source.reflect, source.weight);
      }
    }
    return { translationX: translationX, translationY: translationY, angle: angle };
  }

  function rootTransform(accumulated) {
    var radian = degreesToRadian(-accumulated.angle);
    var rotatedX = accumulated.translationX * Math.cos(radian) -
      accumulated.translationY * Math.sin(radian);
    return {
      translation: {
        x: rotatedX,
        y: rotatedX * Math.sin(radian) + accumulated.translationY * Math.cos(radian)
      },
      angle: accumulated.angle
    };
  }

  function evaluateSetting(setting, parameterCache, minimumValues, maximumValues,
    defaultValues, options, deltaTime) {
    var accumulated = accumulateInputs(setting, parameterCache, minimumValues,
      maximumValues, defaultValues);
    var root = rootTransform(accumulated);
    updateParticles(setting.particles, root.translation, root.angle, options.wind,
      MOVEMENT_THRESHOLD * setting.positionNormalization.maximum, deltaTime,
      AIR_RESISTANCE);
    for (var i = 0; i < setting.outputs.length; i++) {
      var output = setting.outputs[i];
      var index = output.vertexIndex;
      if (index < 1 || index >= setting.particles.length) { continue; }
      var translation = sub(setting.particles[index].position,
        setting.particles[index - 1].position);
      var value;
      if (output.kind === 'X') {
        value = outputTranslationX(translation, output.reflect);
      } else if (output.kind === 'Y') {
        value = outputTranslationY(translation, output.reflect);
      } else {
        value = outputAngle(translation,
          parentGravityForParticles(setting.particles, index, options.gravity),
          output.reflect);
      }
      setting.currentOutputs[i] = value;
      var parameterIndex = output.parameterIndex;
      if (parameterIndex < 0 || parameterIndex >= parameterCache.length ||
          parameterIndex >= minimumValues.length ||
          parameterIndex >= maximumValues.length) {
        continue;
      }
      parameterCache[parameterIndex] = updateOutputParameter(
        parameterCache[parameterIndex], minimumValues[parameterIndex],
        maximumValues[parameterIndex], value, output);
    }
  }

  function stabilizeSetting(setting, parameterValues, minimumValues, maximumValues,
    defaultValues, options) {
    var accumulated = accumulateInputs(setting, parameterValues, minimumValues,
      maximumValues, defaultValues);
    var root = rootTransform(accumulated);
    stabilizeParticles(setting.particles, root.translation, root.angle, options.wind,
      MOVEMENT_THRESHOLD * setting.positionNormalization.maximum);
    for (var i = 0; i < setting.outputs.length; i++) {
      var output = setting.outputs[i];
      var index = output.vertexIndex;
      if (index < 1 || index >= setting.particles.length) { continue; }
      var translation = sub(setting.particles[index].position,
        setting.particles[index - 1].position);
      var value;
      if (output.kind === 'X') {
        value = outputTranslationX(translation, output.reflect);
      } else if (output.kind === 'Y') {
        value = outputTranslationY(translation, output.reflect);
      } else {
        value = outputAngle(translation,
          parentGravityForParticles(setting.particles, index, options.gravity),
          output.reflect);
      }
      var parameterIndex = output.parameterIndex;
      if (parameterIndex < 0 || parameterIndex >= parameterValues.length ||
          parameterIndex >= minimumValues.length ||
          parameterIndex >= maximumValues.length) {
        continue;
      }
      parameterValues[parameterIndex] = updateOutputParameter(
        parameterValues[parameterIndex], minimumValues[parameterIndex],
        maximumValues[parameterIndex], value, output);
    }
  }

  function create(rig, paramIds, mins, maxs, defs) {
    var ids = paramIds || [];
    var minimumValues = mins || [];
    var maximumValues = maxs || [];
    var defaultValues = defs || [];
    var indices = Object.create(null);
    for (var i = 0; i < ids.length; i++) {
      if (typeof ids[i] === 'string' && !hasOwn(indices, ids[i])) {
        indices[ids[i]] = i;
      }
    }
    var settings = [];
    var sourceSettings = rig && Array.isArray(rig.settings) ? rig.settings : [];
    for (var s = 0; s < sourceSettings.length; s++) {
      var source = sourceSettings[s];
      var inputs = [];
      var outputs = [];
      var j;
      for (j = 0; j < source.inputs.length; j++) {
        var input = source.inputs[j];
        if (!hasOwn(indices, input.id)) { continue; }
        inputs.push({ parameterIndex: indices[input.id], kind: input.kind,
          reflect: input.reflect, weight: input.weight });
      }
      for (j = 0; j < source.outputs.length; j++) {
        var output = source.outputs[j];
        if (!hasOwn(indices, output.id)) { continue; }
        outputs.push({ parameterIndex: indices[output.id],
          vertexIndex: output.vertexIndex, scale: output.scale,
          weight: output.weight, kind: output.kind, reflect: output.reflect });
      }
      if (outputs.length === 0) { continue; }
      var currentOutputs = [];
      var previousOutputs = [];
      for (j = 0; j < outputs.length; j++) {
        currentOutputs.push(0);
        previousOutputs.push(0);
      }
      settings.push({
        inputs: inputs,
        outputs: outputs,
        particles: particlesFromVertices(source.vertices),
        positionNormalization: source.positionNormalization,
        angleNormalization: source.angleNormalization,
        currentOutputs: currentOutputs,
        previousOutputs: previousOutputs
      });
    }

    // Runtime options start at the algorithm defaults, not at
    // Meta.EffectiveForces (findings 2.1); setOptions() changes them.
    var options = { gravity: { x: 0, y: -1 }, wind: { x: 0, y: 0 } };
    var remain = 0;
    var parameterCache = [];
    var parameterInputCache = [];
    var fps = rig && isNumber(rig.fps) ? rig.fps : 0;

    function evaluate(values, dtS) {
      if (typeof dtS !== 'number' || !isFinite(dtS) || dtS <= 0) { return; }
      var count = values.length;
      if (minimumValues.length !== count || maximumValues.length !== count ||
          defaultValues.length !== count) {
        return;
      }
      remain += dtS;
      if (remain > MAXIMUM_DELTA_TIME) { remain = 0; }
      if (parameterCache.length !== count) {
        parameterCache = [];
        for (var c = 0; c < count; c++) { parameterCache.push(0); }
      }
      if (parameterInputCache.length !== count) {
        parameterInputCache = [];
        for (var p = 0; p < count; p++) { parameterInputCache.push(values[p]); }
      }
      var physicsDeltaTime = fps > 0 && isFinite(fps) ? 1 / fps : dtS;
      if (!isFinite(physicsDeltaTime) || physicsDeltaTime <= 0) { return; }
      while (remain >= physicsDeltaTime) {
        var inputWeight = physicsDeltaTime / remain;
        for (var k = 0; k < count; k++) {
          parameterCache[k] = parameterInputCache[k] * (1 - inputWeight) +
            values[k] * inputWeight;
          parameterInputCache[k] = parameterCache[k];
        }
        for (var si = 0; si < settings.length; si++) {
          var setting = settings[si];
          for (var oi = 0; oi < setting.currentOutputs.length; oi++) {
            setting.previousOutputs[oi] = setting.currentOutputs[oi];
          }
          evaluateSetting(setting, parameterCache, minimumValues, maximumValues,
            defaultValues, options, physicsDeltaTime);
        }
        remain -= physicsDeltaTime;
      }
      var alpha = remain / physicsDeltaTime;
      for (var sf = 0; sf < settings.length; sf++) {
        var finalSetting = settings[sf];
        for (var of = 0; of < finalSetting.outputs.length; of++) {
          var finalOutput = finalSetting.outputs[of];
          var index = finalOutput.parameterIndex;
          if (index < 0 || index >= values.length || index >= minimumValues.length ||
              index >= maximumValues.length) {
            continue;
          }
          var raw = finalSetting.previousOutputs[of] * (1 - alpha) +
            finalSetting.currentOutputs[of] * alpha;
          values[index] = updateOutputParameter(values[index],
            minimumValues[index], maximumValues[index], raw, finalOutput);
        }
      }
    }

    function stabilize(values) {
      var count = values.length;
      if (minimumValues.length !== count || maximumValues.length !== count ||
          defaultValues.length !== count) {
        return;
      }
      for (var s = 0; s < settings.length; s++) {
        stabilizeSetting(settings[s], values, minimumValues, maximumValues,
          defaultValues, options);
      }
    }

    function reset() {
      options = { gravity: { x: 0, y: -1 }, wind: { x: 0, y: 0 } };
      remain = 0;
      parameterCache = [];
      parameterInputCache = [];
      for (var s = 0; s < settings.length; s++) {
        var setting = settings[s];
        setting.particles = resetParticles(setting.particles);
        for (var o = 0; o < setting.currentOutputs.length; o++) {
          setting.currentOutputs[o] = 0;
          setting.previousOutputs[o] = 0;
        }
      }
    }

    function setOptions(o) {
      if (!isRecord(o)) { return; }
      if (isRecord(o.gravity)) {
        if (isNumber(o.gravity.x)) { options.gravity.x = o.gravity.x; }
        if (isNumber(o.gravity.y)) { options.gravity.y = o.gravity.y; }
      }
      if (isRecord(o.wind)) {
        if (isNumber(o.wind.x)) { options.wind.x = o.wind.x; }
        if (isNumber(o.wind.y)) { options.wind.y = o.wind.y; }
      }
    }

    return Object.freeze({
      evaluate: evaluate,
      stabilize: stabilize,
      reset: reset,
      setOptions: setOptions
    });
  }

  var api = Object.freeze({
    parse: parse,
    create: create,
    normalizeParameter: normalizeParameter,
    directionToRadian: directionToRadian
  });

  if (typeof window !== 'undefined' && window) { window.Live2DPhysics = api; }
  if (typeof module !== 'undefined' && module && module.exports) { module.exports = api; }
}());
