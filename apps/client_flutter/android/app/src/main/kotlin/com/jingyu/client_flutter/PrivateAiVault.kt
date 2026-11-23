package com.jingyu.client_flutter

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.FileOutputStream
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Local-only sealed JSON bytes. Call from the serial vault worker, not the UI thread. */
internal class PrivateAiVault(context: Context) {
    companion object {
        const val MAX_RECORD_BYTES = 1024 * 1024
        private const val STORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "jingyu_private_ai_vault"
        private const val VERSION = 1
        private const val IV_BYTES = 12
        private const val TAG_BYTES = 16
        private const val HEADER_BYTES = 1 + IV_BYTES
        private const val OVERHEAD = HEADER_BYTES + TAG_BYTES

        fun isScope(scope: String): Boolean =
            scope.length == 64 && scope.all { it in '0'..'9' || it in 'a'..'f' }
    }

    private val directory = File(checkNotNull(context.noBackupFilesDir), "private-ai-vault")

    fun read(scope: String): ByteArray? {
        val file = fileFor(scope)
        // Distinguish an absent file from an unreadable one. Never create a
        // replacement key for an existing record that cannot be decrypted.
        val descriptor = try {
            Os.open(file.path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_NONBLOCK, 0)
        } catch (error: ErrnoException) {
            if (error.errno == OsConstants.ENOENT) return null
            throw error
        }
        val sealed = try {
            val stat = Os.fstat(descriptor)
            check(OsConstants.S_ISREG(stat.st_mode))
            val size = stat.st_size
            check(size in (OVERHEAD + 1).toLong()..(MAX_RECORD_BYTES + OVERHEAD).toLong())
            ByteArray(size.toInt()).also { buffer ->
                var offset = 0
                while (offset < buffer.size) {
                    val count = Os.read(descriptor, buffer, offset, buffer.size - offset)
                    check(count > 0)
                    offset += count
                }
                check(Os.read(descriptor, ByteArray(1), 0, 1) == 0)
            }
        } finally {
            Os.close(descriptor)
        }
        check(sealed[0].toInt() == VERSION)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            key(create = false),
            GCMParameterSpec(TAG_BYTES * 8, sealed, 1, IV_BYTES)
        )
        cipher.updateAAD(aad(scope))
        return cipher.doFinal(sealed, HEADER_BYTES, sealed.size - HEADER_BYTES)
    }

    fun write(scope: String, record: ByteArray) {
        val file = fileFor(scope)
        require(record.size in 1..MAX_RECORD_BYTES)
        check(directory.isDirectory || directory.mkdirs())
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key(create = true))
        cipher.updateAAD(aad(scope))
        val sealed = cipher.doFinal(record)
        check(cipher.iv.size == IV_BYTES && sealed.size == record.size + TAG_BYTES)

        // Equivalent to AtomicFile: fsync an encrypted sibling, then atomically
        // replace the old file. Os.rename reports errors rather than logging
        // the filename and potentially reporting a failed commit as success.
        val pending = pendingFor(file)
        removeIfPresent(pending)
        try {
            FileOutputStream(pending).use { output ->
                output.write(VERSION)
                output.write(cipher.iv)
                output.write(sealed)
                output.fd.sync()
            }
            Os.rename(pending.path, file.path)
        } finally {
            removeIfPresent(pending)
        }
    }

    fun remove(scope: String) {
        val file = fileFor(scope)
        removeIfPresent(pendingFor(file))
        removeIfPresent(file)
    }

    private fun fileFor(scope: String): File {
        require(isScope(scope))
        return File(directory, "$scope.bin")
    }

    private fun pendingFor(file: File) = File(directory, "${file.name}.pending")

    private fun removeIfPresent(file: File) {
        try {
            Os.remove(file.path)
        } catch (error: ErrnoException) {
            if (error.errno != OsConstants.ENOENT) throw error
        }
    }

    private fun aad(scope: String) = "jingyu.private-ai-vault.v$VERSION:$scope".toByteArray(Charsets.US_ASCII)

    private fun key(create: Boolean): SecretKey {
        val store = KeyStore.getInstance(STORE).apply { load(null) }
        val existing = store.getKey(KEY_ALIAS, null)
        if (existing != null) return existing as SecretKey
        check(create)
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, STORE).apply {
            init(
                KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .setRandomizedEncryptionRequired(true)
                    .build()
            )
        }.generateKey()
    }
}
