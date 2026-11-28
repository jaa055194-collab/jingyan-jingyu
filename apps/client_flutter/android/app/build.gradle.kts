// `java.io.File` written out in full fails here: in a Kotlin build script `java` resolves to
// the project's `java` extension, so import the class instead.
import java.io.File

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.jingyu.client_flutter"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.jingyu.client_flutter"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

// The Live2D viewer page from packages/jingyu_live2d_web goes into the APK assets under
// live2d/viewer/, where Live2DPlatformView serves it (see Live2DViewerRoutes).
// Uses the AGP Sources API (addGeneratedSourceDirectory), as in "Contribute generated sources
// to the build": https://developer.android.com/build/extend-agp
val live2dViewerWeb = file("../../../../packages/jingyu_live2d_web/web")

androidComponents {
    onVariants { variant ->
        val sync = tasks.register<SyncLive2DViewerAssets>(
            "syncLive2DViewerAssets${variant.name.replaceFirstChar { it.uppercase() }}",
        ) {
            webDirectory.set(live2dViewerWeb)
        }
        variant.sources.assets?.addGeneratedSourceDirectory(
            sync,
            SyncLive2DViewerAssets::outputDirectory,
        )
    }
}

dependencies {
    // WebViewAssetLoader and WebViewCompat.addWebMessageListener for the Live2D preview.
    implementation("androidx.webkit:webkit:1.18.0")
    testImplementation("junit:junit:4.13.2")
}

flutter {
    source = "../.."
}

/**
 * Copies the viewer page into `<output>/live2d/viewer/`. Fails if a page file is missing.
 * The PurismCore runtime is fetched separately (tool/fetch_purismcore.ps1) and is not in git,
 * so a missing runtime only warns; its MIT LICENSE must ship with it whenever it is present.
 */
abstract class SyncLive2DViewerAssets : DefaultTask() {
    @get:InputDirectory
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val webDirectory: DirectoryProperty

    @get:OutputDirectory
    abstract val outputDirectory: DirectoryProperty

    @TaskAction
    fun sync() {
        val web = webDirectory.get().asFile
        val out = outputDirectory.get().asFile
        out.deleteRecursively()
        val viewer = File(out, "live2d/viewer")
        for (name in listOf(
            "live2d_viewer.html",
            "live2d_viewer.js",
            "live2d_renderer_webgl.js",
            "live2d_texture_budget.js",
            "live2d_motion.js",
            "live2d_behavior.js",
            "live2d_physics.js",
            "live2d_pose.js",
        )) {
            val source = File(web, name)
            if (!source.isFile) {
                throw GradleException("Live2D viewer file is missing: ${source.path}")
            }
            source.copyTo(File(viewer, name), overwrite = true)
        }
        val runtime = File(web, "runtime/purismcore")
        val core = File(runtime, "purismcore.js")
        if (!core.isFile) {
            logger.warn(
                "warning: PurismCore runtime not found at ${core.path}. The APK will not include it " +
                    "and the Live2D preview will fail to load. " +
                    "Run packages/jingyu_live2d_web/tool/fetch_purismcore.ps1 before building.",
            )
            return
        }
        val license = File(runtime, "LICENSE")
        if (!license.isFile) {
            throw GradleException("PurismCore LICENSE is missing next to ${core.path}")
        }
        core.copyTo(File(viewer, "runtime/purismcore/purismcore.js"), overwrite = true)
        license.copyTo(File(viewer, "runtime/purismcore/LICENSE"), overwrite = true)
    }
}
