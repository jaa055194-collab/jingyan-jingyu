package com.jingyu.client_flutter

import android.Manifest
import android.app.Activity
import android.app.KeyguardManager
import android.hardware.biometrics.BiometricPrompt
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

class MainActivity : FlutterActivity() {
    private companion object {
        const val PICK_LIVE2D_ZIP_REQUEST = 1401
    }

    private lateinit var channel: MethodChannel
    private lateinit var pinStore: PinStore
    private var pendingShare: Map<String, Any?>? = null
    private var authenticated = false
    private var biometricResult: MethodChannel.Result? = null
    private var biometricCancellation: CancellationSignal? = null
    private var live2dZipResult: MethodChannel.Result? = null
    private var live2dZipWorker: Thread? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pinStore = PinStore(this)
        pendingShare = readShare(intent)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "jingyu/platform")
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "initialize" -> {
                        result.success(mapOf(
                            "platform" to "android",
                            "notificationPermission" to ShellNotifications.allowed(this),
                            "biometricAvailable" to biometricAvailable(),
                            "pendingShare" to pendingShare
                        ))
                        pendingShare = null
                        if (Build.VERSION.SDK_INT >= 33 && !ShellNotifications.allowed(this)) {
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1101)
                        }
                    }
                    "getDataDirectory" -> result.success(filesDir.absolutePath)
                    "getLive2DPreviewDirectory" -> result.success(Live2DZipCache.previewDirectory(cacheDir).absolutePath)
                    "pickLive2DZip" -> pickLive2DZip(result)
                    "storeSession" -> {
                        pinStore.storeSession(call.argument<String>("json") ?: error("Session JSON required"))
                        result.success(null)
                    }
                    "readSession" -> result.success(pinStore.readSession())
                    "clearSession" -> {
                        authenticated = false
                        cancelBiometric()
                        pinStore.clearSession()
                        stopService(Intent(this, KeepAliveService::class.java))
                        result.success(null)
                    }
                    "hasPin" -> result.success(pinStore.hasPin())
                    "configurePin" -> {
                        if (pinStore.hasPin() && !authenticated) {
                            result.error("locked", "Unlock before changing the PIN", null)
                        } else {
                            pinStore.configure(call.argument<String>("pin") ?: "")
                            authenticated = true
                            result.success(null)
                        }
                    }
                    "unlockPin" -> {
                        authenticated = pinStore.verify(call.argument<String>("pin") ?: "")
                        result.success(authenticated)
                    }
                    "unlockBiometric" -> unlockBiometric(result)
                    "removePin" -> {
                        if (pinStore.hasPin() && !authenticated) {
                            result.error("locked", "Unlock before removing the PIN", null)
                        } else {
                            pinStore.remove()
                            authenticated = false
                            result.success(null)
                        }
                    }
                    "lock", "logout" -> {
                        authenticated = false
                        cancelBiometric()
                        result.success(null)
                    }
                    "setForegroundService" -> {
                        val service = Intent(this, KeepAliveService::class.java)
                        if (call.argument<Boolean>("enabled") == true) {
                            if (Build.VERSION.SDK_INT >= 26) startForegroundService(service)
                            else startService(service)
                        } else stopService(service)
                        result.success(true)
                    }
                    "setMissedCall" -> {
                        CallTimeoutReceiver.update(
                            this,
                            call.argument<String>("callId") ?: "",
                            call.argument<String>("callerName") ?: "来电",
                            call.argument<String>("state") ?: "ringing",
                            call.argument<Boolean>("hidePreview") ?: true
                        )
                        result.success(true)
                    }
                    "showShare" -> {
                        val text = call.argument<String>("text") ?: ""
                        require(text.isNotBlank()) { "Share text is required" }
                        startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
                            type = "text/plain"
                            putExtra(Intent.EXTRA_TEXT, text)
                            putExtra(Intent.EXTRA_SUBJECT, call.argument<String>("subject"))
                        }, "分享"))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("platform_error", error.message, null)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        readShare(intent)?.let { share ->
            if (::channel.isInitialized) channel.invokeMethod("shareReceived", share)
            else pendingShare = share
        }
    }

    override fun onStop() {
        authenticated = false
        cancelBiometric()
        super.onStop()
    }

    private fun cancelBiometric() {
        val cancellation = biometricCancellation
        biometricCancellation = null
        biometricResult?.success(false)
        biometricResult = null
        cancellation?.cancel()
    }

    override fun onDestroy() {
        val pendingZip = live2dZipResult
        live2dZipResult = null
        live2dZipWorker?.interrupt()
        live2dZipWorker = null
        pendingZip?.success(null)
        cancelBiometric()
        super.onDestroy()
    }

    @Suppress("DEPRECATION")
    private fun pickLive2DZip(result: MethodChannel.Result) {
        if (live2dZipResult != null) {
            result.error("live2d_zip_busy", "A ZIP selection is already in progress", null)
            return
        }
        live2dZipResult = result
        try {
            startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "application/*"
                putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/zip", "application/x-zip-compressed"))
            }, PICK_LIVE2D_ZIP_REQUEST)
        } catch (_: Exception) {
            live2dZipResult = null
            live2dZipPickFailed(result)
        }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_LIVE2D_ZIP_REQUEST) return
        val pending = live2dZipResult ?: return
        if (live2dZipWorker != null) return
        if (resultCode != Activity.RESULT_OK) {
            live2dZipResult = null
            pending.success(null)
            return
        }
        try {
            val uri = data?.data
            if (uri == null || uri.scheme != "content") {
                live2dZipResult = null
                live2dZipPickFailed(pending)
                return
            }
            val resolver = applicationContext.contentResolver
            val directory = cacheDir
            live2dZipWorker = Thread({
                var file: File? = null
                var tooLarge = false
                try {
                    file = Live2DZipCache.copy(directory) {
                        resolver.openInputStream(uri) ?: throw IOException()
                    }
                } catch (_: Live2DZipTooLargeException) {
                    tooLarge = true
                } catch (_: Exception) {
                    // The provider's exception can contain a URI or path; never forward it.
                }
                if (!mainHandler.post { completeLive2DZipPick(pending, file, tooLarge) }) {
                    file?.delete()
                }
            }, "jingyu-live2d-zip").also { it.start() }
        } catch (_: Exception) {
            live2dZipResult = null
            live2dZipPickFailed(pending)
        }
    }

    private fun completeLive2DZipPick(pending: MethodChannel.Result, file: File?, tooLarge: Boolean) {
        if (live2dZipResult !== pending) {
            // onDestroy already cancelled the call; ownership never passed to Dart.
            file?.delete()
            return
        }
        live2dZipResult = null
        live2dZipWorker = null
        when {
            file != null -> pending.success(mapOf("path" to file.absolutePath, "temporary" to true))
            tooLarge -> pending.error("live2d_zip_too_large", "ZIP exceeds the 160 MiB limit", null)
            else -> live2dZipPickFailed(pending)
        }
    }

    private fun live2dZipPickFailed(result: MethodChannel.Result) {
        result.error("live2d_zip_pick_failed", "Could not open the selected ZIP", null)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 1101 && ::channel.isInitialized) {
            channel.invokeMethod("notificationPermissionChanged", ShellNotifications.allowed(this))
        }
    }

    private fun readShare(incoming: Intent?): Map<String, Any?>? {
        val intent = incoming ?: return null
        if (intent.action != Intent.ACTION_SEND && intent.action != Intent.ACTION_SEND_MULTIPLE) return null
        val uris = mutableListOf<Uri>()
        @Suppress("DEPRECATION")
        if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            uris.addAll(intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM) ?: emptyList())
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.add(it) }
        }
        intent.clipData?.let { clip ->
            for (index in 0 until clip.itemCount) clip.getItemAt(index).uri?.let { uris.add(it) }
        }
        val readableUris = uris.distinct().filter { it.scheme == "content" }
        if (intent.flags and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION != 0) {
            readableUris.forEach { uri ->
                try { contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
                catch (_: SecurityException) { /* Most share providers offer temporary grants only. */ }
            }
        }
        val share = mapOf(
            "text" to intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString(),
            "subject" to intent.getStringExtra(Intent.EXTRA_SUBJECT),
            "mimeType" to intent.type,
            "uris" to readableUris.map { it.toString() }
        )
        // Avoid replaying the same external share after Activity recreation.
        intent.action = Intent.ACTION_MAIN
        return share
    }

    private fun biometricAvailable(): Boolean {
        if (Build.VERSION.SDK_INT < 28) return false
        val keyguard = getSystemService(KeyguardManager::class.java)
        if (!keyguard.isDeviceSecure) return false
        return if (Build.VERSION.SDK_INT >= 29) {
            getSystemService(android.hardware.biometrics.BiometricManager::class.java)
                .canAuthenticate() == android.hardware.biometrics.BiometricManager.BIOMETRIC_SUCCESS
        } else packageManager.hasSystemFeature(PackageManager.FEATURE_FINGERPRINT)
    }

    private fun unlockBiometric(result: MethodChannel.Result) {
        if (!pinStore.hasPin() || !biometricAvailable() || Build.VERSION.SDK_INT < 28) {
            result.success(false)
            return
        }
        if (biometricResult != null) {
            result.error("busy", "Authentication already in progress", null)
            return
        }
        biometricResult = result
        val cancellation = CancellationSignal()
        biometricCancellation = cancellation
        fun complete(success: Boolean) {
            if (biometricCancellation !== cancellation) return
            authenticated = success
            biometricResult?.success(success)
            biometricResult = null
            biometricCancellation = null
        }
        BiometricPrompt.Builder(this)
            .setTitle("解锁鲸言鲸语")
            .setNegativeButton("使用 PIN", mainExecutor) { _, _ -> complete(false) }
            .build()
            .authenticate(biometricCancellation!!, mainExecutor, object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(authResult: BiometricPrompt.AuthenticationResult) { complete(true) }
                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) { complete(false) }
            })
    }
}
