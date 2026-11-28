/*
 * live2d_pose.js: pose3.json evaluator for the Live2D viewer. Each pose group
 * shows one part at a time: the visible part fades in and the others fade out
 * behind it, with linked parts following their part. It runs once per frame,
 * after motions, expressions, behaviour and physics, and before
 * model.update(); it writes only part opacities, so the Core propagates them
 * to drawables. Part-id parameters that the model does not have live in
 * pose.extraParams, which the host's setParam and motion routing may write.
 *
 * The logic is ported to ES5 from Eatgrapes/Mocari @29a4792f93b7075049cee080ba11a3c834efd01c,
 * src/json/pose3.rs, under the MIT License:
 *   L6 DEFAULT_POSE_FADE_IN_TIME
 *   L9-72 Pose3, RawPose3 and PosePart parsing
 *   L74-79 resolved_pose_fade_in_time
 *   L81-138 update_pose_group_opacities
 *   L140-159 copy_pose_link_opacities
 *   Copyright (c) 2026 Eatgrapes
 *
 * The pose3.json format is described by Live2D/CubismSpecs
 * @e2de04dd4514, FileFormats/pose3.json.md (format reference only; no text
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

  var DEFAULT_FADE_IN_TIME = 0.5;
  var VISIBLE_THRESHOLD = 0.001;
  var PHI = 0.5;
  var BACK_OPACITY_THRESHOLD = 0.15;

  function isRecord(value) {
    return value !== null && typeof value === 'object' && !Array.isArray(value);
  }

  function isNumber(value) {
    return typeof value === 'number' && isFinite(value);
  }

  function hasOwn(object, key) {
    return Object.prototype.hasOwnProperty.call(object, key);
  }

  function parse(json) {
    if (!isRecord(json)) { return null; }
    if (json.Type !== undefined && json.Type !== 'Live2D Pose') { return null; }
    var fadeInTime = DEFAULT_FADE_IN_TIME;
    if (json.FadeInTime !== undefined) {
      if (!isNumber(json.FadeInTime)) { return null; }
      if (json.FadeInTime >= 0) { fadeInTime = json.FadeInTime; }
    }
    var sourceGroups = json.Groups;
    if (sourceGroups === undefined) { sourceGroups = []; }
    if (!Array.isArray(sourceGroups)) { return null; }
    var groups = [];
    for (var g = 0; g < sourceGroups.length; g++) {
      var sourceGroup = sourceGroups[g];
      if (!Array.isArray(sourceGroup)) { return null; }
      var entries = [];
      for (var e = 0; e < sourceGroup.length; e++) {
        var source = sourceGroup[e];
        if (!isRecord(source) || typeof source.Id !== 'string' ||
            source.Id.length === 0) {
          return null;
        }
        var sourceLinks = source.Link;
        if (sourceLinks === undefined) { sourceLinks = []; }
        if (!Array.isArray(sourceLinks)) { return null; }
        var links = [];
        for (var l = 0; l < sourceLinks.length; l++) {
          if (typeof sourceLinks[l] !== 'string') { return null; }
          links.push(sourceLinks[l]);
        }
        entries.push({ id: source.Id, links: links });
      }
      groups.push(entries);
    }
    return { fadeInTime: fadeInTime, groups: groups };
  }

  function create(pose, partIds, paramIds) {
    var parts = partIds || [];
    var params = paramIds || [];
    var partIndex = Object.create(null);
    var paramIndex = Object.create(null);
    var i;
    for (i = 0; i < parts.length; i++) {
      if (typeof parts[i] === 'string' && !hasOwn(partIndex, parts[i])) {
        partIndex[parts[i]] = i;
      }
    }
    for (i = 0; i < params.length; i++) {
      if (typeof params[i] === 'string' && !hasOwn(paramIndex, params[i])) {
        paramIndex[params[i]] = i;
      }
    }
    var extraParams = {};
    var groups = [];
    var sourceGroups = pose && Array.isArray(pose.groups) ? pose.groups : [];
    for (var g = 0; g < sourceGroups.length; g++) {
      var sourceEntries = sourceGroups[g];
      var entries = [];
      for (var e = 0; e < sourceEntries.length; e++) {
        var source = sourceEntries[e];
        if (!hasOwn(partIndex, source.id)) { continue; }
        var links = [];
        for (var l = 0; l < source.links.length; l++) {
          if (hasOwn(partIndex, source.links[l])) {
            links.push(partIndex[source.links[l]]);
          }
        }
        var parameterIndex = hasOwn(paramIndex, source.id) ?
          paramIndex[source.id] : -1;
        if (parameterIndex < 0 && !hasOwn(extraParams, source.id)) {
          extraParams[source.id] = 0;
        }
        entries.push({
          id: source.id,
          partIndex: partIndex[source.id],
          paramIndex: parameterIndex,
          linkIndices: links
        });
      }
      if (entries.length > 0) { groups.push(entries); }
    }
    var fadeInTime = pose && isNumber(pose.fadeInTime) && pose.fadeInTime >= 0 ?
      pose.fadeInTime : DEFAULT_FADE_IN_TIME;

    function opacityAt(partOpacities, index) {
      if (index >= partOpacities.length) { return 0; }
      var value = partOpacities[index];
      return isNumber(value) ? value : 0;
    }

    function reset(values, partOpacities) {
      for (var gi = 0; gi < groups.length; gi++) {
        var group = groups[gi];
        for (var ei = 0; ei < group.length; ei++) {
          var entry = group[ei];
          var target = ei === 0 ? 1 : 0;
          if (entry.paramIndex >= 0) {
            if (entry.paramIndex < values.length) {
              values[entry.paramIndex] = target;
            }
          } else {
            extraParams[entry.id] = target;
          }
          if (entry.partIndex < partOpacities.length) {
            partOpacities[entry.partIndex] = target;
          }
          for (var li = 0; li < entry.linkIndices.length; li++) {
            var linkIndex = entry.linkIndices[li];
            if (linkIndex < partOpacities.length) {
              partOpacities[linkIndex] = target;
            }
          }
        }
      }
    }

    function evaluate(values, partOpacities, dtS) {
      var deltaTime = isNumber(dtS) && dtS > 0 ? dtS : 0;
      for (var gi = 0; gi < groups.length; gi++) {
        var group = groups[gi];
        var visible = -1;
        var newOpacity = 1;
        for (var ei = 0; ei < group.length; ei++) {
          var entry = group[ei];
          var value = entry.paramIndex >= 0 ?
            values[entry.paramIndex] : extraParams[entry.id];
          if (!(value > VISIBLE_THRESHOLD)) { continue; }
          if (visible >= 0) { break; }
          visible = ei;
          if (fadeInTime === 0) {
            newOpacity = 1;
            continue;
          }
          newOpacity = Math.min(1, opacityAt(partOpacities, entry.partIndex) +
            deltaTime / fadeInTime);
        }
        if (visible < 0) { visible = 0; }
        for (var oi = 0; oi < group.length; oi++) {
          var other = group[oi];
          if (oi === visible) {
            if (other.partIndex < partOpacities.length) {
              partOpacities[other.partIndex] = newOpacity;
            }
            continue;
          }
          var target = newOpacity < PHI ?
            newOpacity * (PHI - 1) / PHI + 1 :
            (1 - newOpacity) * PHI / (1 - PHI);
          var backOpacity = (1 - target) * (1 - newOpacity);
          if (backOpacity > BACK_OPACITY_THRESHOLD) {
            target = 1 - BACK_OPACITY_THRESHOLD / (1 - newOpacity);
          }
          if (other.partIndex < partOpacities.length &&
              partOpacities[other.partIndex] > target) {
            partOpacities[other.partIndex] = target;
          }
        }
        for (var ci = 0; ci < group.length; ci++) {
          var source = group[ci];
          var opacity = opacityAt(partOpacities, source.partIndex);
          for (var li = 0; li < source.linkIndices.length; li++) {
            var linkIndex = source.linkIndices[li];
            if (linkIndex < partOpacities.length) {
              partOpacities[linkIndex] = opacity;
            }
          }
        }
      }
    }

    return Object.freeze({
      extraParams: extraParams,
      reset: reset,
      evaluate: evaluate
    });
  }

  var api = Object.freeze({
    parse: parse,
    create: create
  });

  if (typeof window !== 'undefined' && window) { window.Live2DPose = api; }
  if (typeof module !== 'undefined' && module && module.exports) { module.exports = api; }
}());
