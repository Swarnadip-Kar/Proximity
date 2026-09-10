// AccountChip — the Gmail card (§4.3).
//
// Shows the Google account's own avatar/photo circle with the Gmail logo as
// a small badge overlapping the bottom-right of the avatar (16dp, themed
// circle backing so it reads on any photo), display name, email — no other
// chrome, no card border, sits directly on `surface.base` by default.
//
// At large size on the Account menu header (§5.1) ONLY, it sits on a subtle
// `gradient.brand` wash (see [largeHeader]) — every other placement stays
// flat. This is a "you've arrived at your own page" accent, not a
// component default.
//
// Identity display only, not a button. The photo is the Google account's
// own OAuth profile photo ([photoUrl]) — ordinary account metadata, NOT
// `face_verification` output. There is no code path here that reads the
// face gallery for display. A failed image load falls back to the
// deterministic initials avatar (§10.1), never a broken-image icon.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import 'student_card.dart' show studentInitials;

export 'student_card.dart' show studentInitials;

/// Gmail identity chip. Flat by default; gradient wash only via
/// [largeHeader] on the Account menu header.
class AccountChip extends StatelessWidget {
  /// Google display name.
  final String displayName;

  /// Google account email.
  final String email;

  /// Google OAuth profile photo URL. Null/empty renders the initials
  /// avatar. Never a face-gallery path.
  final String? photoUrl;

  /// Account-menu-header mode: 56dp avatar + subtle `gradient.brand` wash
  /// behind the chip (§2.5, §5.1). Everywhere else stays flat.
  final bool largeHeader;

  const AccountChip({
    super.key,
    required this.displayName,
    required this.email,
    this.photoUrl,
    this.largeHeader = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final radius = largeHeader ? 28.0 : 20.0;

    final content = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: ProxSpacing.screenMargin,
        vertical: largeHeader ? ProxSpacing.lg : ProxSpacing.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _Avatar(
            displayName: displayName,
            photoUrl: photoUrl,
            radius: radius,
          ),
          const SizedBox(width: ProxSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  displayName,
                  style: largeHeader
                      ? ProxType.title(color: c.contentPrimary)
                      : ProxType.body(color: c.contentPrimary),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
                const SizedBox(height: 2),
                Text(
                  email,
                  style: ProxType.caption(color: c.contentSecondary),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ],
            ),
          ),
        ],
      ),
    );

    if (!largeHeader) return content;

    // The one wash this component is allowed (§2.5): gradient.brand behind
    // the Account header only, subtle enough that contentPrimary on the
    // effective surface still passes contrast (see ProximityColors docs).
    // Token colors only — the opacity scales the token gradient, it never
    // hand-authors a new one.
    return Stack(
      children: [
        Positioned.fill(
          child: Opacity(
            opacity: 0.14,
            child: DecoratedBox(
              decoration: BoxDecoration(gradient: c.gradientBrand),
            ),
          ),
        ),
        content,
      ],
    );
  }
}

class _Avatar extends StatelessWidget {
  final String displayName;
  final String? photoUrl;
  final double radius;

  const _Avatar({
    required this.displayName,
    required this.photoUrl,
    required this.radius,
  });

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final url = photoUrl?.trim() ?? '';

    Widget initials() => Container(
          width: radius * 2,
          height: radius * 2,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: c.accentBrand.withValues(alpha: 0.15),
          ),
          alignment: Alignment.center,
          child: Text(
            studentInitials(displayName),
            style: ProxType.label(color: c.accentBrand),
            overflow: TextOverflow.clip,
          ),
        );

    final photo = url.isEmpty
        ? initials()
        : ClipOval(
            child: Image.network(
              url,
              width: radius * 2,
              height: radius * 2,
              fit: BoxFit.cover,
              // §10.1: failed loads fall back to initials, never a
              // broken-image icon or blank circle.
              errorBuilder: (_, __, ___) => initials(),
            ),
          );

    return SizedBox(
      width: radius * 2 + 2,
      height: radius * 2 + 2,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          photo,
          // Gmail badge: 16dp, overlapping the avatar bottom-right. The
          // backing is the raised-surface token (reads on any photo in both
          // themes) rather than a literal white circle, per the
          // dark/light-parity constraint — same job, theme-aware.
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: c.surfaceRaised,
                border: Border.all(color: c.divider),
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.mail,
                size: 10,
                color: c.accentBrand,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
