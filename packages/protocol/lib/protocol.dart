// Proximity protocol — pure Dart, no platform code. §5, §8.
library proximity_protocol;

export 'src/constants.dart';
export 'src/bytes.dart';
export 'src/crypto.dart';
export 'src/uuid_codec.dart';
export 'src/air.dart';
export 'src/air/ipv4.dart';
export 'src/air/parse.dart';
export 'src/clock_drift.dart';
export 'src/window.dart';
export 'src/mesh.dart';
export 'src/face_gate.dart';
export 'src/face_print.dart';
export 'src/transport_contract.dart';
// M1 crypto kernel: canonical homes (same declarations as the barrels above).
export 'src/crypto/primitives.dart';
export 'src/crypto/preimages.dart';
export 'src/crypto/freshness.dart';
export 'src/crypto/verify.dart';
export 'src/device_binding.dart';
