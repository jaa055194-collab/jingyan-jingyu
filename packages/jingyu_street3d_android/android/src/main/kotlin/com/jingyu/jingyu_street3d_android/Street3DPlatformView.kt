package com.jingyu.jingyu_street3d_android

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.webkit.ConsoleMessage
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebChromeClient
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
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import java.io.ByteArrayInputStream

/**
 * One street scene: a WebView hosted as a Flutter PlatformView, as section 1 of PROTOCOL.md in
 * jingyu_street3d_web describes.
 *
 * - WebViewAssetLoader serves the page from the APK at https://appassets.androidplatform.net,
 *   limited to the folder that holds the entry page. Nothing else loads: the asset origin answers
 *   404 outside that folder, every other URL but data: and blob: gets an empty 403, and
 *   navigation away is blocked.
 * - The page talks through the object WebViewCompat.addWebMessageListener injects
 *   (`Street3DBridge` by default), on that origin only. The page posts first; the view answers
 *   through the reply proxy of the page's latest message, and holds what Dart sends until then.
 * - Dart drives the view over the channel `jingyu/street3d_view_<id>` (start, send, pause,
 *   resume); the view calls back `message` and `failure`.
 */
internal class Street3DPlatformView(
    private val context: Context,
    viewId: Int,
    params: Map<String, Any?>,
    messenger: BinaryMessenger,
    private val assets: FlutterPlugin.FlutterAssets,
) : PlatformView, MethodChannel.MethodCallHandler {
    private val entry = params["entry"] as? String ?: DEFAULT_ENTRY
    private val assetPackage = params["assetPackage"] as? String ?: DEFAULT_ASSET_PACKAGE
    private val bridgeName = params["bridgeName"] as? String ?: DEFAULT_BRIDGE_NAME
    private val channel = MethodChannel(messenger, CHANNEL_PREFIX + viewId)

    // The WebView sits in a container so that it can be dropped after its renderer is gone.
    private val container = FrameLayout(context)
    private var webView: WebView?
    private var started = false
    private var replyProxy: JavaScriptReplyProxy? = null
    private val pending = java.util.ArrayDeque<String>()

    init {
        val view = WebView(context)
        container.addView(
            view,
            ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT),
        )
        webView = view
        channel.setMethodCallHandler(this)
    }

    override fun getView(): View = container

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> start(result)
            "send" -> {
                val json = call.arguments as? String
                if (json == null) {
                    result.error("bad_args", "send takes one String.", null)
                } else {
                    send(json)
                    result.success(null)
                }
            }
            "pause" -> {
                webView?.onPause()
                result.success(null)
            }
            "resume" -> {
                webView?.onResume()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun dispose() {
        channel.setMethodCallHandler(null)
        dropWebView()
    }

    private fun start(result: MethodChannel.Result) {
        val view = webView
        if (view == null) {
            result.error("crashed", "The page's renderer is gone.", null)
            return
        }
        if (started) {
            result.success(null)
            return
        }
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
            val version = WebViewCompat.getCurrentWebViewPackage(context)?.versionName ?: "unknown"
            result.error("unsupported", "WebView $version has no WebMessageListener.", null)
            return
        }
        val page = resolvePage()
        if (page == null) {
            result.error(
                "bad_args",
                "Bad entry \"$entry\", asset package \"$assetPackage\" or bridge name \"$bridgeName\".",
                null,
            )
            return
        }
        started = true
        configure(view, page)
        view.loadUrl(page.url)
        result.success(null)
    }

    /** The entry page's URL and its folder, as a URL path and as an APK asset path. */
    private class Page(val url: String, val urlFolder: String, val assetFolder: String)

    private fun resolvePage(): Page? {
        // The entry must sit in a folder: that folder, never the asset root, is what gets served.
        if (!isPlainRelative(entry) || '/' !in entry || !BRIDGE_NAME.matches(bridgeName)) return null
        if (assetPackage.isNotEmpty() && !PACKAGE_NAME.matches(assetPackage)) return null
        val assetPath = if (assetPackage.isEmpty()) {
            assets.getAssetFilePathByName(entry)
        } else {
            assets.getAssetFilePathByName(entry, assetPackage)
        }
        // Never expose the APK's whole asset root.
        val slash = assetPath.lastIndexOf('/')
        if (slash <= 0) return null
        val assetFolder = assetPath.substring(0, slash + 1)
        return Page("$ORIGIN/assets/$assetPath", "/assets/$assetFolder", assetFolder)
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun configure(view: WebView, page: Page) {
        with(view.settings) {
            javaScriptEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            setSupportZoom(false)
            setSupportMultipleWindows(false)
            javaScriptCanOpenWindowsAutomatically = false
            mediaPlaybackRequiresUserGesture = true
        }
        // The Flutter page behind shows through until the scene draws its first frame.
        view.setBackgroundColor(Color.TRANSPARENT)
        view.webViewClient = PageClient(page, assetLoader(page))
        view.webChromeClient = ConsoleLog
        WebViewCompat.addWebMessageListener(view, bridgeName, setOf(ORIGIN)) { _, message, _, isMainFrame, proxy ->
            onPageMessage(message, isMainFrame, proxy)
        }
    }

    private fun assetLoader(page: Page): WebViewAssetLoader {
        val apkAssets = WebViewAssetLoader.AssetsPathHandler(context)
        return WebViewAssetLoader.Builder()
            .setDomain(DOMAIN)
            .addPathHandler(page.urlFolder) { path ->
                if (isPlainRelative(path)) apkAssets.handle(page.assetFolder + path) else null
            }
            .build()
    }

    // Each document posts through its own reply proxy, and a reloaded page posts hello before
    // anything else, so the proxy of the latest message reaches the live page. A proxy whose
    // document is gone drops what it is given. What Dart sent before the first message is held.
    private fun onPageMessage(message: WebMessageCompat, isMainFrame: Boolean, proxy: JavaScriptReplyProxy) {
        if (!isMainFrame || message.type != WebMessageCompat.TYPE_STRING) return
        val data = message.data ?: return
        val first = replyProxy == null
        replyProxy = proxy
        channel.invokeMethod("message", data)
        if (first) {
            while (true) {
                val held = pending.pollFirst() ?: break
                proxy.postMessage(held)
            }
        }
    }

    private fun send(json: String) {
        val proxy = replyProxy
        if (proxy != null) {
            proxy.postMessage(json)
        } else if (webView != null) {
            if (pending.size >= MAX_PENDING) pending.pollFirst()
            pending.addLast(json)
        }
    }

    private fun fail(kind: String, detail: String) {
        channel.invokeMethod("failure", mapOf("kind" to kind, "detail" to detail))
    }

    private fun dropWebView() {
        val view = webView ?: return
        webView = null
        replyProxy = null
        pending.clear()
        container.removeView(view)
        view.destroy()
    }

    private inner class PageClient(
        private val page: Page,
        private val loader: WebViewAssetLoader,
    ) : WebViewClient() {
        // Runs on a WebView worker thread; it reads only immutable state.
        override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
            val url = request.url
            // data: and blob: URLs are the page's own in-memory content; nothing is fetched.
            if (url.scheme == "data" || url.scheme == "blob") return null
            return loader.shouldInterceptRequest(url)
                ?: if (url.scheme == "https" && url.host == DOMAIN) empty(404, "Not Found") else empty(403, "Forbidden")
        }

        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            val url = request.url
            val inFolder = url.scheme == "https" && url.host == DOMAIN &&
                url.path.orEmpty().startsWith(page.urlFolder)
            return !inFolder
        }

        override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
            if (request.isForMainFrame) fail("loadFailed", "${error.errorCode} ${error.description}")
        }

        override fun onReceivedHttpError(
            view: WebView,
            request: WebResourceRequest,
            errorResponse: WebResourceResponse,
        ) {
            if (request.isForMainFrame) fail("loadFailed", "HTTP ${errorResponse.statusCode}")
        }

        // Returning true keeps the app alive; this WebView is unusable afterwards and is dropped.
        override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
            if (view === webView) {
                dropWebView()
                fail(
                    "crashed",
                    if (detail.didCrash()) "The renderer crashed." else "The system stopped the renderer to free memory.",
                )
            }
            return true
        }
    }

    /** Page warnings and errors go to logcat; nothing else is logged. */
    private object ConsoleLog : WebChromeClient() {
        override fun onConsoleMessage(message: ConsoleMessage): Boolean {
            val level = message.messageLevel()
            if (level == ConsoleMessage.MessageLevel.ERROR || level == ConsoleMessage.MessageLevel.WARNING) {
                Log.w(TAG, "${message.sourceId()}:${message.lineNumber()} ${message.message()}")
            }
            return true
        }
    }

    companion object {
        private const val TAG = "Street3D"
        private const val CHANNEL_PREFIX = "jingyu/street3d_view_"
        private const val DOMAIN = "appassets.androidplatform.net"
        private const val ORIGIN = "https://$DOMAIN"
        private const val DEFAULT_ENTRY = "web/index.html"
        private const val DEFAULT_ASSET_PACKAGE = "jingyu_street3d_web"
        private const val DEFAULT_BRIDGE_NAME = "Street3DBridge"

        /** Messages held for a page that has not posted yet: as many as the page itself queues. */
        private const val MAX_PENDING = 64
        private val BRIDGE_NAME = Regex("[A-Za-z_\$][A-Za-z0-9_\$]*")
        private val PACKAGE_NAME = Regex("[a-z][a-z0-9_]*")

        /** A relative path of plain segments: no leading slash, no empty, `.` or `..` segment. */
        private fun isPlainRelative(path: String): Boolean =
            path.isNotEmpty() && '\\' !in path &&
                path.split('/').none { it.isEmpty() || it == "." || it == ".." }

        private fun empty(status: Int, reason: String) = WebResourceResponse(
            "text/plain",
            "utf-8",
            status,
            reason,
            emptyMap(),
            ByteArrayInputStream(ByteArray(0)),
        )
    }
}
