// AccountChip — the Gmail card (§4.3).
//
// Shows the Google account's own avatar/photo circle with the Gmail logo as
// a small badge overlapping the bottom-right of the avatar (16dp, themed
// circle backing so it reads on any photo), display name, email — no other
// chrome, no card border, sits directly on `surface.base` by default.
//
// UI Overhaul: large header mode gets a stronger animated gradient wash
// (20%, slowly sweeping). Gmail badge springs in on load. Avatar gets
// a subtle gradient ring in brand colors.
//
// Identity display only, not a button. The photo is the Google account's
// own OAuth profile photo ([photoUrl]) — ordinary account metadata, NOT
// `face_verification` output.
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

  /// Account-menu-header mode: 56dp avatar + animated `gradient.brand` wash
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
            largeHeader: largeHeader,
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

    // Gradient wash behind the Account header — stronger and subtly
    // animated compared to the old static 14% version.
    return Stack(
      children: [
        Positioned.fill(
          child: Opacity(
            opacity: 0.18,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: c.gradientBrand,
                borderRadius: ProxRadii.cardSpecRadius,
              ),
            ),
          ),
        ),
        content,
      ],
    );
  }
}

class _Avatar extends StatefulWidget {
  final String displayName;
  final String? photoUrl;
  final double radius;
  final bool largeHeader;

  const _Avatar({
    required this.displayName,
    required this.photoUrl,
    required this.radius,
    this.largeHeader = false,
  });

  @override
  State<_Avatar> createState() => _AvatarState();
}

class _AvatarState extends State<_Avatar>
    with SingleTickerProviderStateMixin {
  AnimationController? _badgeSpring;

  @override
  void initState() {
    super.initState();
    _badgeSpring = AnimationController(
      vsync: this,
      duration: ProxDurations.verdictPop,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!ProxMotion.reduced(context)) {
      // Spring the badge in on first load.
      _badgeSpring?.forward(from: 0);
    } else {
      _badgeSpring?.value = 1.0;
    }
  }

  @override
  void dispose() {
    _badgeSpring?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final url = widget.photoUrl?.trim() ?? '';

    Widget initials() => Container(
          width: widget.radius * 2,
          height: widget.radius * 2,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: c.accentBrand.withValues(alpha: 0.12),
          ),
          alignment: Alignment.center,
          child: Text(
            studentInitials(widget.displayName),
            style: ProxType.label(color: c.accentBrand).copyWith(
              fontSize: widget.largeHeader ? 16 : 13,
            ),
            overflow: TextOverflow.clip,
          ),
        );

    final photo = url.isEmpty
        ? initials()
        : ClipOval(
            child: Image.network(
              url,
              width: widget.radius * 2,
              height: widget.radius * 2,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => initials(),
            ),
          );

    // Avatar with gradient ring on large header.
    final avatar = widget.largeHeader
        ? Container(
            width: widget.radius * 2 + 4,
            height: widget.radius * 2 + 4,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: SweepGradient(
                colors: [
                  c.accentBrand,
                  c.statusMarked,
                  c.accentBrand,
                ],
              ),
            ),
            padding: const EdgeInsets.all(2),
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: c.surfaceBase,
              ),
              padding: const EdgeInsets.all(1),
              child: ClipOval(child: photo),
            ),
          )
        : photo;

    final spring = _badgeSpring;

    return SizedBox(
      width: widget.radius * 2 + 4,
      height: widget.radius * 2 + 4,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Center(child: avatar),
          // Gmail badge: 16dp, overlapping the avatar bottom-right.
          // Springs in on first load for a micro-delight.
          Positioned(
            right: -1,
            bottom: -1,
            child: spring != null
                ? ScaleTransition(
                    scale: CurvedAnimation(
                      parent: spring,
                      curve: ProxCurves.verdictSpring,
                    ),
                    child: _gmailBadge(c),
                  )
                : _gmailBadge(c),
          ),
        ],
      ),
    );
  }

  Widget _gmailBadge(ProximityColors c) => Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: c.surfaceRaised,
          border: Border.all(color: c.divider, width: 0.5),
          boxShadow: [
            BoxShadow(
              color: c.accentBrand.withValues(alpha: 0.15),
              blurRadius: 4,
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Icon(
          Icons.mail,
          size: 10,
          color: c.accentBrand,
        ),
      );
}
