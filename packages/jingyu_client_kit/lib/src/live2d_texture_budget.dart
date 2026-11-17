/// Mobile texture budget planning for device-local Live2D models.
///
/// Pure Dart, no GPU calls: callers pass the decoded texture dimensions and a
/// device-class budget; the planner returns dimensions that fit. It is a
/// conservative planning aid, not a measured GPU capability — always confirm
/// `GL_MAX_TEXTURE_SIZE` and real memory/fps on the target device.
library;

class TextureSize {
  const TextureSize(this.width, this.height);

  final int width;
  final int height;

  @override
  bool operator ==(Object other) =>
      other is TextureSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'TextureSize(${width}x$height)';
}

/// Budget for one device class.
///
/// Defaults are a conservative Snapdragon-888-class starting point: cap each
/// edge at 8192 and keep decoded RGBA8 base textures within 256 MiB, before
/// mipmaps/masks/FBO/WASM. Confirm on the real device.
class Live2DTextureLimits {
  const Live2DTextureLimits({
    this.maxDimension = 8192,
    this.maxTotalBytes = 256 * 1024 * 1024,
  });

  final int maxDimension;
  final int maxTotalBytes;
}

class Live2DTexturePlan {
  const Live2DTexturePlan(this.textures, this.totalBytes, this.withinBudget);

  final List<TextureSize> textures;
  final int totalBytes;
  final bool withinBudget;
}

int _rgba8(TextureSize t) => t.width * t.height * 4;

/// Caps each texture's long edge at [Live2DTextureLimits.maxDimension], then
/// uniformly halves all textures until the RGBA8 total fits
/// [Live2DTextureLimits.maxTotalBytes] (or reaches 1x1).
Live2DTexturePlan planLive2DTextures(
  List<TextureSize> textures, {
  Live2DTextureLimits limits = const Live2DTextureLimits(),
}) {
  if (limits.maxDimension < 1 || limits.maxTotalBytes < 1) {
    throw const FormatException('invalid texture limits');
  }
  for (final t in textures) {
    if (t.width < 1 || t.height < 1) {
      throw const FormatException('texture dimensions must be positive');
    }
  }

  var current = <TextureSize>[];
  for (final t in textures) {
    final longEdge = t.width > t.height ? t.width : t.height;
    if (longEdge <= limits.maxDimension) {
      current.add(t);
    } else {
      final scaledW = (t.width * limits.maxDimension / longEdge).floor();
      final scaledH = (t.height * limits.maxDimension / longEdge).floor();
      current.add(TextureSize(scaledW < 1 ? 1 : scaledW, scaledH < 1 ? 1 : scaledH));
    }
  }

  var total = current.fold<int>(0, (sum, t) => sum + _rgba8(t));
  while (total > limits.maxTotalBytes) {
    var changed = false;
    final halved = <TextureSize>[];
    for (final t in current) {
      final w = t.width > 1 ? (t.width / 2).floor() : 1;
      final h = t.height > 1 ? (t.height / 2).floor() : 1;
      if (w != t.width || h != t.height) changed = true;
      halved.add(TextureSize(w, h));
    }
    if (!changed) break;
    current = halved;
    total = current.fold<int>(0, (sum, t) => sum + _rgba8(t));
  }

  return Live2DTexturePlan(
    List<TextureSize>.unmodifiable(current),
    total,
    total <= limits.maxTotalBytes,
  );
}
