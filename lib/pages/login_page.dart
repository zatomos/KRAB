import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/services/supabase.dart';
import 'package:krab/services/home_widget_updater.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/widgets/floating_snack_bar.dart';
import 'package:krab/widgets/rounded_input_field.dart';
import 'package:krab/widgets/soft_button.dart';
import 'package:krab/pages/camera_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  LoginPageState createState() => LoginPageState();
}

class LoginPageState extends State<LoginPage> {
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _passwordConfirmController = TextEditingController();
  final _forgotPasswordController = TextEditingController();

  String _localizeAuthError(String? error) {
    switch (error) {
      case 'invalid_email_or_password':
        return context.l10n.invalid_email_or_password;
      case 'email_already_exists':
        return context.l10n.email_already_exists;
      case 'password_too_weak':
        return context.l10n.password_too_weak;
      default:
        return error ?? '';
    }
  }

  bool _isSigningUp = false;
  bool _isLoading = false;
  bool _showPassword = false;
  bool _showConfirmPassword = false;
  String? _errorMessage;

  @override
  void dispose() {
    _usernameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _passwordConfirmController.dispose();
    _forgotPasswordController.dispose();
    super.dispose();
  }

  Future<void> _signUp() async {
    if (_isLoading) return;
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final passwordConfirm = _passwordConfirmController.text;
    final username = _usernameController.text.trim();

    if (email.isEmpty || password.isEmpty || username.isEmpty) {
      setState(() => _errorMessage = context.l10n.fill_in_all_fields);
      return;
    }
    if (password != passwordConfirm) {
      setState(() => _errorMessage = context.l10n.passwords_do_not_match);
      return;
    }

    setState(() { _isLoading = true; _errorMessage = null; });
    final response = await registerUser(username, email, password);
    if (!mounted) return;
    if (response.success) {
      // Cache groups so the widget configure screen can offer a group filter
      unawaited(cacheUserGroupsForWidget());
      TextInput.finishAutofillContext(shouldSave: true);
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => const CameraPage()),
      );
      showSnackBar(context.l10n.register_user_success);
    } else {
      setState(() { _isLoading = false; _errorMessage = _localizeAuthError(response.error); });
    }
  }

  Future<void> _logIn() async {
    if (_isLoading) return;
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() => _errorMessage = context.l10n.fill_in_all_fields);
      return;
    }

    setState(() { _isLoading = true; _errorMessage = null; });
    final response = await loginUser(email, password);
    if (!mounted) return;
    if (response.success) {
      // Cache groups so the widget configure screen can offer a group filter
      unawaited(cacheUserGroupsForWidget());
      TextInput.finishAutofillContext(shouldSave: true);
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => const CameraPage()),
      );
    } else {
      setState(() { _isLoading = false; _errorMessage = _localizeAuthError(response.error); });
    }
  }

  Future<void> _forgotPasswordDialog() async {
    _forgotPasswordController.clear();
    return showDialog(
      context: context,
      builder: (context) {
        String? dialogError;
        bool sending = false;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(context.l10n.forgot_password),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(context.l10n.enter_email_account),
                  const SizedBox(height: 16),
                  RoundedInputField(
                    controller: _forgotPasswordController,
                    hintText: context.l10n.email,
                    errorText: dialogError,
                    icon: const Icon(Icons.email_rounded),
                  ),
                ],
              ),
              actions: [
                SoftButton(
                  label: context.l10n.cancel,
                  onPressed: () => Navigator.pop(context),
                  color: GlobalThemeData.darkColorScheme.onSurfaceVariant,
                ),
                if (sending)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  SoftButton(
                    label: context.l10n.send,
                    onPressed: () async {
                      final email = _forgotPasswordController.text.trim();
                      if (email.isEmpty) {
                        setDialogState(() => dialogError = context.l10n.fill_in_all_fields);
                        return;
                      }
                      setDialogState(() { sending = true; dialogError = null; });
                      final response = await sendPasswordResetEmail(email);
                      if (!context.mounted) return;
                      if (response.success) {
                        Navigator.pop(context);
                        showSnackBar(context.l10n.password_email_sent);
                      } else {
                        setDialogState(() {
                          sending = false;
                          dialogError = _localizeAuthError(response.error);
                        });
                      }
                    },
                    color: GlobalThemeData.darkColorScheme.primary,
                    icon: Icons.send_rounded,
                  ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 20),
              _buildLogo(),
              const SizedBox(height: 40),
              Text(
                _isSigningUp ? context.l10n.sign_up : context.l10n.log_in,
                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 28),
              AutofillGroup(
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeInOut,
                  child: Column(
                    children: [
                      if (_isSigningUp)
                        RoundedInputField(
                          controller: _usernameController,
                          hintText: context.l10n.username,
                          icon: const Icon(Icons.person_rounded),
                          autofillHints: const [AutofillHints.username],
                        ),
                      RoundedInputField(
                        controller: _emailController,
                        hintText: context.l10n.email,
                        icon: const Icon(Icons.email_rounded),
                        autofillHints: const [AutofillHints.email],
                      ),
                      RoundedInputField(
                        controller: _passwordController,
                        hintText: context.l10n.password,
                        obscureText: !_showPassword,
                        icon: const Icon(Icons.lock_rounded),
                        autofillHints: _isSigningUp
                            ? const [AutofillHints.newPassword]
                            : const [AutofillHints.password],
                        suffixIcon: IconButton(
                          icon: Icon(_showPassword ? Icons.visibility_off_rounded : Icons.visibility_rounded),
                          onPressed: () => setState(() => _showPassword = !_showPassword),
                        ),
                      ),
                      if (_isSigningUp)
                        RoundedInputField(
                          controller: _passwordConfirmController,
                          hintText: context.l10n.confirm_password,
                          obscureText: !_showConfirmPassword,
                          icon: const Icon(Icons.check_rounded),
                          autofillHints: const [AutofillHints.newPassword],
                          suffixIcon: IconButton(
                            icon: Icon(_showConfirmPassword ? Icons.visibility_off_rounded : Icons.visibility_rounded),
                            onPressed: () => setState(() => _showConfirmPassword = !_showConfirmPassword),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (_errorMessage != null) _buildError(),
              const SizedBox(height: 20),
              _buildButton(),
              if (!_isSigningUp)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: _forgotPasswordDialog,
                    child: Text(context.l10n.forgot_password_question),
                  ),
                ),
              const SizedBox(height: 8),
              Center(
                child: TextButton(
                  onPressed: () {
                    setState(() {
                      _isSigningUp = !_isSigningUp;
                      _errorMessage = null;
                      _passwordController.clear();
                      if (!_isSigningUp) _usernameController.clear();
                    });
                  },
                  child: Text(
                    _isSigningUp
                        ? context.l10n.already_have_account
                        : context.l10n.dont_have_account,
                  ),
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLogo() {
    return Column(
      children: [
        Image.asset('logo/krab_logo.png', width: 120, height: 120),
        const Text(
          'KRAB',
          style: TextStyle(fontSize: 40, fontWeight: FontWeight.w900, letterSpacing: 2),
        ),
      ],
    );
  }

  Widget _buildError() {
    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _errorMessage!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildButton() {
    return SizedBox(
      height: 52,
      child: ElevatedButton(
        onPressed: _isLoading ? null : (_isSigningUp ? _signUp : _logIn),
        style: ElevatedButton.styleFrom(
          backgroundColor: GlobalThemeData.darkColorScheme.primary,
          disabledBackgroundColor: GlobalThemeData.darkColorScheme.primary.withValues(alpha: 0.6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: _isLoading
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
              )
            : Text(
                _isSigningUp ? context.l10n.sign_up : context.l10n.log_in,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
      ),
    );
  }
}
