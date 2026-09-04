import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/core/device_store.dart';
import 'package:proximity_app/core/student_driver.dart';
import 'package:proximity_app/mode.dart';
import 'package:proximity_ble/ble.dart';
import 'package:proximity_face/face.dart';
import 'package:proximity_protocol/protocol.dart';
import 'package:proximity_transport/transport.dart';

const _email = 's@x.in';
const _beacon = ClassBeacon(
  classLabel: 't',
  host: '127.0.0.1',
  port: 9,
  rssiDbm: 0,
  displayCode: 'X',
);

Future<InMemoryDeviceStore> enrolledStore() async {
  final s = InMemoryDeviceStore();
  await s.writeEnrollment(StoredEnrollment(
    email: _email,
    name: 'S',
    roll: '1',
    seedHex: 'ab' * 32,
    pkHex: 'cd' * 32,
    templateCsv: '1.0,0.0,0.0,0.0',
    enrolledAt: DateTime.now().toUtc(),
  ));
  return s;
}

MockFaceEmbedder mockEmbedder() => MockFaceEmbedder(
      enrolled: const [1, 0, 0, 0],
      probe: const [1, 0, 0, 0],
    );

void main() {
  test('checkFace passes with enrolled template', () async {
    final d = RealStudentDriver(
      store: await enrolledStore(),
      embedder: mockEmbedder(),
      engine: ProxBleEngine(radio: FakeBleRadio()),
    );
    expect(await d.checkFace(Uint8List.fromList([9])), 1.0);
  });

  test('checkFace fails without enrollment', () async {
    final d = RealStudentDriver(
      store: InMemoryDeviceStore(),
      embedder: mockEmbedder(),
      engine: ProxBleEngine(radio: FakeBleRadio()),
    );
    expect(await d.checkFace(Uint8List.fromList([9])), isNull);
  });

  test('no radio heard -> noSignal (never fake-marked)', timeout: const Timeout(Duration(minutes: 2)), () async {
    final d = RealStudentDriver(
      store: await enrolledStore(),
      embedder: mockEmbedder(),
      engine: ProxBleEngine(radio: FakeBleRadio()),
    );
    var progress = 0.0;
    // hearChallenge that never resolves within the window.
    final slowHear = Future<Uint8List?>.delayed(
        const Duration(seconds: 60), () => null);
    final res = await d.listenAndProve(
      target: _beacon,
      identity:
          const LinkedIdentity(name: 'S', gmail: _email, roll: '1'),
      faceScore: 1.0,
      onProgress: (p) => progress = p,
      hearChallenge: () => slowHear.timeout(
        const Duration(seconds: 2),
        onTimeout: () => null,
      ),
    );
    expect(res.result, StudentResult.noSignal);
    expect(progress, greaterThan(0));
  });

  test('engine nextChallenge resolves injected sightings', () async {
    // Full client prove against a real local ProxServer is covered in
    // transport tests; here the radio wait resolves and progress completes.
    final engine = ProxBleEngine(radio: FakeBleRadio());
    // Inject a challenge sighting straight into the engine (as the BLE
    // stack would), then resolve via nextChallenge.
    final cj = Uint8List.fromList([4, 4, 4, 4, 4, 4, 4, 4]);
    engine.handleSighting(BleSighting(
      uuid: UuidCodec.packChallenge(cj),
      rssiDbm: -60,
      at: DateTime.now().toUtc(),
    ));
    final heard = await engine.nextChallenge(
        timeout: const Duration(seconds: 2));
    expect(heard, cj);
  });
}
