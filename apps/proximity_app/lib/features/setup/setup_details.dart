// Setup-scoped DetailsExpander (§4.7).
//
// Same widget, same collapsed-by-default contract — plus a theme
// fallback: production always builds under the app themes (extension
// present → pure passthrough, zero visual change), while older tests
// pumping plain MaterialApp get ProximityColors.light() so the strict
// ProximityColors.of inside DetailsExpander never fails fast there.
library;

import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../widgets/details_expander.dart';

class SetupDetails extends StatelessWidget {
  final String title;
  final Widget child;

  const SetupDetails({super.key, required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).extension<ProximityColors>() != null) {
      return DetailsExpander(title: title, child: child);
    }
    return Theme(
      data: Theme.of(context).copyWith(
        extensions: [
          ...Theme.of(context).extensions.values,
          const ProximityColors.light(),
        ],
      ),
      child: DetailsExpander(title: title, child: child),
    );
  }
}
