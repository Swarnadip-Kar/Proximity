//
// Post-End records freshness tick (prof live → Courses tab).
// Root cause it serves (post-End freshness): `ProfCoursesScreen` and
// `CourseOverviewScreen` read via `FutureBuilder` futures built from
// `store.readCourses()`/`store.readHistory()`. Both states live inside the
// shell `IndexedStack` + per-tab `Navigator`, which caches its route — tab
// switches never rebuild them, so the futures never re-read and the Courses
// tab keeps showing its pre-End snapshot (new session missing without an
// app restart; same stale-link class as the `_LiveRoot` catalog bug).
//
// Trigger wiring (no data/filter/sort change): the take host bumps this
// tick when its visit writes history or exits (End completion, round stop,
// manual decisions, direct adds, Live-tab exit — composition wrappers in
// `screens/take_attendance.dart` `build`, orchestration bodies untouched);
// the two records screens listen and `setState` (rebuilding re-creates
// their inline futures, so the next read is fresh — even while offstage,
// so the data is current before the tab is shown).
//
// Frozen: hosting lifecycle, drafts/snapshots, decision paths, strings
// semantics, timings, thresholds, network — none touched here.
library;

import 'package:flutter/foundation.dart';

/// Bumped every time the live visit durably changes class history (or
/// exits the Live tab). Records screens listen and re-read on change.
final ValueNotifier<int> liveHistoryTick = ValueNotifier<int>(0);

/// Bump the history-refresh tick (idempotent, synchronous notify).
void bumpLiveHistoryTick() {
  liveHistoryTick.value++;
}
