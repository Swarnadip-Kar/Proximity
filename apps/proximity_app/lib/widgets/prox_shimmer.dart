// Skeleton / shimmer loading placeholders. Replace bare spinners with
// content-shaped loading states: card, row, and block variants. A single
// AnimationController per shimmer tree keeps all gradients in sync.
//
// Reduce-motion safe: under `ProxMotion.reduced` the gradient stays static
// (50% phase — mid-sweep highlight) so the placeholder reads as "loading"
// without motion.
library;

import 'package:flutter/material.dart';

import '../design/tokens.dart';

/// Animated shimmer gradient sweep. Wrap one or more [ProxShimmerBlock],
/// [ProxShimmerRow], or [ProxShimmerCard] children inside this to share a
/// single animation controller.
class ProxShimmerHost extends StatefulWidget {
  final Widget child;
  const ProxShimmerHost({super.key, required this.child});

  @override
  State<ProxShimmerHost> createState() => _ProxShimmerHostState();
}

class _ProxShimmerHostState extends State<ProxShimmerHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: ProxDurations.shimmer,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!ProxMotion.reduced(context)) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _ShimmerScope(controller: _controller, child: widget.child);
  }
}

class _ShimmerScope extends InheritedWidget {
  final AnimationController controller;
  const _ShimmerScope({required this.controller, required super.child});

  static AnimationController? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ShimmerScope>()?.controller;

  @override
  bool updateShouldNotify(_ShimmerScope old) => controller != old.controller;
}

/// Rectangular shimmer placeholder block.
class ProxShimmerBlock extends StatelessWidget {
  final double width;
  final double height;
  final double borderRadius;

  const ProxShimmerBlock({
    super.key,
    this.width = double.infinity,
    this.height = 16,
    this.borderRadius = 8,
  });

  @override
  Widget build(BuildContext context) {
    final controller = _ShimmerScope.of(context);
    final baseColor = ProxShimmer.base(context);
    final highlightColor = ProxShimmer.highlight(context);

    if (controller == null || ProxMotion.reduced(context)) {
      return Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: baseColor,
          borderRadius: BorderRadius.circular(borderRadius),
        ),
      );
    }

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(borderRadius),
            gradient: LinearGradient(
              begin: Alignment(-1.0 + 2.0 * controller.value, 0),
              end: Alignment(1.0 + 2.0 * controller.value, 0),
              colors: [baseColor, highlightColor, baseColor],
              stops: const [0.0, 0.5, 1.0],
            ),
          ),
        );
      },
    );
  }
}

/// List-tile shaped shimmer placeholder: avatar circle + two text lines.
class ProxShimmerRow extends StatelessWidget {
  const ProxShimmerRow({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: ProxSpacing.sm),
      child: Row(
        children: [
          ProxShimmerBlock(
            width: 40,
            height: 40,
            borderRadius: ProxRadii.chip,
          ),
          const SizedBox(width: ProxSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const ProxShimmerBlock(height: 14, width: 160),
                const SizedBox(height: ProxSpacing.sm),
                ProxShimmerBlock(
                  height: 10,
                  width: 100,
                  borderRadius: 5,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Card-shaped shimmer placeholder with internal rows.
class ProxShimmerCard extends StatelessWidget {
  final int lines;
  const ProxShimmerCard({super.key, this.lines = 3});

  @override
  Widget build(BuildContext context) {
    final c = ProximityColors.of(context);
    return Container(
      padding: const EdgeInsets.all(ProxSpacing.lg),
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        borderRadius: ProxRadii.cardSpecRadius,
        border: Border.all(color: c.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < lines; i++) ...[
            ProxShimmerBlock(
              height: i == 0 ? 16 : 12,
              width: i == lines - 1 ? 120 : double.infinity,
            ),
            if (i < lines - 1) const SizedBox(height: ProxSpacing.md),
          ],
        ],
      ),
    );
  }
}
