// Web callable stub (see attest_http.dart): the records-only build holds
// no device key and never verifies — always unreachable so callers defer.
library;

Future<({int status, Map<String, dynamic> json})> postCallableJson(
        Uri url, Map<String, String> headers, String body) async =>
    throw StateError('attestation verify is mobile-only (records build)');
