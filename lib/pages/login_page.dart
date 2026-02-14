import 'package:flutter/material.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/services/supabase.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/widgets/floating_snack_bar.dart';
import 'package:krab/widgets/rounded_input_field.dart';
import 'package:krab/widgets/rectangle_button.dart';
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

  String _message = "";
  bool _isSigningUp = true;

  Future<void> _signUp() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final passwordConfirm = _passwordConfirmController.text;
    final username = _usernameController.text.trim();

    if (password != passwordConfirm) {
      setState(() {
        _message = context.l10n.passwords_do_not_match;
      });
      return;
    }

    if (email.isEmpty || password.isEmpty || username.isEmpty) {
      setState(() {
        _message = context.l10n.fill_in_all_fields;
      });
      return;
    }

    final response = await registerUser(username, email, password);
    if (!mounted) return;
    if (response.success) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => const CameraPage()),
      );
      showSnackBar(context.l10n.register_user_success);
    } else {
      setState(() {
        _message = "${response.error}";
      });
    }
  }

  Future<void> _logIn() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() {
        _message = context.l10n.fill_in_all_fields;
      });
      return;
    }

    final response = await loginUser(email, password);
    if (!mounted) return;
    if (response.success) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => const CameraPage()),
      );
    } else {
      setState(() {
        _message = "${response.error}";
      });
    }
  }

  Future<void> _forgotPasswordDialog() async {
    return showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("Forgot Password"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("Enter the email associated with your account."),
              const SizedBox(height: 20),
              RoundedInputField(
                controller: _forgotPasswordController,
                hintText: "Email",
                icon: const Icon(Icons.email),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text("Cancel"),
            ),
            TextButton(
              onPressed: () async {
                final email = _forgotPasswordController.text.trim();
                if (email.isEmpty) {
                  showDialog(
                      context: context,
                      builder: (context) {
                        return AlertDialog(
                          title: const Text("Error"),
                          content: const Text("Please enter an email."),
                          actions: [
                            TextButton(
                              onPressed: () {
                                Navigator.of(context).pop();
                              },
                              child: const Text("OK"),
                            ),
                          ],
                        );
                      });
                  return;
                }

                final response = await sendPasswordResetEmail(email);
                if (!context.mounted || !mounted) return;
                if (response.success) {
                  Navigator.of(context).pop();
                  setState(() {
                    _message = "Password reset email sent.";
                  });
                } else {
                  showDialog(
                      context: context,
                      builder: (context) {
                        return AlertDialog(
                          title: const Text("Error"),
                          content: Text("${response.error}"),
                          actions: [
                            TextButton(
                              onPressed: () {
                                Navigator.of(context).pop();
                              },
                              child: const Text("OK"),
                            ),
                          ],
                        );
                      });
                }
              },
              child: const Text("Reset Password"),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Center(
              child: Text(
                _isSigningUp ? context.l10n.sign_up : context.l10n.log_in,
                style: TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.bold,
                    color: GlobalThemeData.darkColorScheme.secondary),
              ),
            ),
            const SizedBox(height: 20),
            // Username field.
            Visibility(
              visible: _isSigningUp,
              child: RoundedInputField(
                  controller: _usernameController,
                  hintText: context.l10n.username,
                  icon: const Icon(Icons.person_rounded)),
            ),
            // Email field.
            RoundedInputField(
                controller: _emailController,
                hintText: context.l10n.email,
                icon: const Icon(Icons.email_rounded)),
            // Password field.
            RoundedInputField(
              controller: _passwordController,
              hintText: context.l10n.password,
              obscureText: true,
              icon: const Icon(Icons.lock_rounded),
            ),
            // Password confirmation field
            Visibility(
              visible: _isSigningUp,
              child: RoundedInputField(
                controller: _passwordConfirmController,
                hintText: context.l10n.confirm_password,
                obscureText: true,
                icon: const Icon(Icons.replay_circle_filled_rounded),
              ),
            ),
            const SizedBox(height: 20),
            // Wrap the button in Center to preserve its width
            Center(
              child: RectangleButton(
                label:
                    _isSigningUp ? context.l10n.sign_up : context.l10n.log_in,
                onPressed: _isSigningUp ? _signUp : _logIn,
              ),
            ),
            // Uncomment if you setup password reset in Supabase.
            /*Visibility(
                visible: !_isSigningUp,
                child: TextButton(
                    onPressed: _forgotPasswordDialog,
                    child: const Text("Forgot Password?"))),*/
            const SizedBox(height: 10),
            Center(
                child: Text(_message,
                    style: const TextStyle(
                        color: Colors.red, fontWeight: FontWeight.bold))),
            Center(
                child: TextButton(
              onPressed: () {
                setState(() {
                  _isSigningUp = !_isSigningUp;
                  _message = "";
                  _passwordController.clear();
                  if (!_isSigningUp) {
                    _usernameController.clear(); // leaving sign-up
                  }
                });
              },
              child: Text(
                _isSigningUp
                    ? context.l10n.already_have_account
                    : context.l10n.dont_have_account,
              ),
            )),
          ],
        ),
      ),
    );
  }
}
