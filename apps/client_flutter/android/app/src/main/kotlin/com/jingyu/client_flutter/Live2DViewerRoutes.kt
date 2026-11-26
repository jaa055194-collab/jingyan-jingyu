package com.jingyu.client_flutter

import java.io.File
import java.io.IOException
import java.security.SecureRandom

/**
 * Pure path and route rules for the Live2D preview WebView. Nothing here touches android.*,
 * so a plain JVM unit test can cover it.
 *
 * - Viewer: `https://appassets.androidplatform.net/live2d/viewer/<file>` serves only the files
 *   in [VIEWER_FILES] from the APK assets; any other file is [Route.Forbidden].
 * - Model: `https://appassets.androidplatform.net/live2d/model/<token>/<relative path>`. The
 *   token is 128 random bits in hex, issued by `serve` for one staged directory. An unknown
 *   token, an unsafe path, or a path that canonicalizes outside the directory (`..`, absolute
 *   paths, symlink escapes) is [Route.Forbidden]; a missing file is [Route.NotFound].
 *
 * The domain is WebViewAssetLoader's default one, see
 * https://developer.android.com/reference/androidx/webkit/WebViewAssetLoader and
 * https://developer.android.com/develop/ui/views/layout/webapps/load-local-content.
 */
internal object Live2DViewerRoutes {
    const val DOMAIN = "appassets.androidplatform.net"
    const val ORIGIN = "https://$DOMAIN"
    const val VIEWER_PREFIX = "/live2d/viewer/"
    const val MODEL_PREFIX = "/live2d/model/"
    const val VIEWER_URL = "$ORIGIN${VIEWER_PREFIX}live2d_viewer.html"

    /** Where the Gradle task puts the viewer files inside the APK assets. */
    const val ASSET_DIR = "live2d/viewer/"

    /** `serve` accepts only directories strictly inside `<cacheDir>/live2d-preview`. */
    const val PREVIEW_DIR = "live2d-preview"

    private const val JS = "text/javascript"

    /** The viewer allowlist: path below [VIEWER_PREFIX] to MIME type. */
    val VIEWER_FILES: Map<String, String> = mapOf(
        "live2d_viewer.html" to "text/html",
        "live2d_viewer.js" to JS,
        "live2d_renderer_webgl.js" to JS,
        "live2d_texture_budget.js" to JS,
        "runtime/purismcore/purismcore.js" to JS,
    )

    sealed interface Route {
        data class Asset(val assetPath: String, val mimeType: String) : Route
        data class Staged(val file: File, val mimeType: String) : Route
        object NotFound : Route
        object Forbidden : Route
    }

    /** [suffix] is the decoded path after [VIEWER_PREFIX]. */
    fun viewer(suffix: String): Route {
        val mimeType = VIEWER_FILES[suffix] ?: return Route.Forbidden
        return Route.Asset(ASSET_DIR + suffix, mimeType)
    }

    /**
     * [suffix] is the decoded path after [MODEL_PREFIX]; [tokens] maps each issued token to the
     * canonical directory it serves.
     */
    fun model(suffix: String, tokens: Map<String, File>): Route {
        val slash = suffix.indexOf('/')
        if (slash < 0) return Route.Forbidden
        val token = suffix.substring(0, slash)
        val root = if (isToken(token)) tokens[token] else null
        val relative = suffix.substring(slash + 1)
        if (root == null || !isSafeRelativePath(relative)) return Route.Forbidden
        val file = canonical(File(root, relative)) ?: return Route.Forbidden
        if (!isStrictDescendant(root, file)) return Route.Forbidden
        return if (file.isFile) Route.Staged(file, modelMimeType(file.name)) else Route.NotFound
    }

    /**
     * The canonical form of [directory] if it is an existing directory strictly inside
     * [previewRoot], else null. Both sides are canonicalized, so /data/user/0 and /data/data
     * spellings of the same cache directory compare equal.
     */
    fun stagingDirectory(previewRoot: File, directory: String): File? {
        if (directory.indexOf('\u0000') >= 0 || !File(directory).isAbsolute) return null
        val root = canonical(previewRoot) ?: return null
        val dir = canonical(File(directory)) ?: return null
        return if (isStrictDescendant(root, dir) && dir.isDirectory) dir else null
    }

    /** Relative, `/`-separated, and free of empty, `.` and `..` segments. */
    fun isSafeRelativePath(path: String): Boolean =
        path.isNotEmpty() && path.indexOf('\\') < 0 && path.indexOf('\u0000') < 0 &&
            path.split('/').none { it.isEmpty() || it == "." || it == ".." }

    fun isStrictDescendant(root: File, file: File): Boolean {
        val prefix = root.path.trimEnd(File.separatorChar) + File.separatorChar
        return file.path.length > prefix.length && file.path.startsWith(prefix)
    }

    fun isToken(value: String): Boolean =
        value.length == 32 && value.all { it in '0'..'9' || it in 'a'..'f' }

    fun newToken(random: SecureRandom): String {
        val bytes = ByteArray(16)
        random.nextBytes(bytes)
        return bytes.joinToString("") { (it.toInt() and 0xff).toString(16).padStart(2, '0') }
    }

    fun modelBaseUrl(token: String): String = "$ORIGIN$MODEL_PREFIX$token/"

    fun isViewerOrigin(origin: String): Boolean = origin == ORIGIN || origin == "$ORIGIN/"

    fun modelMimeType(name: String): String =
        when (name.substringAfterLast('.', "").lowercase()) {
            "json" -> "application/json"
            "png" -> "image/png"
            else -> "application/octet-stream"
        }

    private fun canonical(file: File): File? =
        try {
            file.canonicalFile
        } catch (e: IOException) {
            null
        }
}
