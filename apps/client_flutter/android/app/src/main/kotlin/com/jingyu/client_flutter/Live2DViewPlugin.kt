package com.jingyu.client_flutter

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * Registers the `jingyu/live2d_view` platform view that Live2DPreviewView creates with
 * AndroidView, as in "Hosting native Android views":
 * https://docs.flutter.dev/platform-integration/android/platform-views
 *
 * It also owns the `jingyu/live2d_store` method channel. Its one method,
 * `getLive2DStoreDirectory`, answers the absolute path of noBackupFilesDir/live2d (created
 * when missing), the root of the on-device Live2D store. The Dart caller is
 * lib/features/world/live2d_store_directory.dart. It is not on `jingyu/platform` in
 * MainActivity.kt because other tickets share that file.
 */
class Live2DViewPlugin : FlutterPlugin {
    private var storeChannel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        binding.platformViewRegistry.registerViewFactory(VIEW_TYPE, Factory(binding.binaryMessenger))
        val context = binding.applicationContext
        storeChannel = MethodChannel(binding.binaryMessenger, STORE_CHANNEL).also {
            it.setMethodCallHandler { call, result -> onStoreCall(context, call, result) }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        storeChannel?.setMethodCallHandler(null)
        storeChannel = null
    }

    private fun onStoreCall(context: Context, call: MethodCall, result: MethodChannel.Result) {
        if (call.method != STORE_DIRECTORY_METHOD) {
            result.notImplemented()
            return
        }
        val root = Live2DViewerRoutes.storeDirectory(context.noBackupFilesDir)
        if (root == null) {
            result.error("store_unavailable", "noBackupFilesDir/live2d could not be created", null)
        } else {
            result.success(root.path)
        }
    }

    private class Factory(private val messenger: BinaryMessenger) :
        PlatformViewFactory(StandardMessageCodec.INSTANCE) {
        override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
            Live2DPlatformView(context, viewId, messenger)
    }

    companion object {
        const val VIEW_TYPE = "jingyu/live2d_view"
        const val STORE_CHANNEL = "jingyu/live2d_store"
        const val STORE_DIRECTORY_METHOD = "getLive2DStoreDirectory"
    }
}
