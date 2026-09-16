// Compat barrel (M1): verifier + limiters + CSV export live in crypto/verify.dart.
// NOTE: the "Present rule default 2/2 (W1 AND W2)" header moved with that code
// (crypto/verify.dart) and describes the legacy protocol CSV only — the
// production app export path is proximity_storage (ClassRecord.toCsv /
// buildDateRangeMatrix: Present = intersection of ALL windows).
library;

export 'crypto/verify.dart';
