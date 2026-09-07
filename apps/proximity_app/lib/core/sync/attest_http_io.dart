// Native callable POST (see attest_http.dart).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// POSTs a v1-callable body, returns (status, decoded JSON object).
/// Throws on transport failure, timeout, or non-JSON — the caller maps
/// everything thrown here to unreachable/defer (never an anomaly).
Future<({int status, Map<String, dynamic> json})> postCallableJson(
    Uri url, Map<String, String> headers, String body) async {
  final client = HttpClient();
  try {
    final req =
        await client.postUrl(url).timeout(const Duration(seconds: 12));
    headers.forEach(req.headers.set);
    req.write(body);
    final res = await req.close().timeout(const Duration(seconds: 12));
    final text = await res
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 12));
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('callable: non-object JSON');
    }
    return (status: res.statusCode, json: decoded);
  } finally {
    client.close();
  }
}
