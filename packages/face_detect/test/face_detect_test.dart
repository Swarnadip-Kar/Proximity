import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_face_detect/face_detect.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('detectFaces returns native count', () async {
    const channel = MethodChannel('proximity_face_detect');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'detectFaces');
      expect((call.arguments as Map)['path'], '/tmp/face.jpg');
      return 2;
    });
    expect(await FaceScan.detectFaces('/tmp/face.jpg'), 2);
  });

  test('detectFaces null-safe', () async {
    const channel = MethodChannel('proximity_face_detect');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
    expect(await FaceScan.detectFaces('/tmp/face.jpg'), 0);
  });
}
