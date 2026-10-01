// Relay policy: which devices re-air challenges (active mesh) vs listen
// passively (prove over WiFi, never ADV).
//
// Old phones + iPhones drown in the BLE storm (scan→parse→ADV churn +
// CoreBluetooth throttling + background pause). Passive mode keeps marking
// working while cutting ~1 ADV/10s/device from the hall.
library;

import 'platformx.dart';

/// True when this device should listen passively (no relay).
/// iOS: CoreBluetooth foreground-only + displaced mfg data + OS scan
/// throttling make iPhones poor relays; Android front rows cover.
/// Low-RAM Android heuristic lives here when a RAM signal lands.
bool shouldRelayPassively() => isIOS;
