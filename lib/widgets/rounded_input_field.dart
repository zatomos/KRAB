import 'package:flutter/material.dart';


class RoundedInputField extends StatelessWidget {
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String hintText;
  final String? errorText;
  final bool obscureText;
  final bool capitalizeSentences;
  final int? maxLength;
  final int? maxLines;
  final int? minLines;
  final double borderRadius;
  final Icon? icon;
  final Widget? suffixIcon;
  final EdgeInsetsGeometry contentPadding;
  final Iterable<String>? autofillHints;
  final TextInputType? keyboardType;
  final bool enabled;

  const RoundedInputField({
    super.key,
    this.controller,
    this.focusNode,
    this.hintText = '',
    this.errorText,
    this.obscureText = false,
    this.capitalizeSentences = false,
    this.maxLength,
    this.maxLines = 1,
    this.minLines,
    this.borderRadius = 12.0,
    this.icon,
    this.suffixIcon,
    this.contentPadding =
        const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
    this.autofillHints,
    this.keyboardType,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        enabled: enabled,
        obscureText: obscureText,
        autofillHints: autofillHints,
        keyboardType: keyboardType,
        textCapitalization: capitalizeSentences
            ? TextCapitalization.sentences
            : TextCapitalization.none,
        maxLength: maxLength,
        maxLines: obscureText ? 1 : maxLines,
        minLines: minLines,
        // Enforce the limit without showing the counter.
        buildCounter: (_,
                {required int currentLength,
                required bool isFocused,
                int? maxLength}) =>
            null,
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
                color: Theme.of(context).colorScheme.onSurface, width: 1.5),
            borderRadius: BorderRadius.circular(borderRadius),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(
                color: Theme.of(context).colorScheme.primary, width: 2.5),
            borderRadius: BorderRadius.circular(borderRadius),
          ),
        ),
      ),
    );
  }
}
