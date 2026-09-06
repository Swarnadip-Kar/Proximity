// Web records-build implementation of [localIPv4Addrs]: no interfaces on
// web (records builds never host).
library;

Future<List<String>> localIPv4Addrs() async => const ['127.0.0.1'];
