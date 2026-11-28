package com.jingyu.client_flutter

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.ApplicationInfo
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import androidx.webkit.JavaScriptReplyProxy
import androidx.webkit.WebMessageCompat
import androidx.webkit.WebViewAssetLoader
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.io.InputStream
import java.security.SecureRandom
import java.util.concurrent.ConcurrentHashMap

/**
 * The native side of the `jingyu/live2d_view` platform view: a WebView that shows the Live2D
 * viewer page and talks to the Dart `AndroidLive2DRendererHost` over the method channel
 * `jingyu/live2d_view/<viewId>`.
 *
 * Follows the platform documentation (patterns adapted, no code copied):
 * - Hosting native views: https://docs.flutter.dev/platform-integration/android/platform-views
 * - Local content over https with WebViewAssetLoader and custom PathHandlers:
 *   https://developer.android.com/develop/ui/views/layout/webapps/load-local-content
 * - The page bridge: WebViewCompat.addWebMessageListener in
 *   https://developer.android.com/reference/androidx/webkit/WebViewCompat
 * - Renderer loss: "Handle render process termination" in
 *   https://developer.android.com/develop/ui/views/layout/webapps/managing-webview
 *
 * Channel protocol (fixed; the Dart host and its test fake implement the other side):
 * - Dart to native: `serve {directory}` returns the model base URL, ending in `/`, for a
 *   preview staging directory or a stored model directory (see `serve`), or fails with
 *   `bad_directory`. `post {message}` hands a string to the page and fails with
 *   `bad_message`, `gone` or `not_ready`, checked in that order.
 * - Native to Dart: `message` (the page's string, unparsed, `boot` included), `pageError`
 *   (a string) and `renderProcessGone {didCrash}`. These wait for Dart's first call, so none
 *   reaches the channel before the Dart host has set its handler.
 */
internal class Live2DPlatformView(
    context: Context,
    viewId: Int,
    messenger: BinaryMessenger,
) : PlatformView {
    private val appContext: Context = context.applicationContext
    private val channel = MethodChannel(messenger, "${Live2DViewPlugin.VIEW_TYPE}/$viewId")
    private val container = FrameLayout(context)
    private val handler = Handler(Looper.getMainLooper())

    /** Issued tokens and the canonical directories they serve; read on WebView IO threads. */
    private val tokens = ConcurrentHashMap<String, File>()

    /** Calls to Dart made before Dart's first call; see [scheduleFlush]. */
    private val pending = ArrayList<Pair<String, Any?>>()
    private var dartReady = false
    private var flushScheduled = false

    private var webView: WebView? = null
    private var listening = false
    private var pageStarted = false
    private var replyProxy: JavaScriptReplyProxy? = null
    private var gone = false
    private var disposed = false

    // Custom PathHandlers instead of AssetsPathHandler, which would expose every APK asset,
    // flutter_assets included. The handlers answer 403 and 404 themselves, and any request
    // they do not match gets 403 in shouldInterceptRequest, so nothing reaches the network.
    private val assetLoader = WebViewAssetLoader.Builder()
        .setDomain(Live2DViewerRoutes.DOMAIN)
        .addPathHandler(Live2DViewerRoutes.VIEWER_PREFIX) { path ->
            respond(Live2DViewerRoutes.viewer(path))
        }
        .addPathHandler(Live2DViewerRoutes.MODEL_PREFIX) { path ->
            respond(Live2DViewerRoutes.model(path, tokens))
        }
        .build()

    private val client = object : WebViewClient() {
        override fun shouldInterceptRequest(
            view: WebView,
            request: WebResourceRequest,
        ): WebResourceResponse = assetLoader.shouldInterceptRequest(request.url) ?: forbidden()

        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
            true

        override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
            // A reload: posts wait for the new document's first message. The first document
            // needs no reset, and skipping it keeps an early boot message from being lost.
            if (pageStarted) replyProxy = null
            pageStarted = true
        }

        override fun onReceivedError(
            view: WebView,
            request: WebResourceRequest,
            error: WebResourceError,
        ) {
            if (request.isForMainFrame) {
                invoke("pageError", "load_error:${error.errorCode}:${error.description}")
            }
        }

        override fun onReceivedHttpError(
            view: WebView,
            request: WebResourceRequest,
            errorResponse: WebResourceResponse,
        ) {
            if (request.isForMainFrame) invoke("pageError", "http_error:${errorResponse.statusCode}")
        }

        override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
            // The WebView cannot be used again; only a new platform view can recover.
            if (!gone) {
                gone = true
                destroyWebView()
                invoke("renderProcessGone", mapOf("didCrash" to detail.didCrash()))
            }
            return true
        }
    }

    init {
        channel.setMethodCallHandler { call, result -> onMethodCall(call, result) }
        container.setBackgroundColor(Color.TRANSPARENT)
        start(context)
    }

    override fun getView(): View = container

    override fun dispose() {
        if (disposed) return
        disposed = true
        channel.setMethodCallHandler(null)
        handler.removeCallbacksAndMessages(null)
        pending.clear()
        tokens.clear()
        destroyWebView()
        // The staged model files stay: Dart owns and deletes them.
    }

    private fun start(context: Context) {
        val view = try {
            WebView(context)
        } catch (e: Exception) {
            // The WebView provider can be missing, disabled or in the middle of an update.
            fail("webview_unavailable")
            return
        }
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
            view.destroy()
            fail("web_message_listener_unsupported")
            return
        }
        configure(view)
        WebViewCompat.addWebMessageListener(
            view,
            BRIDGE,
            setOf(Live2DViewerRoutes.ORIGIN),
        ) { _, message, sourceOrigin, isMainFrame, proxy ->
            onPageMessage(message, sourceOrigin.toString(), isMainFrame, proxy)
        }
        listening = true
        webView = view
        container.addView(
            view,
            ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT),
        )
        view.loadUrl(Live2DViewerRoutes.VIEWER_URL)
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun configure(view: WebView) {
        view.settings.run {
            javaScriptEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            setGeolocationEnabled(false)
            setSupportMultipleWindows(false)
            javaScriptCanOpenWindowsAutomatically = false
        }
        view.setBackgroundColor(Color.TRANSPARENT)
        view.isVerticalScrollBarEnabled = false
        view.isHorizontalScrollBarEnabled = false
        view.webViewClient = client
        if ((appContext.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
            WebView.setWebContentsDebuggingEnabled(true)
        }
    }

    private fun onPageMessage(
        message: WebMessageCompat,
        origin: String,
        isMainFrame: Boolean,
        proxy: JavaScriptReplyProxy,
    ) {
        // The origin rule already limits the bridge to the viewer origin; check again anyway.
        if (disposed || gone || !isMainFrame || !Live2DViewerRoutes.isViewerOrigin(origin)) return
        replyProxy = proxy
        // Dart reports anything but a JSON object string as bad_message.
        invoke("message", if (message.type == WebMessageCompat.TYPE_STRING) message.data else null)
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *>
        when (call.method) {
            "serve" -> serve(arguments?.get("directory"), result)
            "post" -> post(arguments?.get("message"), result)
            else -> result.notImplemented()
        }
        scheduleFlush()
    }

    /**
     * Issues a token for exactly the directories [Live2DViewerRoutes.servedDirectory] accepts:
     * a preview staging directory or a stored model directory. The store root is not created
     * here; while it is missing there is no stored model to serve.
     */
    private fun serve(directory: Any?, result: MethodChannel.Result) {
        val previewRoot = File(appContext.cacheDir, Live2DViewerRoutes.PREVIEW_DIR)
        val storeRoot = appContext.noBackupFilesDir?.let { File(it, Live2DViewerRoutes.STORE_DIR) }
        val root = (directory as? String)?.let {
            Live2DViewerRoutes.servedDirectory(previewRoot, storeRoot, it)
        }
        if (root == null) {
            result.error(
                "bad_directory",
                "the directory is not inside the Live2D preview cache or the Live2D model store",
                null,
            )
            return
        }
        val token = Live2DViewerRoutes.newToken(random)
        tokens[token] = root
        result.success(Live2DViewerRoutes.modelBaseUrl(token))
    }

    private fun post(message: Any?, result: MethodChannel.Result) {
        if (message !is String) {
            result.error("bad_message", "message must be a string", null)
            return
        }
        if (gone || disposed) {
            result.error("gone", "the Live2D renderer is gone", null)
            return
        }
        val proxy = replyProxy
        if (proxy == null) {
            result.error("not_ready", "the viewer page has not sent a message yet", null)
            return
        }
        try {
            proxy.postMessage(message)
        } catch (e: RuntimeException) {
            result.error("post_failed", e.message, null)
            return
        }
        result.success(null)
    }

    private fun invoke(method: String, arguments: Any?) {
        if (disposed) return
        if (dartReady) channel.invokeMethod(method, arguments) else pending.add(method to arguments)
    }

    /**
     * After Dart's first call, sends the held calls in order. Posting runs them after the reply
     * to that call and outside its handler, which also suits merged UI and platform threads.
     */
    private fun scheduleFlush() {
        if (dartReady || flushScheduled) return
        flushScheduled = true
        handler.post {
            if (disposed) return@post
            dartReady = true
            val held = pending.toList()
            pending.clear()
            for ((method, arguments) in held) channel.invokeMethod(method, arguments)
        }
    }

    private fun fail(code: String) {
        gone = true
        invoke("pageError", code)
    }

    private fun destroyWebView() {
        val view = webView ?: return
        webView = null
        replyProxy = null
        if (listening) {
            listening = false
            // After a renderer loss the WebView only needs destroying.
            if (!gone) {
                try {
                    WebViewCompat.removeWebMessageListener(view, BRIDGE)
                } catch (e: RuntimeException) {
                    // The WebView is destroyed next anyway.
                }
            }
        }
        container.removeView(view)
        // A WebView whose renderer is gone takes no calls except destroy().
        if (!gone) view.stopLoading()
        view.destroy()
    }

    /** Runs on a WebView IO thread. */
    private fun respond(route: Live2DViewerRoutes.Route): WebResourceResponse =
        when (route) {
            is Live2DViewerRoutes.Route.Asset ->
                ok(route.mimeType) { appContext.assets.open(route.assetPath) }
            is Live2DViewerRoutes.Route.Staged -> ok(route.mimeType) { FileInputStream(route.file) }
            Live2DViewerRoutes.Route.NotFound -> status(404, "Not Found")
            Live2DViewerRoutes.Route.Forbidden -> forbidden()
        }

    private fun ok(mimeType: String, open: () -> InputStream): WebResourceResponse {
        val data = try {
            open()
        } catch (e: IOException) {
            return status(404, "Not Found")
        }
        val text = mimeType.startsWith("text/") || mimeType == "application/json"
        return WebResourceResponse(mimeType, if (text) "utf-8" else null, 200, "OK", emptyMap(), data)
    }

    private companion object {
        const val BRIDGE = "Live2DBridge"
        val random = SecureRandom()

        fun status(code: Int, reason: String) = WebResourceResponse(
            "text/plain",
            "utf-8",
            code,
            reason,
            emptyMap(),
            ByteArrayInputStream(ByteArray(0)),
        )

        fun forbidden() = status(403, "Forbidden")
    }
}
