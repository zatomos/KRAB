import 'package:flutter/material.dart';

import 'package:krab/themes/global_theme_data.dart';

class RoundedInputField extends StatelessWidget {
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String hintText;
  final String? errorText;
  final bool obscureText;
  final bool capitalizeSentences;
  final int? maxLength;
  final double borderRadius;
  final Icon? icon;
  final Widget? suffixIcon;
  final EdgeInsetsGeometry contentPadding;
  final Iterable<String>? autofillHints;
  final TextInputType? keyboardType;

  const RoundedInputField({
    super.key,
    this.controller,
    this.focusNode,
    this.hintText = '',
    this.errorText,
    this.obscureText = false,
    this.capitalizeSentences = false,
    this.maxLength,
    this.borderRadius = 12.0,
    this.icon,
    this.suffixIcon,
    this.contentPadding =
        const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
    this.autofillHints,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        obscureText: obscureText,
        autofillHints: autofillHints,
        keyboardType: keyboardType,
        textCapitalization: capitalizeSentences
            ? TextCapitalization.sentences
            : TextCapitalization.none,
        maxLength: maxLength,
        decoration: InputDecoration(
          icon: icon,
          labelText: hintText,
          errorText: errorText,
          suffixIcon: suffixIcon,
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
