// Cloud sync: professor session backup + student device binding + roles.
// Firestore collections (see firestore.rules):
//   users/{uid}: {email, name, roles[prof|student], displayName, lastMode,
//     updatedAt} — one doc per Firebase uid; the SAME Gmail can hold BOTH
//     roles (prof multi-device, student single-device). lastMode is the last
//     used mode (landing + relaunch default). Local history stays source of
//     truth for sessions.
//   studentDevices/{emailLower}: {email, uid, pkHex, installId, name, roll,
//     modelVer, platform, createdAt/lastMoveAt/lastSeenAt/updatedAtMillis,
//     moveCount} — one enrolled student device per Gmail. Same-device writes
//     (pkHex or installId unchanged) are always allowed; moves to a different
//     device need a 30-day cooldown (request.time - lastMoveAtMillis > 30d)
//     unless the doc predates timestamps (one migration move). Clients claim
//     via a transaction so racing devices resolve to exactly one winner.
//     NO reset path exists by design: professor registration is
//     self-asserted this phase, so any reset permission would let a student
//     self-reset around the cooldown. Genuine loss waits out the week;
//     manual attendance covers the gap. Face photos are NEVER written
//     here — only the device public key + install id. Face-derived MATH
//     (one quantized face-code per Gmail, protocol face_print.dart) IS
//     written to facePrints/{emailLower} in the claim transaction for the
//     same-face duplicate check — privacy flag in that file applies.
//   studentDirectory/{emailLower}: {email, name, roll, nameLower,
//     updatedAtMillis} — minimal professor-searchable directory, maintained
//     by the claim transaction. Professors (role-gated) prefix-search it to
//     add students to records; students read only their own doc. NOTE: the
//     prof gate is advisory until professor roles are institute-verified —
//     any self-registered prof can list it (emails/names/rolls only).
//   deviceInstalls/{installId}: {email, pkHex, updatedAtMillis} — one
//     student Gmail per app install. Stops the same phone (incl. app clones,
//     which get their own installId) from holding two student enrollments.
//   classSessions/{sessionId}: {courseId, courseName, classLabel, profUid,
//     profEmail, profName, dateIso, timestampIso, startIso, windows, names,
//     rolls, studentEmails[], updatedAt}
//   classSessions/{sessionId}: {courseId, courseName, classLabel, profUid,
//     profEmail, profName, dateIso, timestampIso, startIso, windows, names,
//     rolls, studentEmails[], updatedAt}
// Local history stays the offline source of truth; cloud is the sync copy.
// Firestore offline persistence queues writes automatically — first sign-in
// merges both ways, later changes push on save and pull on open/refresh.
//
// M6 sync refactor: implementation split into core/sync/ (roles, claim,
// sessions, directory, queue, backends). This file is the compatibility
// barrel — same public class/method names, so callers don't change.
library;

export 'sync/sync.dart';
