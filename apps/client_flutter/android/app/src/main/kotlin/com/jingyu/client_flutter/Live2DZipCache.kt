package com.jingyu.client_flutter

import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.InterruptedIOException

internal class Live2DZipTooLargeException : IOException()

internal object Live2DZipCache {
    private const val MAX_BYTES = 160 * 1024 * 1024
    private const val STALE_AFTER_MILLIS = 24L * 60L * 60L * 1000L
    @Volatile private var sweptThisProcess = false

    @Synchronized
    fun previewDirectory(cacheDir: File): File {
        val directory = File(cacheDir, "live2d-preview")
        if (!directory.exists() && !directory.mkdirs()) throw IOException()
        if (!directory.isDirectory) throw IOException()
        if (!sweptThisProcess) {
            val cutoff = System.currentTimeMillis() - STALE_AFTER_MILLIS
            directory.listFiles()?.forEach { child ->
                if ((child.name.startsWith("live2d-zip-") || child.name.startsWith("live2d-preview-")) &&
                    child.lastModified() in 1 until cutoff) {
                    child.deleteRecursively()
                }
            }
            sweptThisProcess = true
        }
        return directory
    }

    fun copy(cacheDir: File, openSource: () -> InputStream): File {
        checkInterrupted()
        val privateDirectory = previewDirectory(cacheDir)
        val file = File.createTempFile("live2d-zip-", ".zip", privateDirectory)
        var complete = false
        try {
            openSource().use { input ->
                file.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var remaining = MAX_BYTES
                    while (remaining > 0) {
                        checkInterrupted()
                        val count = input.read(buffer, 0, minOf(buffer.size, remaining))
                        if (count == -1) break
                        if (count == 0) throw IOException()
                        output.write(buffer, 0, count)
                        remaining -= count
                    }
                    // Probe for EOF without writing or reading a full buffer past the limit.
                    checkInterrupted()
                    if (remaining == 0 && input.read() != -1) {
                        throw Live2DZipTooLargeException()
                    }
                }
            }
            checkInterrupted()
            complete = true
            return file
        } finally {
            if (!complete) file.delete()
        }
    }

    private fun checkInterrupted() {
        if (Thread.currentThread().isInterrupted) throw InterruptedIOException()
    }
}
