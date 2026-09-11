// Host preview card: EXACTLY what a joining student sees in the waiting
// room — host Gmail photo (letter-initial disc fallback) + display name +
// email + org. Shared by the student waiting room AND the professor setup
// tab ("This is what students will see"), so the preview can never drift
// from reality: same widget, same fallback contract. Photo is ordinary
// account metadata, shown only when the professor opts in per course.
// Title is the display name, falling back to the email when unconfigured
// (never blank while any identity is known); the second line carries the
// email (unless it already IS the title) plus the org, omitted entirely
// when unknown (no dangling separators). No 'Hosted by' prefix (adds no
// information — the card IS the host); no address ever renders twice.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import 'prox_cards.dart';

class HostPreviewCard extends StatelessWidget {
  final String displayName;

  /// Professor email: title fallback when the display name is unconfigured
  /// + second line (deduped — never rendered twice). Callers must always
  /// pass what they know so an unconfigured host still shows an honest,
  /// useful card instead of a bare org domain.
  final String email;
  final String org;
  final String photoUrl;

  const HostPreviewCard({
    super.key,
    required this.displayName,
    this.email = '',
    this.org = '',
    this.photoUrl = '',
  });

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    final url = photoUrl.trim();
    final mail = email.trim();
    // Title: display name first, email when unconfigured (an unconfigured
    // host must still show something honest — never a bare org domain and
    // never blank while any identity is known).
    final name = displayName.trim().isNotEmpty ? displayName.trim() : mail;
    // Letter fallback (never blank, never a bare symbol): first
    // alphanumeric of the resolved title, else '?'.
    var initial = '?';
    for (final ch in name.characters) {
      if (RegExp('[A-Za-z0-9]').hasMatch(ch)) {
        initial = ch.toUpperCase();
        break;
      }
    }

    Widget initials() => Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: c.accentBrand.withValues(alpha: 0.12),
          ),
          alignment: Alignment.center,
          child: Text(
            initial,
            style: ProxType.title(color: c.accentBrand),
          ),
        );

    final avatar = url.isEmpty
        ? initials()
        : ClipOval(
            child: Image.network(
              url,
              width: 56,
              height: 56,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => initials(),
              frameBuilder: (context, child, frame, _) {
                if (frame == null) return initials();
                return child;
              },
            ),
          );

    // No 'Hosted by' prefix: the card already IS the host, so the
    // prefix adds no information. Email on its own line (unless it
    // already IS the title), org on the next line — each omitted when
    // unknown (no dangling separators, no blank lines, no address
    // rendered twice). The prof setup preview (same widget, same mapping)
    // mirrors exactly what students see. When title and lines are all
    // empty the card renders nothing.
    final title = name;
    final emailLine =
        (mail.isNotEmpty && mail.toLowerCase() != title.toLowerCase())
            ? mail
            : '';
    final orgLine = org.trim();
    if (title.isEmpty && emailLine.isEmpty && orgLine.isEmpty) {
      return const SizedBox.shrink();
    }

    return ProxCard(
      child: Row(
        children: [
          avatar,
          const SizedBox(width: ProxSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (title.isNotEmpty)
                  Text(
                    title,
                    style: ProxType.body(color: c.contentPrimary),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                if (title.isNotEmpty && emailLine.isNotEmpty)
                  const SizedBox(height: 2),
                if (emailLine.isNotEmpty)
                  Text(
                    emailLine,
                    style: ProxType.caption(color: c.contentSecondary),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                if (orgLine.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    orgLine,
                    style: ProxType.caption(color: c.contentSecondary),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
