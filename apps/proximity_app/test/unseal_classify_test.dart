// Unseal failure classifier: one 'restore detected' collapses six local
// failures — the code pins the stage for field diagnosis (fail-closed).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proximity_app/features/device_identity/hw_device_key.dart';
import 'package:proximity_app/features/face_identity/device_key.dart';
import 'package:proximity_protocol/protocol.dart';

import 'test_device.dart';

void main() {
  final dek = randBytes(32);
  final seed = randBytes(32);
  late Uint8List validSeal;

  setUpAll(() {
    validSeal = sealWithDek(dek32: dek, seed32: seed);
    expect(validSeal.length, kHwSealEnvelopeBytes);
  });

  String classify({
    Uint8List? sealed,
    bool hwKeyPresent = true,
    bool dekPresent = true,
    bool aadInputsComplete = true,
    bool pkDMatchesStored = true,
  }) =>
      classifyUnsealFailure(
        sealed: sealed ?? validSeal,
        hwKeyPresent: hwKeyPresent,
        dekPresent: dekPresent,
        aadInputsComplete: aadInputsComplete,
        pkDMatchesStored: pkDMatchesStored,
      );

  test('complete inputs with a valid shape classify as tag-mismatch', () {
    // The classifier never opens the envelope (no DEK use): a well-formed
    // seal whose GCM tag fails (clone / legacy empty-AAD / corruption) is
    // the only remaining bucket.
    expect(classify(), 'tag-mismatch');
  });

  test('missing HW key / DEK win over everything else', () {
    expect(classify(hwKeyPresent: false), 'no-hw-key');
    expect(classify(dekPresent: false), 'no-dek');
    expect(
        classify(hwKeyPresent: false, dekPresent: false), 'no-hw-key');
  });

  test('short / corrupt envelopes classify as shape, not clone', () {
    expect(classify(sealed: Uint8List(0)), 'bad-envelope-shape');
    expect(classify(sealed: Uint8List.fromList([0x50, 0x58])),
        'bad-envelope-shape');
  });

  test('wrong magic on a full-length envelope is not a clone', () {
    final bad = Uint8List.fromList(validSeal);
    bad[0] = 0x00;
    expect(classify(sealed: bad), 'bad-envelope-magic');
  });

  test('PXK1 software envelope reads as legacy, not clone', () {
    final legacy =
        Uint8List.fromList([...kSealedKeyMagic, ...seed]);
    expect(classify(sealed: legacy), 'legacy-pxk1-seal');
  });

  test('missing AAD inputs / rotated pkD classify before the tag', () {
    expect(classify(aadInputsComplete: false), 'incomplete-aad-inputs');
    expect(classify(pkDMatchesStored: false), 'pkd-rotated');
  });

  test('sealDekPresent reflects the store without leaking key material',
      () async {
    final sealStore = MemorySealStore();
    final device =
        HwDeviceKey(backend: TestHwBackend(), sealStore: sealStore);
    expect(await device.sealDekPresent(), isFalse);
    await sealStore.writeDek(
        alias: kHwDeviceKeyAlias, dek32: randBytes(32));
    expect(await device.sealDekPresent(), isTrue);
  });
}
