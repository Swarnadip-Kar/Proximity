// Manual attendance module barrel (§4.8).
//
// Professor manual attendance (`live/<course>/inbox` approve/reject plus
// the manual-add form on `live/<course>/add`) is one implementation
// imported by both routes — not duplicated screen-local UI. The inbox
// carries its own `SelectionScope` instance per list (see
// `manual_inbox.dart`); the form's search/queue orchestration lives in
// `manual_directory.dart`.
//
// M3 compatibility: `widgets/manual_add.dart` is a re-export shim over
// this barrel (Phase 6 owns deletions), so existing imports — the
// saved-session editor, `direct_add.dart` (pre-rebuild), and
// `manual_add_test.dart` — keep resolving.
library;

export 'manual_add_form.dart';
export 'manual_directory.dart';
export 'manual_inbox.dart';
