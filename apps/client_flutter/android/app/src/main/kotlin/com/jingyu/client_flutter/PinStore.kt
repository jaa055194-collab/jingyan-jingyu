package com.jingyu.client_flutter

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec

/** App-private salted verifier; session secrets are encrypted by a non-exportable Keystore key. */
class PinStore(context: Context) {
    private val preferences = context.getSharedPreferences("jingyu_lock", Context.MODE_PRIVATE)
    fun hasPin() = preferences.contains("verifier")
    fun configure(pin: String) {
        require(pin.matches(Regex("[0-9]{4,12}"))) { "PIN must contain 4–12 digits" }
        val salt = ByteArray(32).also { SecureRandom().nextBytes(it) }
        check(preferences.edit().putString("salt", encode(salt))
            .putString("verifier", encode(derive(pin, salt))).putInt("failures", 0)
            .putLong("retryAfter", 0).commit()) { "Cannot save PIN" }
    }
    fun verify(pin: String): Boolean {
        if (!hasPin() || !pin.matches(Regex("[0-9]{4,12}")) || System.currentTimeMillis() < preferences.getLong("retryAfter", 0)) return false
        val salt = decode(preferences.getString("salt", "")!!)
        val matches = MessageDigest.isEqual(derive(pin, salt), decode(preferences.getString("verifier", "")!!))
        val failures = if (matches) 0 else preferences.getInt("failures", 0) + 1
        preferences.edit().putInt("failures", failures)
            .putLong("retryAfter", if (failures >= 5) System.currentTimeMillis() + 30_000 else 0).commit()
        return matches
    }
    fun remove() { check(preferences.edit().remove("salt").remove("verifier").remove("failures").remove("retryAfter").commit()) }
    private fun derive(pin: String, salt: ByteArray): ByteArray {
        val spec = PBEKeySpec(pin.toCharArray(), salt, 120_000, 256)
        return try { SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded }
        finally { spec.clearPassword() }
    }
    fun storeSession(json: String) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, sessionKey())
        check(preferences.edit().putString("session", encode(cipher.doFinal(json.toByteArray(Charsets.UTF_8))))
            .putString("sessionIv", encode(cipher.iv)).commit())
    }
    fun readSession(): String? {
        val encrypted = preferences.getString("session", null) ?: return null
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, sessionKey(), GCMParameterSpec(128, decode(preferences.getString("sessionIv", "")!!)))
        return String(cipher.doFinal(decode(encrypted)), Charsets.UTF_8)
    }
    fun clearSession() { check(preferences.edit().remove("session").remove("sessionIv").commit()) }
    private fun sessionKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey("jingyu_session", null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder("jingyu_session", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    private fun encode(value: ByteArray) = Base64.encodeToString(value, Base64.NO_WRAP)
    private fun decode(value: String) = Base64.decode(value, Base64.NO_WRAP)
}
