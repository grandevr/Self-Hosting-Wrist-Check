package uk.debil.status;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;

import java.nio.charset.StandardCharsets;
import java.security.KeyStore;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/**
 * Where the status URL and bearer token live.
 *
 * Set on the watch (browser or on-watch entry) and stored in app-private preferences. The token is
 * encrypted with an AES-GCM key that never leaves the Android Keystore. If nothing has been set up
 * on the watch, the optional build-time defaults from secrets.properties are used.
 * The token is never logged.
 */
final class Config {
    private static final String PREFS = "config";
    private static final String KEY_URL = "url";
    private static final String KEY_TOKEN = "token";      // base64(iv || ciphertext)
    private static final String KEYSTORE = "AndroidKeyStore";
    private static final String KEY_ALIAS = "status_token_key";
    private static final int GCM_TAG_BITS = 128;

    /** URL + token to fetch with. */
    static final class Creds {
        final String url;
        final String token;
        Creds(String url, String token) { this.url = url; this.token = token; }
    }

    /** Thrown when a token was stored but can't be decrypted right now. */
    static final class UnreadableException extends Exception {
        UnreadableException(Throwable cause) { super(cause); }
    }

    private Config() {}

    /** The credentials to use, or null if the app hasn't been set up yet. */
    static Creds load(Context ctx) throws UnreadableException {
        SharedPreferences p = prefs(ctx);
        String url = p.getString(KEY_URL, "");
        String enc = p.getString(KEY_TOKEN, "");
        if (!url.isEmpty() && !enc.isEmpty()) {
            try {
                return new Creds(url, decrypt(enc));
            } catch (Exception e) {
                throw new UnreadableException(e);
            }
        }
        if (!BuildConfig.STATUS_URL.isEmpty() && !BuildConfig.STATUS_TOKEN.isEmpty()) {
            return new Creds(BuildConfig.STATUS_URL, BuildConfig.STATUS_TOKEN);
        }
        return null;
    }

    static boolean isConfigured(Context ctx) {
        try {
            return load(ctx) != null;
        } catch (UnreadableException e) {
            return true; // something is stored; treat a decrypt hiccup as a fetch problem, not "not set up"
        }
    }

    /** The URL currently in use (to pre-fill setup forms), or "". Never returns the token. */
    static String currentUrl(Context ctx) {
        String url = prefs(ctx).getString(KEY_URL, "");
        return url.isEmpty() ? BuildConfig.STATUS_URL : url;
    }

    static void save(Context ctx, String url, String token) throws Exception {
        prefs(ctx).edit()
                .putString(KEY_URL, url)
                .putString(KEY_TOKEN, encrypt(token))
                .commit();
    }

    /** Checks a URL typed by the user. Returns an error message, or null if it's usable. */
    static String validateUrl(String url) {
        if (url == null || url.isEmpty()) return "Enter the status URL.";
        if (!url.startsWith("https://")) return "The URL must start with https://";
        try {
            java.net.URL u = new java.net.URL(url);
            if (u.getHost() == null || u.getHost().isEmpty()) return "The URL has no host name.";
        } catch (Exception e) {
            return "That doesn't look like a valid URL.";
        }
        return null;
    }

    private static SharedPreferences prefs(Context ctx) {
        return ctx.getApplicationContext().getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    private static SecretKey key() throws Exception {
        KeyStore ks = KeyStore.getInstance(KEYSTORE);
        ks.load(null);
        if (ks.containsAlias(KEY_ALIAS)) {
            return ((KeyStore.SecretKeyEntry) ks.getEntry(KEY_ALIAS, null)).getSecretKey();
        }
        KeyGenerator gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE);
        gen.init(new KeyGenParameterSpec.Builder(KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build());
        return gen.generateKey();
    }

    private static String encrypt(String plain) throws Exception {
        Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
        c.init(Cipher.ENCRYPT_MODE, key());
        byte[] iv = c.getIV();
        byte[] ct = c.doFinal(plain.getBytes(StandardCharsets.UTF_8));
        byte[] out = new byte[1 + iv.length + ct.length];
        out[0] = (byte) iv.length;
        System.arraycopy(iv, 0, out, 1, iv.length);
        System.arraycopy(ct, 0, out, 1 + iv.length, ct.length);
        return Base64.encodeToString(out, Base64.NO_WRAP);
    }

    private static String decrypt(String encoded) throws Exception {
        byte[] in = Base64.decode(encoded, Base64.NO_WRAP);
        int ivLen = in[0] & 0xFF;
        Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
        c.init(Cipher.DECRYPT_MODE, key(), new GCMParameterSpec(GCM_TAG_BITS, in, 1, ivLen));
        byte[] pt = c.doFinal(in, 1 + ivLen, in.length - 1 - ivLen);
        return new String(pt, StandardCharsets.UTF_8);
    }
}
