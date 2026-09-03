import UIKit
import Flutter
import Vision

public class ProximityFaceDetectPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "proximity_face_detect", binaryMessenger: registrar.messenger())
    let instance = ProximityFaceDetectPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "detectFaces",
          let args = call.arguments as? [String: Any],
          let path = args["path"] as? String else {
      result(FlutterMethodNotImplemented)
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let count = Self.faceCount(atPath: path)
      DispatchQueue.main.async { result(count) }
    }
  }

  private static func faceCount(atPath path: String) -> Int {
    let url = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: url),
          let image = UIImage(data: data),
          let cg = image.cgImage else { return 0 }
    let request = VNDetectFaceRectanglesRequest()
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    do {
      try handler.perform([request])
      return request.results?.count ?? 0
    } catch {
      return 0
    }
  }
}
