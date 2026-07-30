import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/services/home_widget_updater.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/widgets/auth/auth_error_box.dart';
import 'package:krab/widgets/auth/auth_scaffold.dart';
import 'package:krab/widgets/floating_snack_bar.dart';
import 'package:krab/widgets/rectangle_button.dart';
import 'package:krab/widgets/rounded_input_field.dart';
import 'package:krab/widgets/server_label.dart';
import 'package:krab/widgets/soft_button.dart';
import 'package:krab/pages/camera_page.dart';
import 'package:krab/services/instance/instances.dart';

class LoginPage extends StatefulWidget {
  /// The server being signed into.
  final KrabInstance instance;

  /// Whether signing in should take over the app. False when the user is
  /// adding a server from the servers screen, where success means going back to
  /// the list rather than jumping into a camera on a different account.
  final bool enterAppOnSuccess;

  const LoginPage({
    super.key,
    required this.instance,
    this.enterAppOnSuccess = true,
  });

  @override
  LoginPageState createState() => LoginPageState();
}

/// How long the green ring is held before the screen moves on.
const Duration _successHold = Duration(seconds: 1);

class LoginPageState extends State<LoginPage> {
  KrabApi get _api => widget.instance.api;

  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _passwordConfirmController = TextEditingController();
  final _forgotPasswordController = TextEditingController();

  String _localizeAuthError(String? error) {
    switch (error) {
      case 'network_error':
        return context.l10n.error_network;
      case 'auth_error':
        return context.l10n.error_server;
      case 'invalid_email_or_password':
        return context.l10n.invalid_email_or_password;
      case 'email_already_exists':
        return context.l10n.email_already_exists;
      case 'password_too_weak':
        return context.l10n.password_too_weak;
      case 'email_not_confirmed':
        return context.l10n.email_not_confirmed;
      default:
        return error ?? '';
    }
  }

  /// Shown under the error when a login is blocked by an unconfirmed email, so
  /// the user can trigger a fresh confirmation link.
  bool _showResendConfirmation = false;

  Future<void> _resendConfirmation() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) return;
    final res = await _api.resendConfirmationEmail(email);
    if (!mounted) return;
    if (res.success) {
      showSnackBar(context.l10n.confirmation_email_resent);
    } else {
      showSnackBar(_localizeAuthError(res.error), tone: SnackTone.failure);
    }
  }

  bool _isSigningUp = false;
  bool _isLoading = false;
  bool _success = false;
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

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    final response = await _api.registerUser(username, email, password);
    if (!mounted) return;
    if (!response.success) {
      setState(() {
        _isLoading = false;
        _errorMessage = _localizeAuthError(response.error);
      });
      return;
    }

    // data == false means a confirmation email was sent and the account isn't
    // logged in yet. Send the user back to the login screen to confirm first.
    if (response.data == false) {
      TextInput.finishAutofillContext(shouldSave: true);
      setState(() {
        _isLoading = false;
        _isSigningUp = false;
        _passwordController.clear();
        _passwordConfirmController.clear();
      });
      showSnackBar(context.l10n.verification_email_sent(email),
          tone: SnackTone.success);
      return;
    }

    // Auto-confirm path: already logged in.
    showSnackBar(context.l10n.register_user_success, tone: SnackTone.success);
    await _enterApp();
  }

  /// Leave the login screen, now that there's a session: into the app when this
  /// is the way in, or back to wherever asked for the sign-in.
  Future<void> _enterApp() async {
    unawaited(cacheUserGroupsForWidget());
    TextInput.finishAutofillContext(shouldSave: true);

    setState(() => _success = true);
    await Future.delayed(_successHold);
    if (!mounted) return;

    if (!widget.enterAppOnSuccess) {
      Navigator.of(context).pop(true);
      return;
    }
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const CameraPage()),
    );
  }

  Future<void> _logIn() async {
    if (_isLoading) return;
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() => _errorMessage = context.l10n.fill_in_all_fields);
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _showResendConfirmation = false;
    });
    final response = await _api.loginUser(email, password);
    if (!mounted) return;
    if (response.success) {
      await _enterApp();
    } else {
      setState(() {
        _isLoading = false;
        _errorMessage = _localizeAuthError(response.error);
        _showResendConfirmation = response.error == 'email_not_confirmed';
      });
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
                    keyboardType: TextInputType.emailAddress,
                  ),
                ],
              ),
              actionsOverflowButtonSpacing:
                  GlobalThemeData.dialogActionsOverflowSpacing,
              actions: [
                SoftButton(
                  label: context.l10n.cancel,
                  onPressed: () => Navigator.pop(context),
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                        setDialogState(() =>
                            dialogError = context.l10n.fill_in_all_fields);
                        return;
                      }
                      setDialogState(() {
                        sending = true;
                        dialogError = null;
                      });
                      final response = await _api.sendPasswordResetEmail(email);
                      if (!context.mounted) return;
                      if (response.success) {
                        Navigator.pop(context);
                        showSnackBar(context.l10n.password_email_sent,
                            tone: SnackTone.success);
                      } else {
                        setDialogState(() {
                          sending = false;
                          dialogError = _localizeAuthError(response.error);
                        });
                      }
                    },
                    color: Theme.of(context).colorScheme.primary,
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
    return AuthScaffold(
      title: _isSigningUp ? context.l10n.sign_up : context.l10n.log_in,
      success: _success,
      footer: TextButton(
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
      children: [
        ServerLabel(widget.instance, fontSize: 13),
        const SizedBox(height: authGapS),
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
                    maxLength: 19,
                    textInputAction: TextInputAction.next,
                  ),
                RoundedInputField(
                  controller: _emailController,
                  hintText: context.l10n.email,
                  icon: const Icon(Icons.email_rounded),
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  textInputAction: TextInputAction.next,
                ),
                _passwordField(
                  controller: _passwordController,
                  hintText: context.l10n.password,
                  icon: Icons.lock_rounded,
                  visible: _showPassword,
                  onToggle: () =>
                      setState(() => _showPassword = !_showPassword),
                  autofillHint: _isSigningUp
                      ? AutofillHints.newPassword
                      : AutofillHints.password,
                  textInputAction: _isSigningUp
                      ? TextInputAction.next
                      : TextInputAction.done,
                  onSubmitted: _isSigningUp ? null : (_) => _logIn(),
                ),
                if (_isSigningUp)
                  _passwordField(
                    controller: _passwordConfirmController,
                    hintText: context.l10n.confirm_password,
                    icon: Icons.check_rounded,
                    visible: _showConfirmPassword,
                    onToggle: () => setState(
                        () => _showConfirmPassword = !_showConfirmPassword),
                    autofillHint: AutofillHints.newPassword,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _signUp(),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: authGapM),
        AuthErrorBox(
          _errorMessage,
          action: _showResendConfirmation
              ? Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: _resendConfirmation,
                    child: Text(context.l10n.resend_confirmation),
                  ),
                )
              : null,
        ),
        RectangleButton(
          label: _isSigningUp ? context.l10n.sign_up : context.l10n.log_in,
          icon:
              _isSigningUp ? Symbols.person_add_rounded : Symbols.login_rounded,
          loading: _isLoading,
          onPressed: _isSigningUp ? _signUp : _logIn,
        ),
        if (!_isSigningUp && _api.isPasswordResetEnabled)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _forgotPasswordDialog,
              child: Text(context.l10n.forgot_password_question),
            ),
          ),
      ],
    );
  }

  /// A password field with a show/hide toggle.
  Widget _passwordField({
    required TextEditingController controller,
    required String hintText,
    required IconData icon,
    required bool visible,
    required VoidCallback onToggle,
    required String autofillHint,
    TextInputAction? textInputAction,
    ValueChanged<String>? onSubmitted,
  }) {
    return RoundedInputField(
      controller: controller,
      hintText: hintText,
      obscureText: !visible,
      icon: Icon(icon),
      autofillHints: [autofillHint],
      textInputAction: textInputAction,
      onSubmitted: onSubmitted,
      suffixIcon: IconButton(
        icon: Icon(
            visible ? Icons.visibility_off_rounded : Icons.visibility_rounded),
        onPressed: onToggle,
      ),
    );
  }
}
