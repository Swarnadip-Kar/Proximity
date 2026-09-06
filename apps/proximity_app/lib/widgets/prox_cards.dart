// Shared cards + list tiles. Every course/session/student/attendance row
// in the app is one of these — no screen hand-rolls its own Card+ListTile
// with bespoke padding, shape, or entrance timing.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../design/tokens.dart';
import 'prox_motion.dart';

/// Standard content card. Flat by design (border, no shadow) so live
/// screens with camera/BLE stay cheap to composite.
class ProxCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  const ProxCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(ProxSpacing.lg),
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final card = Card(
      child: Padding(padding: padding, child: child),
    );
    if (onTap == null) return card;
    return InkWell(
      borderRadius: ProxRadii.cardRadius,
      onTap: onTap,
      child: card,
    );
  }
}

/// One tappable row: leading icon/dot, title, subtitle, trailing. Replaces
/// the dozen bespoke ListTile-in-Card copies across course/session/student
/// lists. Entrance stagger is opt-in via [staggerIndex] (null = no delay).
class ProxListTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final int? staggerIndex;
  final Key? tileKey;

  const ProxListTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.staggerIndex,
    this.tileKey,
  });

  @override
  Widget build(BuildContext context) {
    final tile = Card(
      child: ListTile(
        key: tileKey,
        leading: leading,
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle!),
        trailing: trailing,
        onTap: onTap,
        shape: RoundedRectangleBorder(
          borderRadius: ProxRadii.cardRadius,
        ),
      ),
    );
    final i = staggerIndex;
    if (i == null || ProxMotion.reduced(context)) return tile;
    return ProxFadeSlideIn(
      delay: Duration(
        milliseconds: (i * ProxDurations.staggerStep.inMilliseconds)
            .clamp(0, ProxDurations.staggerCap.inMilliseconds),
      ),
      child: tile,
    );
  }
}

/// Small colored dot for live/presence indication. Pulses only when
/// [pulse] is true (professor LIVE, student BLE-active) — static otherwise
/// so idle lists stay calm and cheap.
///
/// Implementation note: the pulse is timer-driven (periodic toggle +
/// implicit fade), never an infinite ticker — so widget tests using
/// `pumpAndSettle` still settle and the dot costs ~1 rebuild per 800ms.
class ProxDot extends StatefulWidget {
  final Color color;
  final bool pulse;
  final double size;

  const ProxDot({
    super.key,
    required this.color,
    this.pulse = false,
    this.size = 10,
  });

  @override
  State<ProxDot> createState() => _ProxDotState();
}

class _ProxDotState extends State<ProxDot> {
  static const _period = Duration(milliseconds: 800);
  Timer? _timer;
  var _dim = false;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(ProxDot old) {
    super.didUpdateWidget(old);
    if (widget.pulse != old.pulse) {
      _timer?.cancel();
      _timer = null;
      _dim = false;
      _arm();
    }
  }

  void _arm() {
    if (!widget.pulse) return;
    _timer = Timer.periodic(_period, (_) {
      if (!mounted) return;
      setState(() => _dim = !_dim);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
    );
    if (!widget.pulse || ProxMotion.reduced(context)) return dot;
    return AnimatedOpacity(
      duration: _period,
      curve: Curves.easeInOut,
      opacity: _dim ? 0.35 : 1.0,
      child: dot,
    );
  }
}
