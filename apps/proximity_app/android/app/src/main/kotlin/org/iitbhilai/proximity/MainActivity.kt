package org.iitbhilai.proximity

import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.WindowManager
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    companion object {
        private const val TAG = "ProximityRelease"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Fail-closed first: a repackaged or wrong-key build dies here
        // before any UI is shown.
        verifyReleaseSignature()
        applyWindowHardening()
    }

    override fun onResume() {
        super.onResume()
        // Permission sheets, camera plugin, recents return reset window flags.
        applyWindowHardening()
    }

    override fun onPostResume() {
        super.onPostResume()
        // Runs after the engine's own resume handling — wins any flag race.
        applyWindowHardening()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // Dialogs and plugin activities clear decor flags on focus loss.
        if (hasFocus) applyWindowHardening()
    }

    private fun isDebuggable(): Boolean =
        (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

    private fun applyWindowHardening() {
        applyEdgeToEdge()
        // Audit 2026-09-12 H4: FLAG_SECURE blanks this window in screenshots
        // and screen recordings (recents thumbnail included). Release-only:
        // debuggable builds skip so developers can capture UI for review.
        // No plist equivalent exists on iOS (see iOS commit body) — Android
        // enforcement lives here, not in the manifest (no manifest attribute
        // sets FLAG_SECURE).
        if (!isDebuggable()) {
            window.setFlags(
                WindowManager.LayoutParams.FLAG_SECURE,
                WindowManager.LayoutParams.FLAG_SECURE
            )
        }
    }

    private fun applyEdgeToEdge() {
        // Backward-compatible edge-to-edge (API <35): draw behind the
        // status + navigation bars from the first frame. API 35+ enforces
        // this regardless (targetSdk 36). Dart also opts in via
        // SystemChrome.edgeToEdge, but that lands after first frame —
        // without this native call the launch shows opaque system bars.
        WindowCompat.setDecorFitsSystemWindows(window, false)
        // Fully transparent 3-button nav (no translucent scrim).
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
        }
        // Status-bar contrast enforcement exists on API 35+; opt out.
        if (Build.VERSION.SDK_INT >= 35) {
            window.isStatusBarContrastEnforced = false
        }
    }

    // Audit 2026-09-12 H4: release cert self-check. Compares the SHA-256 of
    // every signing cert on this package against the pinned value baked in
    // at build time (BuildConfig.RELEASE_CERT_SHA256, sourced from
    // -PreleaseCertSha256 / certSha256 in keystore.properties / env).
    // Debuggable builds skip entirely. Any failure throws: the process dies
    // on the launch screen with an actionable logcat line — fail-closed.
    private fun verifyReleaseSignature() {
        if (isDebuggable()) return
        val expected = BuildConfig.RELEASE_CERT_SHA256.replace(":", "").uppercase()
        if (expected.isBlank()) {
            Log.e(
                TAG, "Failing closed: release build carries no pinned " +
                    "signing-cert SHA-256 (BuildConfig.RELEASE_CERT_SHA256 is " +
                    "empty). Set -PreleaseCertSha256=<sha256>, certSha256 in " +
                    "android/keystore.properties, or RELEASE_CERT_SHA256, then " +
                    "rebuild. Refusing to run an unpinned release build."
            )
            throw SecurityException("Proximity fail-closed: no pinned signing-cert SHA-256.")
        }
        val signatures: Array<Signature> = try {
            readOwnSignatures()
        } catch (e: Exception) {
            Log.e(TAG, "Failing closed: could not read own signing certificates.", e)
            throw SecurityException("Proximity fail-closed: unreadable signing certificates.", e)
        }
        val digest = MessageDigest.getInstance("SHA-256")
        val matched = signatures.any { sig ->
            digest.digest(sig.toByteArray()).toHex().uppercase() == expected
        }
        if (!matched) {
            Log.e(
                TAG, "Failing closed: signing-cert SHA-256 mismatch — this " +
                    "build was NOT signed with the expected release key " +
                    "(expected=$expected). If you rotated the release key, " +
                    "update certSha256 / -PreleaseCertSha256 AND register the " +
                    "new SHA-256 in Play Console (Release > Setup > App " +
                    "integrity > App signing), then rebuild. Repackaged or " +
                    "debug-signed impostor builds stop here."
            )
            throw SecurityException("Proximity fail-closed: signing-cert SHA-256 mismatch.")
        }
    }

    private fun readOwnSignatures(): Array<Signature> {
        val pm = packageManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val info = pm.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES)
            val signingInfo = info.signingInfo
                ?: throw IllegalStateException("SigningInfo is null")
            // Multiple signers (rotation lineage): the device enforces the
            // lineage; any currently-valid signer matching the pin is fine.
            // Single signer: check the full history so a rotated-from key
            // still matches during the transition window.
            if (signingInfo.hasMultipleSigners()) signingInfo.apkContentsSigners
            else signingInfo.signingCertificateHistory
        } else {
            @Suppress("DEPRECATION")
            pm.getPackageInfo(packageName, PackageManager.GET_SIGNATURES).signatures
        } ?: emptyArray()
    }

    private fun ByteArray.toHex(): String {
        val chars = CharArray(size * 2)
        val hex = "0123456789ABCDEF"
        for (i in indices) {
            val v = this[i].toInt() and 0xFF
            chars[i * 2] = hex[v ushr 4]
            chars[i * 2 + 1] = hex[v and 0x0F]
        }
        return String(chars)
    }
}
