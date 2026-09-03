package org.iitbhilai.proximity.face_detect

import android.content.Context
import android.net.Uri
import androidx.annotation.NonNull
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

class ProximityFaceDetectPlugin : FlutterPlugin, MethodCallHandler {
  private lateinit var channel: MethodChannel
  private lateinit var appContext: Context

  override fun onAttachedToEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    appContext = binding.applicationContext
    channel = MethodChannel(binding.binaryMessenger, "proximity_face_detect")
    channel.setMethodCallHandler(this)
  }

  override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
    if (call.method != "detectFaces") {
      result.notImplemented()
      return
    }
    val path = call.argument<String>("path")
    if (path == null) {
      result.error("BAD_ARGS", "Missing image path", null)
      return
    }
    try {
      val image = InputImage.fromFilePath(
        appContext, Uri.fromFile(java.io.File(path)))
      val options = FaceDetectorOptions.Builder()
        .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST)
        .setMinFaceSize(0.15f)
        .build()
      FaceDetection.getClient(options)
        .process(image)
        .addOnSuccessListener { faces -> result.success(faces.size) }
        .addOnFailureListener { e -> result.error("DETECT_FAILED", e.message, null) }
    } catch (e: Exception) {
      result.error("DETECT_FAILED", e.message, null)
    }
  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
  }
}
