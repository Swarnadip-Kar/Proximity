package org.iitbhilai.proximity

import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.WindowManager
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import java.security.MessageDigest

// FlutterFragmentActivity (not FlutterActivity): biometric-gated Keystore
// signing (AttestedSecureKeys, userAuth-gated DKey ops at prove time)
// drives an androidx BiometricPrompt, which requires a FragmentActivity
// host — plain FlutterActivity crashes the prove with
// KeyOperationError(key_operation_failed). Zero behavior change otherwise.
class MainActivity : FlutterFragmentActivity() {
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

    override fun configureFlutterEngine(flutterEngine: io.flutter.embedding.engine.FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        io.flutter.plugin.common.MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "org.iitbhilai.proximity/hardware_id"
        ).setMethodCallHandler { call, result ->
            if (call.method == "getAndroidId") {
                val id = android.provider.Settings.Secure.getString(
                    contentResolver,
                    android.provider.Settings.Secure.ANDROID_ID
                )
                result.success(id ?: "")
            } else if (call.method == "getMemoryInfo") {
                // No permission needed: total RAM + the OS low-RAM flag
                // (ActivityManager.isLowRamDevice — OEM-tuned). The Dart
                // relay policy treats either signal as passive-listen.
                val am = getSystemService(android.content.Context.ACTIVITY_SERVICE)
                    as android.app.ActivityManager
                val info = android.app.ActivityManager.MemoryInfo()
                am.getMemoryInfo(info)
                result.success(mapOf(
                    "totalMemBytes" to info.totalMem,
                    "lowRamDevice" to am.isLowRamDevice
                ))
            } else {
                result.notImplemented()
            }
        }
        registerScreenBrightnessChannel(flutterEngine)
        registerAmbientLightChannel(flutterEngine)
        registerKeystoreLogChannel(flutterEngine)
    }

    // Enroll flash assist (Dart: features/setup/flash_assist.dart).
    // Window brightness, NOT system brightness: a per-window attribute
    // that dies with the window, so backgrounding/kill self-heals a missed
    // Dart-side restore. getBrightness returns -1.0 when the window follows
    // the system (restored verbatim); setBrightness takes 0.0..1.0.
    // Callbacks already run on the platform thread; runOnUiThread is
    // belt-and-braces for OEM handler quirks.
    private fun registerScreenBrightnessChannel(flutterEngine: io.flutter.embedding.engine.FlutterEngine) {
        io.flutter.plugin.common.MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "org.iitbhilai.proximity/screen_brightness"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getBrightness" -> {
                    result.success(window.attributes.screenBrightness.toDouble())
                }
                "setBrightness" -> {
                    // Negative (Dart sends -1.0) = follow system: clear the
                    // window override so the OS brightness slider works again
                    // after back navigation. Coercing it into 0..1 stranded
                    // the window at darkest with "controlled by another app".
                    val raw = call.argument<Double>("value")
                    val v = if (raw != null && raw < 0) -1.0f
                        else (raw ?: 1.0).coerceIn(0.0, 1.0).toFloat()
                    runOnUiThread {
                        val attrs = window.attributes
                        attrs.screenBrightness = v
                        window.attributes = attrs
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    // Live ambient light (Dart: features/setup/ambient_light.dart).
    // TYPE_LIGHT lux at sensor rate (~5Hz, no permission needed) for the
    // instant flash-assist trigger: true pre-AE ambient, unlike the
    // auto-exposed capture crops. No sensor (emulator, some low-end) ends
    // the stream with UNAVAILABLE and Dart falls back to capture
    // brightness. Listener lives only while Dart listens (capture screens
    // up) — negligible battery.
    private fun registerAmbientLightChannel(flutterEngine: io.flutter.embedding.engine.FlutterEngine) {
        io.flutter.plugin.common.EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "org.iitbhilai.proximity/ambient_light"
        ).setStreamHandler(object : io.flutter.plugin.common.EventChannel.StreamHandler {
            private var listener: android.hardware.SensorEventListener? = null
            private var manager: android.hardware.SensorManager? = null

            override fun onListen(args: Any?, events: io.flutter.plugin.common.EventChannel.EventSink?) {
                val sink = events ?: return
                val mgr = getSystemService(android.content.Context.SENSOR_SERVICE)
                    as android.hardware.SensorManager
                val sensor = mgr.getDefaultSensor(android.hardware.Sensor.TYPE_LIGHT)
                if (sensor == null) {
                    sink.error("UNAVAILABLE", "No ambient light sensor", null)
                    return
                }
                manager = mgr
                val l = object : android.hardware.SensorEventListener {
                    override fun onSensorChanged(e: android.hardware.SensorEvent?) {
                        if (e != null && e.values.isNotEmpty()) {
                            sink.success(e.values[0].toDouble())
                        }
                    }
                    override fun onAccuracyChanged(
                        s: android.hardware.Sensor?, acc: Int) {}
                }
                listener = l
                mgr.registerListener(
                    l, sensor, android.hardware.SensorManager.SENSOR_DELAY_NORMAL)
            }

            override fun onCancel(args: Any?) {
                try {
                    val l = listener
                    if (l != null) manager?.unregisterListener(l)
                } catch (_: Exception) {}
                listener = null
                manager = null
            }
        })
    }

    // Keystore failure forensics (Dart: core/enrollment.dart generateKey
    // catch). The attested_secure_keys plugin logs per-attempt native
    // failures (attempt #N failed: <Class>) ONLY to logcat with no Dart
    // channel, and a release app cannot grant itself READ_LOGS — but an
    // app may always read its OWN logcat (UID-filtered, no permission).
    // This channel dumps the current process's AttestedSecureKeys lines
    // (bounded) so a field failure names the OS cause with one tap and no
    // cable. Best-effort: any exec/read failure returns an empty list,
    // never an error (must not fail the Dart error path over forensics).
    private fun registerKeystoreLogChannel(flutterEngine: io.flutter.embedding.engine.FlutterEngine) {
        io.flutter.plugin.common.MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "org.iitbhilai.proximity/keystore_log"
        ).setMethodCallHandler { call, result ->
            if (call.method == "dumpKeystoreLog") {
                Thread {
                    val lines: List<String> = try {
                        val pid = android.os.Process.myPid()
                        val proc = Runtime.getRuntime().exec(arrayOf(
                            "logcat", "-d",
                            "--pid", pid.toString(),
                            "-t", "200",
                            "-v", "brief",
                            "AttestedSecureKeys:D", "*:S"
                        ))
                        val done = proc.waitFor(3, java.util.concurrent.TimeUnit.SECONDS)
                        val out = if (done) {
                            proc.inputStream.bufferedReader().readText()
                        } else {
                            proc.destroy()
                            ""
                        }
                        out.lines()
                            .map { it.trim() }
                            .filter { it.contains("AttestedSecureKeys") }
                            .takeLast(40)
                            .map { if (it.length > 300) it.substring(0, 300) + "…" else it }
                    } catch (e: Exception) {
                        emptyList()
                    }
                    // Reply on the platform thread: MethodChannel results are
                    // not safe to complete from a worker thread, and the
                    // activity may have detached while logcat ran.
                    runOnUiThread {
                        try { result.success(lines) } catch (_ignored: Exception) {}
                    }
                }.start()
            } else {
                result.notImplemented()
            }
        }
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
