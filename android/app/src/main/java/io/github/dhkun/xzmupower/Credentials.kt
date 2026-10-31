package io.github.dhkun.xzmupower

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * 登录凭据的本机加密存储, 用于会话过期后静默重新登录。
 *
 * 密码用 Android Keystore 里的 AES-GCM 密钥加密, 密钥不可导出、仅本应用可用;
 * 密文存在普通 SharedPreferences。凭据只保存在本机, 不上传任何服务器。
 */
object Credentials {
    private const val FILE = "creds"
    private const val KEY_ALIAS = "xzmu_creds_key"
    private const val STORE = "AndroidKeyStore"

    const val TYPE_WX = "wx"
    const val TYPE_ECARD = "ecard"

    private fun sp(ctx: Context) = ctx.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    private fun secretKey(): SecretKey {
        val ks = KeyStore.getInstance(STORE).apply { load(null) }
        (ks.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, STORE)
        gen.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build()
        )
        return gen.generateKey()
    }

    private fun encrypt(plain: String): String? = try {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val iv = cipher.iv
        val enc = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        Base64.encodeToString(iv + enc, Base64.NO_WRAP)
    } catch (e: Exception) {
        null
    }

    private fun decrypt(blob: String?): String? {
        if (blob.isNullOrEmpty()) return null
        return try {
            val raw = Base64.decode(blob, Base64.NO_WRAP)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, raw, 0, 12))
            String(cipher.doFinal(raw, 12, raw.size - 12), Charsets.UTF_8)
        } catch (e: Exception) {
            null
        }
    }

    /** 是否已保存可用于自动续期的凭据 */
    fun has(ctx: Context): Boolean =
        sp(ctx).getBoolean("enabled", false) && !decrypt(sp(ctx).getString("password", null)).isNullOrEmpty()

    fun loginType(ctx: Context): String = sp(ctx).getString("type", TYPE_WX) ?: TYPE_WX
    fun username(ctx: Context): String = decrypt(sp(ctx).getString("username", null)) ?: ""
    fun password(ctx: Context): String = decrypt(sp(ctx).getString("password", null)) ?: ""
    fun customerCode(ctx: Context): String = sp(ctx).getString("customerCode", "") ?: ""
    fun outid(ctx: Context): String = decrypt(sp(ctx).getString("outid", null)) ?: ""

    fun save(ctx: Context, type: String, username: String, password: String,
             customerCode: String, outid: String) {
        if (password.isBlank()) return
        sp(ctx).edit()
            .putString("type", type)
            .putString("username", encrypt(username))
            .putString("password", encrypt(password))
            .putString("customerCode", customerCode)
            .putString("outid", encrypt(outid))
            .putBoolean("enabled", true)
            .apply()
        Prefs.bumpSessionGen(ctx)
    }

    /** 关闭自动续期并抹掉保存的密码 */
    fun clear(ctx: Context) {
        sp(ctx).edit().clear().apply()
        Prefs.bumpSessionGen(ctx)
    }

    /** 供认证恢复读取; 已开启却解不开时标记为暂不可用, 不等同于用户没开自动续期 */
    fun forLogin(ctx: Context): CredsRead {
        if (!sp(ctx).getBoolean("enabled", false)) return CredsRead(null)
        val pw = password(ctx)
        if (pw.isEmpty()) return CredsRead(null, unavailable = true)
        return CredsRead(LoginCreds(loginType(ctx), username(ctx), pw, customerCode(ctx), outid(ctx)))
    }
}
