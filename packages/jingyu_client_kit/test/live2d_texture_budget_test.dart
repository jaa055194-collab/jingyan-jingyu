import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:test/test.dart';

void main() {
  group('planLive2DTextures', () {
    test('keeps sizes when already within dimension and byte budget', () {
      final plan = planLive2DTextures(
        const [TextureSize(1024, 1024), TextureSize(2048, 512)],
        limits: const Live2DTextureLimits(maxDimension: 8192, maxTotalBytes: 64 * 1024 * 1024),
      );
      expect(plan.withinBudget, isTrue);
      expect(plan.textures, [
        const TextureSize(1024, 1024),
        const TextureSize(2048, 512),
      ]);
      expect(plan.totalBytes, (1024 * 1024 + 2048 * 512) * 4);
    });

    test('downscales a texture that exceeds maxDimension', () {
      final plan = planLive2DTextures(
        const [TextureSize(8192, 8192)],
        limits: const Live2DTextureLimits(maxDimension: 4096, maxTotalBytes: 1 << 30),
      );
      expect(plan.textures.single, const TextureSize(4096, 4096));
      expect(plan.withinBudget, isTrue);
    });

    test('uniformly halves until total RGBA8 bytes fit', () {
      // 8192x8192 * 4 = 256MiB; budget 32MiB forces two halvings -> 2048x2048.
      final plan = planLive2DTextures(
        const [TextureSize(8192, 8192)],
        limits: const Live2DTextureLimits(maxDimension: 16384, maxTotalBytes: 32 * 1024 * 1024),
      );
      expect(plan.textures.single, const TextureSize(2048, 2048));
      expect(plan.totalBytes, 2048 * 2048 * 4);
      expect(plan.withinBudget, isTrue);
    });

    test('reports not within budget when minimum size still exceeds it', () {
      final plan = planLive2DTextures(
        const [TextureSize(8192, 8192)],
        limits: const Live2DTextureLimits(maxDimension: 16384, maxTotalBytes: 1),
      );
      expect(plan.withinBudget, isFalse);
    });

    test('preserves aspect ratio while capping the long edge', () {
      final plan = planLive2DTextures(
        const [TextureSize(4096, 2048)],
        limits: const Live2DTextureLimits(maxDimension: 2048, maxTotalBytes: 1 << 30),
      );
      expect(plan.textures.single, const TextureSize(2048, 1024));
    });

    test('rejects non-positive dimensions', () {
      expect(
        () => planLive2DTextures(
          const [TextureSize(0, 1024)],
          limits: const Live2DTextureLimits(),
        ),
        throwsFormatException,
      );
    });

    test('snapdragon-class default budget yields mobile-safe total', () {
      final plan = planLive2DTextures(
        const [
          TextureSize(4096, 8192),
          TextureSize(4096, 8192),
          TextureSize(2048, 2048),
          TextureSize(8192, 8192),
          TextureSize(4096, 4096),
        ],
      );
      expect(plan.withinBudget, isTrue);
      expect(plan.totalBytes, lessThanOrEqualTo(const Live2DTextureLimits().maxTotalBytes));
      for (final t in plan.textures) {
        expect(t.width, lessThanOrEqualTo(const Live2DTextureLimits().maxDimension));
        expect(t.height, lessThanOrEqualTo(const Live2DTextureLimits().maxDimension));
      }
    });
  });
}
