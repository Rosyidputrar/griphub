package id.griphub.agent

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The key the agent host uses to encrypt stored tokens (see agent/src/secure.ts).
 * A random 256-bit key, itself encrypted by a non-exportable Android Keystore
 * key, so a copy of the app's files alone can't reveal the tokens.
 */
object SecureKey {
    private const val ALIAS = "griphub_store"
    private const val PREFS = "griphub_secure"

    @Synchronized
    fun hex(context: Context): String {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val wrapped = prefs.getString("store_key", null)
        if (wrapped != null) {
            // Fail loudly on unwrap failure (Keystore key invalidated, prefs
            // restored onto another device, …). The old code fell through
            // here and generated a NEW key, silently making every stored
            // token undecryptable. Recovery is explicit via resetHex().
            return runCatching { unwrap(wrapped).toHex() }.getOrElse {
                throw IllegalStateException(
                    "Saved store key could not be unlocked. Use Reset saved keys to start over; saved tokens will need to be entered again."
                )
            }
        }
        val key = ByteArray(32).also { SecureRandom().nextBytes(it) }
        prefs.edit().putString("store_key", wrap(key)).apply()
        return key.toHex()
    }

    /** Explicit recovery only: drops the stored key and starts a fresh one. */
    @Synchronized
    fun resetHex(context: Context): String {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val key = ByteArray(32).also { SecureRandom().nextBytes(it) }
        prefs.edit().putString("store_key", wrap(key)).apply()
        return key.toHex()
    }

    private fun keystoreKey(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return gen.generateKey()
    }

    private fun wrap(raw: ByteArray): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, keystoreKey()) }
        return Base64.encodeToString(cipher.iv + cipher.doFinal(raw), Base64.NO_WRAP)
    }

    private fun unwrap(stored: String): ByteArray {
        val bytes = Base64.decode(stored, Base64.NO_WRAP)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, keystoreKey(), GCMParameterSpec(128, bytes, 0, 12))
        return cipher.doFinal(bytes, 12, bytes.size - 12)
    }

    private fun ByteArray.toHex() = joinToString("") { "%02x".format(it) }
}
