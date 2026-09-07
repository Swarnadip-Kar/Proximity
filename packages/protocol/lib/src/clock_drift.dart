// Clock-drift banner: professor is the time authority (signed serverTime
// in every ACK), but phones drift. When the median |t_local - t_server|
// over recent proofs exceeds [kClockDriftBannerSecs], the student UI shows
// an honest banner ("your clock disagrees with the professor's — marks may
// read late") instead of silently verdicting late. Pure Dart, no platform
// code; the student driver feeds it one sample per verdict.
library;

/// Median drift magnitude (seconds) that raises the banner.
const double kClockDriftBannerSecs = 5;

/// Recent-sample window for the median.
const int kClockDriftWindow = 9;

class ClockDriftTracker {
  final List<double> _offsetsSecs = [];

  /// Records one verdict: [serverTime] from the signed ACK vs the local
  /// receipt instant. Positive = server ahead.
  void addSample({required DateTime serverTime, required DateTime localNow}) {
    _offsetsSecs.add(
        serverTime.toUtc().difference(localNow.toUtc()).inMilliseconds /
            1000.0);
    while (_offsetsSecs.length > kClockDriftWindow) {
      _offsetsSecs.removeAt(0);
    }
  }

  int get sampleCount => _offsetsSecs.length;

  /// Median of |offsets| (0 with no samples).
  double get medianAbsSecs {
    if (_offsetsSecs.isEmpty) return 0;
    final sorted = _offsetsSecs.map((o) => o.abs()).toList()..sort();
    return sorted[sorted.length ~/ 2];
  }

  /// True when the median drift exceeds the banner threshold. Needs at
  /// least 3 samples so one slow POST cannot banner.
  bool get drifted =>
      _offsetsSecs.length >= 3 &&
      medianAbsSecs > kClockDriftBannerSecs;

  /// One-line banner copy, or null when clocks agree.
  String? get banner => drifted
      ? 'Clock drift ~${medianAbsSecs.toStringAsFixed(0)}s vs professor — marks may read late; check automatic date & time.'
      : null;

  void clear() => _offsetsSecs.clear();
}
