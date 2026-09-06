// Byte helpers: strict hex decode + bounded u64 decode.
import 'dart:typed_data';

import 'package:proximity_protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  group('hexDecode', () {
    test('round-trips valid hex (either case)', () {
      expect(hexEncode(hexDecode('00ffA9')), '00ffa9');
      expect(hexDecode(''), isEmpty);
    });

    test('rejects non-hex instead of silently stripping', () {
      // The old strip-non-hex turned garbage into empty bytes, which
      // surfaced downstream as misleading bad-challenge/bad-sig verdicts.
      expect(() => hexDecode('zz'), throwsFormatException);
      expect(() => hexDecode('12zz34'), throwsFormatException);
      expect(() => hexDecode('0x12'), throwsFormatException);
    });

    test('rejects odd lengths instead of truncating', () {
      expect(() => hexDecode('abc'), throwsFormatException);
    });
  });

  group('u64beDecode', () {
    test('rejects short buffers instead of ranging', () {
      expect(() => u64beDecode(Uint8List.fromList([1, 2, 3])), throwsFormatException);
      expect(() => u64beDecode(Uint8List.fromList(List.filled(8, 1)), 1),
          throwsFormatException);
    });
  });
}
