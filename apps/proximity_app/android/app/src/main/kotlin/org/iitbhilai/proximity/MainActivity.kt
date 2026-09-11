package org.iitbhilai.proximity

import android.os.Build
import android.os.Bundle
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        applyEdgeToEdge()
    }

    override fun onResume() {
        super.onResume()
        // Permission sheets, camera plugin, recents return reset window flags.
        applyEdgeToEdge()
    }

    override fun onPostResume() {
        super.onPostResume()
        // Runs after the engine's own resume handling — wins any flag race.
        applyEdgeToEdge()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // Dialogs and plugin activities clear decor flags on focus loss.
        if (hasFocus) applyEdgeToEdge()
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
}
