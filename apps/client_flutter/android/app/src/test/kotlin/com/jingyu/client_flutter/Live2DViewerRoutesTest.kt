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
    fun modelServesExpressionMotionPhysicsAndPoseFiles() {
        File(staged, "expression-0.exp3.json").writeText("{}")
        File(staged, "motion-0.motion3.json").writeText("{}")
        File(staged, "physics.physics3.json").writeText("{}")
        File(staged, "pose.pose3.json").writeText("{}")
        assertEquals(staged("expression-0.exp3.json", "application/json"), model("$TOKEN/expression-0.exp3.json"))
        assertEquals(staged("motion-0.motion3.json", "application/json"), model("$TOKEN/motion-0.motion3.json"))
        assertEquals(staged("physics.physics3.json", "application/json"), model("$TOKEN/physics.physics3.json"))
        assertEquals(staged("pose.pose3.json", "application/json"), model("$TOKEN/pose.pose3.json"))
    }

    @Test
    fun modelReportsMissingModelFilesAndDirectoriesAsNotFound() {
        File(staged, "folder.png").mkdirs()
        assertEquals(Route.NotFound, model("$TOKEN/missing.model3.json"))
        assertEquals(Route.NotFound, model("$TOKEN/textures/missing.png"))
        assertEquals(Route.NotFound, model("$TOKEN/folder.png"))
    }

    @Test
    fun modelRejectsFilesOutsideTheModelFileTypes() {
        File(staged, "notes.txt").writeText("x")
        File(staged, "model.cdi3.json").writeText("{}")
        for (path in listOf("notes.txt", "model.cdi3.json", "missing.json", "textures", "index.html", "viewer.js")) {
            assertEquals(path, Route.Forbidden, model("$TOKEN/$path"))
        }
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
        val link = File(staged, "escape.model3.json")
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
        assertEquals(Route.Forbidden, model("$TOKEN/escape.model3.json"))
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
    fun modelIdsFollowTheProfileRule() {
        for (id in listOf("a", "0", "hero-1", "Hero_1.v2", "hero.pending.x", "a".repeat(128))) {
            assertTrue(id, Live2DViewerRoutes.isValidModelId(id))
        }
        for (id in listOf(
            "",
            ".a",
            "-a",
            "_a",
            "..",
            "a b",
            "a/b",
            "a\\b",
            "a\n",
            "h\u00e9ro",
            "a".repeat(129),
            "hero.pending",
            "hero.PENDING",
            "hero.old",
            "hero.Old",
        )) {
            assertFalse(id, Live2DViewerRoutes.isValidModelId(id))
        }
    }

    @Test
    fun storeDirectoryIsCreatedUnderTheNoBackupDirectory() {
        val noBackup = temp.newFolder("no_backup")
        val expected = File(noBackup, Live2DViewerRoutes.STORE_DIR).canonicalFile
        assertEquals(expected, Live2DViewerRoutes.storeDirectory(noBackup))
        assertTrue(expected.isDirectory)
        assertEquals(expected, Live2DViewerRoutes.storeDirectory(noBackup))
        assertNull(Live2DViewerRoutes.storeDirectory(null))
        val blocked = temp.newFolder("blocked")
        File(blocked, Live2DViewerRoutes.STORE_DIR).writeText("a file, not a directory")
        assertNull(Live2DViewerRoutes.storeDirectory(blocked))
    }

    @Test
    fun persistedModelDirectoryAcceptsOnlyModelDirectoriesDirectlyInTheStore() {
        val storeRoot = temp.newFolder(Live2DViewerRoutes.STORE_DIR)
        val models = File(storeRoot, Live2DViewerRoutes.MODELS_DIR).apply { mkdirs() }
        val model = File(models, "hero-1").apply { mkdirs() }
        File(model, "nested").mkdirs()
        for (name in listOf("hero-1.pending", "hero-1.old", ".hidden")) File(models, name).mkdirs()
        File(models, "file.model3.json").writeText("{}")
        val canonical = model.canonicalFile
        assertEquals(canonical, Live2DViewerRoutes.persistedModelDirectory(storeRoot, model.path))
        assertEquals(
            canonical,
            Live2DViewerRoutes.persistedModelDirectory(storeRoot, File(models, "hero-1/../hero-1").path),
        )
        for (directory in listOf(
            storeRoot.path,
            models.path,
            File(models, "hero-1.pending").path,
            File(models, "hero-1.old").path,
            File(models, ".hidden").path,
            File(models, "file.model3.json").path,
            File(model, "nested").path,
            File(models, "missing").path,
            staged.path,
            "${Live2DViewerRoutes.MODELS_DIR}/hero-1",
            "",
            model.path + "\u0000",
        )) {
            assertNull(directory, Live2DViewerRoutes.persistedModelDirectory(storeRoot, directory))
        }
    }

    @Test
    fun servedDirectoryAcceptsAStagingOrAStoredModelDirectory() {
        val storeRoot = temp.newFolder(Live2DViewerRoutes.STORE_DIR)
        val model = File(storeRoot, "${Live2DViewerRoutes.MODELS_DIR}/hero-1").apply { mkdirs() }
        assertEquals(staged.canonicalFile, Live2DViewerRoutes.servedDirectory(previewRoot, storeRoot, staged.path))
        assertEquals(staged.canonicalFile, Live2DViewerRoutes.servedDirectory(previewRoot, null, staged.path))
        assertEquals(model.canonicalFile, Live2DViewerRoutes.servedDirectory(previewRoot, storeRoot, model.path))
        assertNull(Live2DViewerRoutes.servedDirectory(previewRoot, null, model.path))
        for (directory in listOf(storeRoot.path, previewRoot.path, temp.root.path)) {
            assertNull(directory, Live2DViewerRoutes.servedDirectory(previewRoot, storeRoot, directory))
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
