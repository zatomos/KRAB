import 'package:flutter/material.dart';

import 'package:krab/services/supabase.dart';
import 'package:krab/themes/GlobalThemeData.dart';
import 'package:krab/widgets/RoundedInputField.dart';
import 'package:krab/widgets/RectangleButton.dart';
import 'package:krab/pages/CameraPage.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  LoginPageState createState() => LoginPageState();
}

class LoginPageState extends State<LoginPage> {
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _forgotPasswordController = TextEditingController();

  String _message = "";
  bool _isSigningUp = true;

  Future<void> _signUp() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final username = _usernameController.text.trim();

    if (email.isEmpty || password.isEmpty || username.isEmpty) {
      setState(() {
        _message = "Please fill in all fields.";
      });
      return;
    }

    final response = await registerUser(username, email, password);
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

  Future<void> _logIn() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() {
        _message = "Please fill in all fields.";
      });
      return;
    }

    final response = await loginUser(email, password);
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
                  showDialog(context: context, builder: (context) {
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
                if (response.success) {
                  Navigator.of(context).pop();
                  setState(() {
                    _message = "Password reset email sent.";
                  });
                } else {
                  showDialog(context: context, builder: (context) {
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
                _isSigningUp ? "Sign Up" : "Login",
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
                hintText: "Username",
                icon: const Icon(Icons.person),
              ),
            ),
            // Email field.
            RoundedInputField(
              controller: _emailController,
              hintText: "Email",
              icon: const Icon(Icons.email),
            ),
            // Password field.
            RoundedInputField(
              controller: _passwordController,
              hintText: "Password",
              obscureText: true,
              icon: const Icon(Icons.lock),
            ),
            const SizedBox(height: 20),
            // Wrap the button in Center to preserve its intrinsic (fixed) width.
            Center(
              child: RectangleButton(
                label: _isSigningUp ? "Sign Up" : "Login",
                onPressed: _isSigningUp ? _signUp : _logIn,
              ),
            ),
            // Uncomment if you setup password reset in Supabase.
            /*Visibility(
                visible: !_isSigningUp,
                child: TextButton(
                    onPressed: _forgotPasswordDialog,
                    child: const Text("Forgot Password?"))),
            const SizedBox(height: 20),*/
            Center(
                child:
                    Text(_message, style: const TextStyle(color: Colors.red))),
            Center(
              child: TextButton(
                onPressed: () {
                  setState(() {
                    _isSigningUp = !_isSigningUp;
                  });
                },
                child: Text(
                  _isSigningUp
                      ? "Already have an account? Login"
                      : "Don't have an account? Sign Up",
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
