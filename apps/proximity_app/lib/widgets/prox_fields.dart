// Shared text fields: one input language (label, error, 48dp rhythm).
//
// Wraps the tokenized InputDecorationTheme — callers pass label/hint and
// behavior, never raw decorations.
library;

import 'package:flutter/material.dart';

/// Single-line text field on Prox tokens.
class ProxTextField extends StatelessWidget {
  final TextEditingController controller;
  final String? labelText;
  final String? hintText;
  final TextInputAction textInputAction;
  final TextInputType? keyboardType;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;

  const ProxTextField({
    super.key,
    required this.controller,
    this.labelText,
    this.hintText,
    this.textInputAction = TextInputAction.done,
    this.keyboardType,
    this.autofocus = false,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: labelText,
        hintText: hintText,
      ),
      textInputAction: textInputAction,
      keyboardType: keyboardType,
      autofocus: autofocus,
      onSubmitted: onSubmitted,
    );
  }
}
