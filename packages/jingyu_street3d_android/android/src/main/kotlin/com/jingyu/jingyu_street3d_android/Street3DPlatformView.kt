package com.jingyu.jingyu_street3d_android

import android.content.Context
import android.view.View
import android.webkit.WebView
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.platform.PlatformView

/**
 * One street scene: a WebView hosted as a Flutter PlatformView.
 *
 * Skeleton: an empty WebView. The asset loader, the page bridge, the navigation lock and the
 * per-view channel are built on the arguments kept here.
 */
@Suppress("unused")
internal class Street3DPlatformView(
    context: Context,
    private val viewId: Int,
    private val params: Map<String, Any?>,
    private val messenger: BinaryMessenger,
    private val assets: FlutterPlugin.FlutterAssets,
) : PlatformView {
    private val webView = WebView(context)

    override fun getView(): View = webView

    override fun dispose() {
        webView.destroy()
    }
}
