// Proximity WiFi transport: HTTPS server/client, TLS pinning, rate limits.
//
// Web (records-only) builds cannot use dart:io: the three socket files
// below resolve to throwing stubs with identical APIs, so shared drivers
// compile for web. Native builds are untouched (dart.library.io present).
library proximity_transport;

export 'package:proximity_protocol/protocol.dart'
    show ProveDecision, RateLimiter, proveLimiter, windowLimiter;
export 'src/tls.dart';
export 'src/server.dart' if (dart.library.html) 'src/server_stub.dart';
export 'src/client.dart' if (dart.library.html) 'src/client_stub.dart';
export 'src/discovery.dart' if (dart.library.html) 'src/discovery_stub.dart';
export 'src/transport_core.dart';
