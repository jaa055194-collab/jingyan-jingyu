package com.jingyu.client_flutter

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * Registers the `jingyu/live2d_view` platform view that Live2DPreviewView creates with
 * AndroidView, as in "Hosting native Android views":
 * https://docs.flutter.dev/platform-integration/android/platform-views
 */
class Live2DViewPlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        binding.platformViewRegistry.registerViewFactory(VIEW_TYPE, Factory(binding.binaryMessenger))
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) = Unit

    private class Factory(private val messenger: BinaryMessenger) :
        PlatformViewFactory(StandardMessageCodec.INSTANCE) {
        override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
            Live2DPlatformView(context, viewId, messenger)
    }

    companion object {
        const val VIEW_TYPE = "jingyu/live2d_view"
    }
}
