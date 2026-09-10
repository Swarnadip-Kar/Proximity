// Shared manual-add form — M3 re-export shim (Live section, 2026-09-10).
//
// M3 MECHANICAL MOVE (§4.8, see INTEGRATION_LOG.md): `ManualAddForm` and
// its search/queue orchestration moved to
// `features/manual_attendance/` (`manual_add_form.dart` UI +
// `manual_directory.dart` orchestration + `manual_inbox.dart` inbox UI).
// This file stays (Phase 6 owns deletions) as a re-export so existing
// imports — the saved-session editor, `manual_add_test.dart` — keep
// resolving with byte-identical behavior.
library;

export 'package:proximity_app/features/manual_attendance/manual_attendance.dart';

