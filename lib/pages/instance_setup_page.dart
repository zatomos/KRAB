import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/pages/login_page.dart';
import 'package:krab/services/api/supabase.dart';
import 'package:krab/services/connection_check.dart';
import 'package:krab/services/connection_token.dart';
import 'package:krab/services/push_helper.dart';
import 'package:krab/services/supabase_bootstrap.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/user_preferences.dart';
import 'package:krab/widgets/auth_card.dart';
import 'package:krab/widgets/rectangle_button.dart';
import 'package:krab/widgets/rounded_input_field.dart';

/// Asks which KRAB backend this install should talk to.
///
/// KRAB has no central server, so the app cannot be compiled against one
/// instance. The normal path is a single connection token the operator hands
/// out (it packs the URL and the anon key), with manual URL + anon-key entry as
/// a fallback for anyone who would rather type them.
class InstanceSetupPage extends StatefulWidget {
  const InstanceSetupPage({super.key});

  @override
  State<InstanceSetupPage> createState() => _InstanceSetupPageState();
}

class _InstanceSetupPageState extends State<InstanceSetupPage> {
  final _tokenController = TextEditingController();
  final _urlController = TextEditingController();
  final _keyController = TextEditingController();

  bool _manual = false;
  bool _connecting = false;
  bool _testing = false;
  bool _connected = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final c in [_tokenController, _urlController, _keyController]) {
      c.addListener(_onInputChanged);
    }
  }

  /// Editing the input invalidates a prior test result, so drop it.
  void _onInputChanged() {
    if (_connected || _error != null) {
      setState(() {
        _connected = false;
        _error = null;
      });
    }
  }

  @override
  void dispose() {
    _tokenController.dispose();
    _urlController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _pasteToken() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) {
      _tokenController.text = text.trim();
    }
  }

  /// Resolves the connection details from whichever mode is active. Returns null
  /// and sets an inline error if the input is unusable.
  ({String url, String key})? _resolve() {
    if (_manual) {
      final url = _urlController.text.trim();
      final key = _keyController.text.trim();
      if (url.isEmpty || key.isEmpty) {
        setState(() {
          _error = context.l10n.instanceSetupMissingFields;
          _connected = false;
        });
        return null;
      }
      final uri = Uri.tryParse(url);
      if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
        setState(() {
          _error = context.l10n.instanceSetupInvalidUrl;
          _connected = false;
        });
        return null;
      }
      return (url: url, key: key);
    }

    final info = ConnectionToken.decode(_tokenController.text);
    if (info == null) {
      setState(() {
        _error = context.l10n.instanceSetupBadToken;
        _connected = false;
      });
      return null;
    }
    return (url: info.url, key: info.anonKey);
  }

  /// Probes the instance without committing to it, so the user can confirm the
  /// token/details are right before connecting.
  Future<void> _test() async {
    if (_testing || _connecting) return;
    final resolved = _resolve();
    if (resolved == null) return;

    setState(() {
      _testing = true;
      _error = null;
      _connected = false;
    });

    final result = await testConnection(resolved.url, resolved.key);
    if (!mounted) return;

    setState(() {
      _testing = false;
      switch (result) {
        case ConnectionCheckResult.ok:
          _connected = true;
        case ConnectionCheckResult.badKey:
          _error = context.l10n.instanceSetupTestBadKey;
        case ConnectionCheckResult.unreachable:
          _error = context.l10n.instanceSetupUnreachable;
      }
    });
  }

  Future<void> _connect() async {
    if (_connecting || _testing) return;
    final resolved = _resolve();
    if (resolved == null) return;

    setState(() {
      _connecting = true;
      _error = null;
      _connected = false;
    });

    await UserPreferences.setSupabaseConfig(
      url: resolved.url,
      anonKey: resolved.key,
    );

    // Prove the instance answers before committing to it: a wrong token or a
    // typo would otherwise only surface as a confusing failure at login.
    final ok = await initializeSupabaseIfNeeded();
    if (!ok) {
      await UserPreferences.setSupabaseConfig(url: '', anonKey: '');
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _error = context.l10n.instanceSetupUnreachable;
      });
      return;
    }

    // Learn what this instance supports (its VAPID key, and whether it offers
    // password reset or email confirmation) before the login screen is built,
    // since the login screen decides what to show from it.
    await fetchInstanceConfig();

    // Then subscribe against the VAPID key that just arrived.
    await PushHelper.ensureRegistered();

    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: GlobalThemeData.darkColorScheme.surface,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: AuthCard.maxWidth),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Image.asset('logo/krab_logo.png', height: 80),
                  const SizedBox(height: 16),
                  AuthCard(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          context.l10n.instanceSetupTitle,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _manual
                              ? context.l10n.instanceSetupSubtitle
                              : context.l10n.instanceSetupTokenSubtitle,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 20),
                        if (_manual) ...[
                          RoundedInputField(
                            controller: _urlController,
                            hintText: context.l10n.instanceSetupUrlHint,
                          ),
                          RoundedInputField(
                            controller: _keyController,
                            hintText: context.l10n.instanceSetupKeyHint,
                          ),
                        ] else ...[
                          RoundedInputField(
                            controller: _tokenController,
                            hintText: context.l10n.instanceSetupTokenHint,
                          ),
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              onPressed: _connecting ? null : _pasteToken,
                              icon: const Icon(Icons.content_paste_rounded,
                                  size: 18),
                              label: Text(context.l10n.instanceSetupPaste),
                            ),
                          ),
                        ],
                        SizedBox(
                          height: 12,
                          child: Center(
                            child: _error == null
                                ? null
                                : Text(
                                    _error!,
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                        color: theme.colorScheme.error),
                                  ),
                          ),
                        ),
                        RectangleButton(
                          label: _connected
                              ? context.l10n.instanceSetupConnected
                              : _testing
                                  ? context.l10n.instanceSetupTesting
                                  : context.l10n.instanceSetupTest,
                          icon: _connected
                              ? Symbols.check_circle_rounded
                              : Symbols.wifi_tethering_rounded,
                          backgroundColor: _connected
                              ? Colors.green
                              : GlobalThemeData.darkColorScheme.surface,
                          onPressed: _test,
                        ),
                        const SizedBox(height: 10),
                        RectangleButton(
                          label: _connecting
                              ? context.l10n.instanceSetupConnecting
                              : context.l10n.instanceSetupConnect,
                          icon: Symbols.arrow_forward_rounded,
                          onPressed: _connect,
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: (_connecting || _testing)
                              ? null
                              : () => setState(() {
                                    _manual = !_manual;
                                    _error = null;
                                    _connected = false;
                                  }),
                          child: Text(
                            _manual
                                ? context.l10n.instanceSetupUseToken
                                : context.l10n.instanceSetupUseManual,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
