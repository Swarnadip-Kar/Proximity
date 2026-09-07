// Mark flow phases (student): ONE continuation from browse to verdict.
// Waiting → face check → proving → verdict reads as a single flow (the
// [MarkFlowShell] animates every hop); there are no hard cuts and no
// BLE/radar/verdict info dumps anywhere in between.
library;

/// Student mark phases in flow order. `paused` overlays any proving phase
/// (foreground-required rule); `manualPending` is the manual-fallback
/// branch off the waiting room.
enum StudentPhase {
  browsing,
  waiting,
  faceCheck,
  listening,
  marked,
  late,
  needsReview,
  noSignal,
  paused,
  manualPending,
}
