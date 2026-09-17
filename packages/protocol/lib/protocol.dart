// Proximity protocol — pure Dart, no platform code. §5, §8.
library proximity_protocol;

export 'src/constants.dart';
export 'src/bytes.dart';
// M1 crypto kernel: canonical homes.
export 'src/crypto/primitives.dart';
export 'src/crypto/hardware_verify.dart';
export 'src/crypto/preimages.dart';
export 'src/crypto/freshness.dart';
export 'src/crypto/verify.dart';
export 'src/uuid_codec.dart';
export 'src/air.dart';
export 'src/air/ipv4.dart';
export 'src/air/parse.dart';
export 'src/clock_drift.dart';
export 'src/mesh.dart';
export 'src/face_gate.dart';
export 'src/face_print.dart';
export 'src/device_binding.dart';
export 'src/app_attest.dart';
export 'src/chain_verify.dart';
export 'src/attestation_boot.dart';
export 'src/prof_key_pin.dart';
