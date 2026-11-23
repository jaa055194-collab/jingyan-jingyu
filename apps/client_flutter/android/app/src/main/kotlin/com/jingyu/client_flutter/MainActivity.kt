package com.jingyu.client_flutter

import android.Manifest
import android.app.KeyguardManager
import android.hardware.biometrics.BiometricPrompt
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.CancellationSignal
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    companion object {
        private const val REQUEST_PICK_ATTACHMENT = 1201
        private const val REQUEST_SAVE_BACKUP = 1202
        private const val MAX_BACKUP_BYTES = 4 * 1024 * 1024
        // Serialize read/replace/delete across Activity recreation, including
        // Keystore key creation. Tasks access app-private storage only.
        private val privateAiVaultExecutor = Executors.newSingleThreadExecutor()
    }

    private val privateAiVault by lazy { PrivateAiVault(applicationContext) }

    private lateinit var channel: MethodChannel
    private lateinit var pinStore: PinStore
    private var pendingShare: Map<String, Any?>? = null
    private var pendingFileResult: MethodChannel.Result? = null
    private var pendingBackupResult: MethodChannel.Result? = null
    private var pendingBackupBytes: ByteArray? = null
    private var pendingBackupName: String? = null
    private val filePickerExecutor = Executors.newSingleThreadExecutor()
    private var authenticated = false
    private var biometricResult: MethodChannel.Result? = null
    private var biometricCancellation: CancellationSignal? = null
    private var voiceActivityResumed = false
    private val voicePlayback by lazy {
        VoiceMessagePlayback(this) { method, payload ->
            if (::channel.isInitialized) channel.invokeMethod(method, payload)
        }
    }

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
                            "voicePlaybackEpoch" to voicePlayback.epoch,
                            "voicePlaybackResumed" to voicePlayback.resumed,
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
                    "readPrivateAiVault", "writePrivateAiVault", "removePrivateAiVault" ->
                        handlePrivateAiVault(call, result)
                    "playVoiceMessage" -> {
                        val id = call.argument<Number>("requestId")?.toLong()
                        val epoch = call.argument<Number>("epoch")?.toLong()
                        val bytes = call.argument<ByteArray>("bytes")
                        if (id == null || epoch == null || bytes == null ||
                            (pinStore.hasPin() && !authenticated)
                        ) {
                            result.success(false)
                        } else {
                            voicePlayback.play(id, epoch, bytes, result)
                        }
                    }
                    "stopVoiceMessage" -> {
                        call.argument<Number>("requestId")?.toLong()?.let { voicePlayback.stop(it) }
                        result.success(null)
                    }
                    "storeSession" -> {
                        pinStore.storeSession(call.argument<String>("json") ?: error("Session JSON required"))
                        result.success(null)
                    }
                    "readSession" -> result.success(pinStore.readSession())
                    "clearSession" -> {
                        authenticated = false
                        voicePlayback.invalidate()
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
                        voicePlayback.invalidate()
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
                    "pickAttachment" -> {
                        if (pendingFileResult != null || pendingBackupResult != null) {
                            result.error("busy", "A file dialog is already open", null)
                        } else {
                            val kind = call.argument<String>("kind")
                            if (kind != "image" && kind != "file") {
                                result.error("invalid_arguments", "Unsupported attachment kind", null)
                            } else {
                                pendingFileResult = result
                                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                    addCategory(Intent.CATEGORY_OPENABLE)
                                    type = if (kind == "image") "image/*" else "*/*"
                                }
                                try {
                                    startActivityForResult(intent, REQUEST_PICK_ATTACHMENT)
                                } catch (error: Exception) {
                                    pendingFileResult = null
                                    result.error("pick_failed", "Cannot open file picker", null)
                                }
                            }
                        }
                    }
                    "saveBackupFile" -> {
                        if (pendingFileResult != null || pendingBackupResult != null) {
                            result.error("busy", "A file dialog is already open", null)
                        } else {
                            val suggestedName = sanitizeBackupName(call.argument<String>("suggestedName"))
                            val bytes = call.argument<ByteArray>("bytes")
                            val maxBytes = call.argument<Int>("maxBytes")
                            if (suggestedName == null || bytes == null || bytes.isEmpty() || maxBytes == null || maxBytes <= 0 || maxBytes > MAX_BACKUP_BYTES) {
                                result.error("invalid_arguments", "Backup name, bytes and a valid limit are required", null)
                            } else if (bytes.size > maxBytes) {
                                result.error("invalid_arguments", "Backup exceeds the requested byte limit", null)
                            } else {
                                pendingBackupResult = result
                                pendingBackupBytes = bytes
                                pendingBackupName = suggestedName
                                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                    addCategory(Intent.CATEGORY_OPENABLE)
                                    type = "application/json"
                                    putExtra(Intent.EXTRA_TITLE, suggestedName)
                                }
                                try {
                                    startActivityForResult(intent, REQUEST_SAVE_BACKUP)
                                } catch (error: Exception) {
                                    pendingBackupResult = null
                                    pendingBackupBytes = null
                                    pendingBackupName = null
                                    result.error("save_failed", "Cannot open save dialog", null)
                                }
                            }
                        }
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

    private fun handlePrivateAiVault(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *>
        val scope = arguments?.get("scope") as? String
        val isWrite = call.method == "writePrivateAiVault"
        val bytes = arguments?.get("bytes") as? ByteArray
        if (scope == null || !PrivateAiVault.isScope(scope) ||
            (isWrite && (bytes == null || bytes.size !in 1..PrivateAiVault.MAX_RECORD_BYTES))
        ) {
            result.error("private_ai_vault_error", "Invalid private AI vault arguments", null)
            return
        }
        privateAiVaultExecutor.execute {
            try {
                val value = when (call.method) {
                    "readPrivateAiVault" -> privateAiVault.read(scope)
                    "writePrivateAiVault" -> {
                        privateAiVault.write(scope, checkNotNull(bytes))
                        null
                    }
                    else -> {
                        privateAiVault.remove(scope)
                        null
                    }
                }
                runOnUiThread { if (!isDestroyed) result.success(value) }
            } catch (_: Exception) {
                runOnUiThread {
                    if (!isDestroyed) {
                        result.error("private_ai_vault_error", "Private AI vault operation failed", null)
                    }
                }
            } finally {
                if (isWrite) bytes?.fill(0)
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_SAVE_BACKUP) {
            finishSaveBackup(resultCode, data)
            return
        }
        if (requestCode != REQUEST_PICK_ATTACHMENT) return
        val result = pendingFileResult ?: return
        pendingFileResult = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        if (uri.scheme != "content") {
            result.error("pick_failed", "Selected file is unavailable", null)
            return
        }
        filePickerExecutor.execute {
            try {
                val name = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                    ?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }
                val mime = contentResolver.getType(uri)
                val picked = copyPickedFile(uri)
                runOnUiThread {
                    if (isDestroyed) {
                        picked.delete()
                    } else {
                        result.success(mapOf(
                            "path" to picked.absolutePath,
                            "name" to (name ?: "附件"),
                            "mime" to mime,
                            "temporary" to true
                        ))
                    }
                }
            } catch (error: Exception) {
                runOnUiThread {
                    if (!isDestroyed) result.error("pick_failed", "Selected file is unavailable", null)
                }
            }
        }
    }

    private fun finishSaveBackup(resultCode: Int, data: Intent?) {
        val result = pendingBackupResult ?: return
        val bytes = pendingBackupBytes
        val name = pendingBackupName
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            clearPendingBackup()
            result.success(null)
            return
        }
        if (uri.scheme != "content" || bytes == null || name == null) {
            clearPendingBackup()
            result.error("save_failed", "Backup destination is unavailable", null)
            return
        }
        filePickerExecutor.execute {
            try {
                val output = contentResolver.openOutputStream(uri, "wt")
                    ?: error("Cannot open backup destination")
                output.use { stream ->
                    stream.write(bytes)
                    stream.flush()
                }
                // The user may have renamed the document or the provider may
                // dedupe it; report what the destination actually says, and
                // report the destination's real length rather than the input.
                // Display-only: keep the provider's name when it is a safe
                // basename, otherwise fall back to the sanitized suggestion.
                val providedName = contentResolver.query(
                    uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null
                )?.use { cursor ->
                    if (cursor.moveToFirst()) cursor.getString(0) else null
                }
                val actualName = safeDisplayName(providedName) ?: name
                val writtenBytes = contentResolver.openFileDescriptor(uri, "r")
                    ?.use { descriptor -> descriptor.statSize }
                    ?.takeIf { it == bytes.size.toLong() }
                    ?.toInt()
                    ?: error("Backup destination size does not match")
                runOnUiThread {
                    if (!isDestroyed) {
                        clearPendingBackup()
                        result.success(mapOf("name" to actualName, "bytes" to writtenBytes))
                    }
                }
            } catch (error: Exception) {
                // A failed/partial document is not success. Do not delete the
                // user's chosen destination; it may have held an older file.
                runOnUiThread {
                    if (!isDestroyed) {
                        clearPendingBackup()
                        result.error("save_failed", "Cannot save backup file", null)
                    }
                }
            }
        }
    }

    private fun clearPendingBackup() {
        pendingBackupResult = null
        pendingBackupBytes = null
        pendingBackupName = null
    }

    /// Display-only basename: no path separators or control characters, no
    /// extension rewriting, so it matches what the provider actually stored.
    private fun safeDisplayName(raw: String?): String? {
        val base = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val basename = base.substringAfterLast('/').substringAfterLast('\\').trim()
        val cleaned = basename.filter { it.code >= 32 && it.code != 127 }.trim()
        if (cleaned.isEmpty() || cleaned.length > 200) return null
        return cleaned
    }

    private fun sanitizeBackupName(raw: String?): String? {
        val base = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val basename = base.substringAfterLast('/').substringAfterLast('\\').trim()
        val cleaned = basename.filter { it.code >= 32 && it.code != 127 }.trim().trimStart('.')
        if (cleaned.isEmpty()) return null
        val withExtension = if (cleaned.endsWith(".json", ignoreCase = true)) cleaned else "$cleaned.json"
        return if (withExtension.length <= 100) withExtension else withExtension.take(95) + ".json"
    }

    private fun copyPickedFile(uri: Uri): File {
        val folder = File(cacheDir, "picked-attachments")
        require(folder.isDirectory || folder.mkdirs()) { "Cannot create attachment cache" }
        val destination = File(folder, UUID.randomUUID().toString())
        val input = contentResolver.openInputStream(uri) ?: error("Cannot read selected file")
        var total = 0L
        try {
            input.use { source ->
                destination.outputStream().use { target ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        if (Thread.currentThread().isInterrupted) throw InterruptedException()
                        val count = source.read(buffer)
                        if (count < 0) break
                        total += count
                        if (total > 128L * 1024 * 1024) {
                            throw IllegalArgumentException("Selected file is too large")
                        }
                        target.write(buffer, 0, count)
                    }
                }
            }
        } catch (error: Exception) {
            destination.delete()
            throw error
        }
        return destination
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        readShare(intent)?.let { share ->
            if (::channel.isInitialized) channel.invokeMethod("shareReceived", share)
            else pendingShare = share
        }
    }

    override fun onResume() {
        super.onResume()
        voiceActivityResumed = true
        voicePlayback.setForeground(hasWindowFocus())
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        voicePlayback.setForeground(voiceActivityResumed && hasFocus)
    }

    override fun onPause() {
        voiceActivityResumed = false
        voicePlayback.setForeground(false)
        super.onPause()
    }

    override fun onStop() {
        voicePlayback.setForeground(false)
        authenticated = false
        cancelBiometric()
        super.onStop()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        voiceActivityResumed = false
        voicePlayback.setForeground(false)
        if (::channel.isInitialized) channel.setMethodCallHandler(null)
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun cancelBiometric() {
        val cancellation = biometricCancellation
        biometricCancellation = null
        biometricResult?.success(false)
        biometricResult = null
        cancellation?.cancel()
    }

    override fun onDestroy() {
        voiceActivityResumed = false
        voicePlayback.setForeground(false)
        cancelBiometric()
        pendingFileResult?.success(null)
        pendingFileResult = null
        pendingBackupResult?.success(null)
        pendingBackupResult = null
        pendingBackupBytes = null
        pendingBackupName = null
        filePickerExecutor.shutdownNow()
        super.onDestroy()
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
