import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:krab/services/supabase.dart';
import 'package:krab/UserPreferences.dart';
import 'package:krab/widgets/RectangleButton.dart';
import 'package:krab/widgets/UserAvatar.dart';
import 'package:krab/widgets/FloatingSnackBar.dart';
import 'LoginPage.dart';

class AccountPage extends StatefulWidget {
  const AccountPage({super.key});

  @override
  AccountPageState createState() => AccountPageState();
}

class AccountPageState extends State<AccountPage> {
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();

  String username = '';
  bool _isLoading = false;

  bool autoImageSave = false;

  @override
  void initState() {
    super.initState();
    _loadUserProfile();
  }

  Future<void> _loadUserProfile() async {
    setState(() {
      _isLoading = true;
    });

    // Load the profile data
    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;

    if (user == null) {
      // Optionally handle missing user (e.g., redirect to login)
      setState(() {
        _isLoading = false;
      });
      showSnackBar(context, "No user logged in.", color: Colors.red);
      return;
    }

    final usernameResponse = await getUsername(user.id);
    final emailResponse = await getEmail();

// Settings
    autoImageSave = await UserPreferences.getAutoImageSave();

// Optionally show errors if responses failed
    if (!usernameResponse.success) {
      showSnackBar(context, "Error loading username: ${usernameResponse.error}",
          color: Colors.red);
    }
    if (!emailResponse.success) {
      showSnackBar(context, "Error loading email: ${emailResponse.error}",
          color: Colors.red);
    }

    setState(() {
      username = usernameResponse.data ?? "";
      _usernameController.text = usernameResponse.data ?? "";
      _emailController.text = emailResponse.data ?? "";
      _isLoading = false;
    });
  }

  Future<void> _logout() async {
    await logOut();
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (context) => const LoginPage()),
    );
  }

  @override
  Scaffold build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Account'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Stack(
                      children: [
                        UserAvatar(username, radius: 60),
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: CircleAvatar(
                            radius: 20,
                            backgroundColor: Colors.white,
                            child: IconButton(
                              icon: const Icon(Icons.edit, size: 20),
                              onPressed: () {
                                // TODO: Implement image upload
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 30),
                  Text(
                    username,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  // Email Field
                  TextField(
                    controller: _emailController,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      prefixIcon: Icon(Icons.email),
                    ),
                    readOnly: true,
                  ),
                  const SizedBox(height: 50),

                  // Settings Section
                  const Padding(
                    padding: EdgeInsets.only(left: 8.0),
                    child: Text(
                      "Settings",
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),

                  SwitchListTile(
                    title: const Text("Automatically Save Images"),
                    subtitle: const Text(
                        "Images will be saved to your gallery when received."),
                    value: autoImageSave,
                    onChanged: (bool value) {
                      UserPreferences.setAutoImageSave(value);
                      setState(() {
                        autoImageSave = value;
                      });
                    },
                  ),

                  const SizedBox(height: 80),

                  // Logout Button
                  RectangleButton(
                    label: 'Logout',
                    onPressed: _logout,
                    backgroundColor: Colors.redAccent,
                  ),
                ],
              ),
            ),
    );
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _emailController.dispose();
    super.dispose();
  }
}
