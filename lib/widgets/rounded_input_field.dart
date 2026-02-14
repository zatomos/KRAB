import 'package:flutter/material.dart';

import 'package:krab/themes/global_theme_data.dart';

class RoundedInputField extends StatelessWidget {
  final TextEditingController? controller;
  final String hintText;
  final String? errorText;
  final bool obscureText;
  final bool capitalizeSentences;
  final int? maxLength;
  final double borderRadius;
  final Icon? icon;
  final EdgeInsetsGeometry contentPadding;

  const RoundedInputField({
    super.key,
    this.controller,
    this.hintText = '',
    this.errorText,
    this.obscureText = false,
    this.capitalizeSentences = false,
    this.maxLength,
    this.borderRadius = 12.0,
    this.icon,
    this.contentPadding =
        const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
      child: TextField(
        controller: controller,
        obscureText: obscureText,
        textCapitalization: capitalizeSentences
            ? TextCapitalization.sentences
            : TextCapitalization.none,
        maxLength: maxLength,
        decoration: InputDecoration(
          icon: icon,
          labelText: hintText,
          errorText: errorText,
          contentPadding: contentPadding,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(borderRadius),
          ),
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(
                color: GlobalThemeData.darkColorScheme.onSurface, width: 1.5),
            borderRadius: BorderRadius.circular(borderRadius),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(
                color: GlobalThemeData.darkColorScheme.primary, width: 2.5),
            borderRadius: BorderRadius.circular(borderRadius),
          ),
        ),
      ),
    );
  }
}
