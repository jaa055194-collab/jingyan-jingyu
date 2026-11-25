package com.jingyu.jingyu_street3d_android

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * Registers the `jingyu/street3d_view` PlatformView.
 *
 * Flutter registers this class itself (pubspec `flutter.plugin.platforms.android.pluginClass`),
 * so the app needs no MainActivity, Gradle or manifest changes.
 */
class Street3DAndroidPlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        binding.platformViewRegistry.registerViewFactory(
            VIEW_TYPE,
            Street3DViewFactory(binding.binaryMessenger, binding.flutterAssets),
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // Flutter disposes the views; nothing is held per engine.
    }

    companion object {
        /** Must match the view type used by `Street3DAndroidView` on the Dart side. */
        const val VIEW_TYPE = "jingyu/street3d_view"
    }
}

/** Creates one [Street3DPlatformView] per Dart view; creation params arrive as a String-keyed map. */
internal class Street3DViewFactory(
    private val messenger: BinaryMessenger,
    private val assets: FlutterPlugin.FlutterAssets,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val params = (args as? Map<*, *>)
            ?.entries
            ?.mapNotNull { (key, value) -> (key as? String)?.let { it to value } }
            ?.toMap()
            .orEmpty()
        return Street3DPlatformView(context, viewId, params, messenger, assets)
    }
}
