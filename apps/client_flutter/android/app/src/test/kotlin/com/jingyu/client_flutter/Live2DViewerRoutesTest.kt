package com.jingyu.client_flutter

import com.jingyu.client_flutter.Live2DViewerRoutes.Route
import java.io.File
import java.nio.file.Files
import java.security.SecureRandom
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** JVM tests for the routes and path rules behind the Live2D preview WebView. */
class Live2DViewerRoutesTest {
    @get:Rule
    val temp = TemporaryFolder()

    private lateinit var previewRoot: File
    private lateinit var staged: File
    private lateinit var tokens: Map<String, File>

    @Before
    fun setUp() {
        previewRoot = temp.newFolder(Live2DViewerRoutes.PREVIEW_DIR)
        staged = File(previewRoot, "import-1").apply { mkdirs() }
        File(staged, "model.model3.json").writeText("{}")
        File(staged, "textures").mkdirs()
        File(staged, "textures/texture_00.png").writeBytes(byteArrayOf(1))
        File(staged, "model.moc3").writeBytes(byteArrayOf(2))
        File(temp.root, "secret.txt").writeText("outside")
        tokens = mapOf(TOKEN to staged.canonicalFile)
    }

    private fun model(suffix: String) = Live2DViewerRoutes.model(suffix, tokens)

    private fun staged(path: String, mimeType: String) =
        Route.Staged(File(staged, path).canonicalFile, mimeType)

    @Test
    fun viewerServesOnlyTheAllowlist() {
        for ((name, mimeType) in Live2DViewerRoutes.VIEWER_FILES) {
            assertEquals(Route.Asset("live2d/viewer/$name", mimeType), Live2DViewerRoutes.viewer(name))
        }
        for (path in listOf(
            "",
            "index.html",
            "LIVE2D_VIEWER.HTML",
            "./live2d_viewer.html",
            "live2d_viewer.html/",
            "../flutter_assets/AssetManifest.json",
            "flutter_assets/AssetManifest.json",
            "runtime/purismcore/",
            "runtime/purismcore/LICENSE",
        )) {
            assertEquals(path, Route.Forbidden, Live2DViewerRoutes.viewer(path))
        }
    }

    @Test
    fun modelServesStagedFilesWithTheirMimeTypes() {
        assertEquals(staged("model.model3.json", "application/json"), model("$TOKEN/model.model3.json"))
        assertEquals(staged("textures/texture_00.png", "image/png"), model("$TOKEN/textures/texture_00.png"))
        assertEquals(staged("model.moc3", "application/octet-stream"), model("$TOKEN/model.moc3"))
    }

    @Test
    fun modelReportsMissingFilesAndDirectoriesAsNotFound() {
        assertEquals(Route.NotFound, model("$TOKEN/missing.json"))
        assertEquals(Route.NotFound, model("$TOKEN/textures"))
    }

    @Test
    fun modelRejectsUnknownTokensAndUnsafePaths() {
        val notIssued = "0123456789abcdef0123456789abcdef"
        for (suffix in listOf(
            "$notIssued/model.model3.json",
            "${TOKEN.uppercase()}/model.model3.json",
            "${TOKEN.dropLast(1)}/model.model3.json",
            "/$TOKEN/model.model3.json",
            TOKEN,
            "$TOKEN/",
            "$TOKEN/../secret.txt",
            "$TOKEN/textures/../../secret.txt",
            "$TOKEN/./model.model3.json",
            "$TOKEN//model.model3.json",
            "$TOKEN/textures//texture_00.png",
            "$TOKEN/..\\secret.txt",
            "$TOKEN/model.model3.json\u0000.png",
        )) {
            assertEquals(suffix, Route.Forbidden, model(suffix))
        }
    }

    @Test
    fun modelRejectsSymlinksThatLeaveTheStagedDirectory() {
        val link = File(staged, "escape.json")
        val target = File(temp.root, "secret.txt")
        val created = try {
            Files.createSymbolicLink(link.toPath(), target.toPath())
            true
        } catch (e: Exception) {
            false // For example Windows without the symbolic link privilege.
        }
        assumeTrue("symbolic links are not available here", created)
        // Android (Linux) resolves links in canonicalFile; a Windows JVM may not.
        assumeTrue("canonicalFile does not resolve links here", link.canonicalFile == target.canonicalFile)
        assertEquals(Route.Forbidden, model("$TOKEN/escape.json"))
    }

    @Test
    fun stagingDirectoryAcceptsOnlyDirectoriesStrictlyInsideThePreviewRoot() {
        val canonical = staged.canonicalFile
        assertEquals(canonical, Live2DViewerRoutes.stagingDirectory(previewRoot, staged.path))
        assertEquals(
            canonical,
            Live2DViewerRoutes.stagingDirectory(previewRoot, File(previewRoot, "import-1/../import-1").path),
        )
        val sibling = File(temp.root, "${Live2DViewerRoutes.PREVIEW_DIR}-other").apply { mkdirs() }
        for (directory in listOf(
            previewRoot.path,
            temp.root.path,
            sibling.path,
            File(staged, "model.moc3").path,
            File(previewRoot, "missing").path,
            File(previewRoot, "../secret").path,
            "import-1",
            "",
            staged.path + "\u0000",
        )) {
            assertNull(directory, Live2DViewerRoutes.stagingDirectory(previewRoot, directory))
        }
    }

    @Test
    fun tokensAre128RandomBitsInLowercaseHex() {
        val random = SecureRandom()
        val first = Live2DViewerRoutes.newToken(random)
        val second = Live2DViewerRoutes.newToken(random)
        assertTrue(first, Live2DViewerRoutes.isToken(first))
        assertTrue(second, Live2DViewerRoutes.isToken(second))
        assertNotEquals(first, second)
        assertTrue(Live2DViewerRoutes.isToken(TOKEN))
        assertFalse(Live2DViewerRoutes.isToken(TOKEN.uppercase()))
        assertFalse(Live2DViewerRoutes.isToken(TOKEN + "0"))
        assertFalse(Live2DViewerRoutes.isToken("g" + TOKEN.drop(1)))
        assertEquals(
            "https://appassets.androidplatform.net/live2d/model/$first/",
            Live2DViewerRoutes.modelBaseUrl(first),
        )
    }

    @Test
    fun viewerOriginUrlAndModelMimeTypes() {
        assertEquals(
            "https://appassets.androidplatform.net/live2d/viewer/live2d_viewer.html",
            Live2DViewerRoutes.VIEWER_URL,
        )
        assertTrue(Live2DViewerRoutes.isViewerOrigin("https://appassets.androidplatform.net"))
        assertTrue(Live2DViewerRoutes.isViewerOrigin("https://appassets.androidplatform.net/"))
        assertFalse(Live2DViewerRoutes.isViewerOrigin("http://appassets.androidplatform.net"))
        assertFalse(Live2DViewerRoutes.isViewerOrigin("https://appassets.androidplatform.net.example"))
        assertFalse(Live2DViewerRoutes.isViewerOrigin("null"))
        assertEquals("application/json", Live2DViewerRoutes.modelMimeType("a.MODEL3.JSON"))
        assertEquals("image/png", Live2DViewerRoutes.modelMimeType("texture_00.PNG"))
        assertEquals("application/octet-stream", Live2DViewerRoutes.modelMimeType("model.moc3"))
        assertEquals("application/octet-stream", Live2DViewerRoutes.modelMimeType("README"))
    }

    private companion object {
        const val TOKEN = "00112233445566778899aabbccddeeff"
    }
}
