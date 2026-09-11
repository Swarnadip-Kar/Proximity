// Manual attendance module barrel (§4.8).
//
// Professor manual attendance (`live/<course>/inbox` approve/reject plus
// the manual-add form on `live/<course>/add`) is one implementation
// imported by both routes — not duplicated screen-local UI. The inbox
// carries its own `SelectionScope` instance per list (see
// `manual_inbox.dart`); the form's search/queue orchestration lives in
// `manual_directory.dart`. Consumed by the live direct-add/inbox sections,
// the saved-session editor, and `manual_add_test.dart` — one import,
// same form.
library;

export 'manual_add_form.dart';
export 'manual_directory.dart';
export 'manual_inbox.dart';
