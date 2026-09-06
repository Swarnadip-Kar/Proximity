// dart:io implementation of [localIPv4Addrs].
library;

import 'dart:io';

Future<List<String>> localIPv4Addrs() async {
  final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4);
  final out = <String>[];
  for (final i in ifs) {
    for (final a in i.addresses) {
      if (!a.isLoopback && !out.contains(a.address)) out.add(a.address);
    }
  }
  return out;
}
