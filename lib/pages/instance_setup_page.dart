import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/pages/login_page.dart';
import 'package:krab/services/connection_check.dart';
import 'package:krab/services/connection_token.dart';
import 'package:krab/services/instance/instance_registry.dart';
import 'package:krab/services/push_helper.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/widgets/auth/auth_error_box.dart';
import 'package:krab/widgets/auth/auth_scaffold.dart';
import 'package:krab/widgets/rectangle_button.dart';
import 'package:krab/widgets/rounded_input_field.dart';
import 'package:krab/services/instance/instances.dart';

/// Asks which KRAB backend this install should talk to.
class InstanceSetupPage extends StatefulWidget {
  /// Whether this is a new server rather than the first.
  final bool addingAnother;

  const InstanceSetupPage({super.key, this.addingAnother = false});

  @override
  State<InstanceSetupPage> createState() => _InstanceSetupPageState();
}

/// How long the green ring is held before the screen moves on.
const Duration _successHold = Duration(seconds: 1);

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
    setState(() {
      _connected = false;
      _error = null;
    });
  }

  /// The connection details as they currently stand, or null while they are not
  /// usable yet.
  ({String url, String key})? _peek() {
    if (!_manual) {
      final info = ConnectionToken.decode(_tokenController.text);
      return info == null ? null : (url: info.url, key: info.anonKey);
    }
    final url = _urlController.text.trim();
    final key = _keyController.text.trim();
    if (url.isEmpty || key.isEmpty) return null;
    return (url: url, key: key);
  }

  /// The server already connected that the current input names, if any.
  KrabInstance? get _duplicate {
    final input = _peek();
    if (input == null) return null;
    final existing = InstanceRegistry.instance.byUrl(input.url);
    return existing != null && existing.anonKey == input.key ? existing : null;
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

  /// Show an inline error, and forget any earlier successful test.
  void _fail(String message) {
    setState(() {
      _error = message;
      _connected = false;
    });
  }

  /// Resolves the connection details. Returns null and shows an inline error
  /// if the input is unusable.
  ({String url, String key})? _resolve() {
    if (!_manual) {
      final info = ConnectionToken.decode(_tokenController.text);
      if (info == null) {
        _fail(context.l10n.instance_setup_bad_token);
        return null;
      }
      return (url: info.url, key: info.anonKey);
    }

    final url = _urlController.text.trim();
    final key = _keyController.text.trim();
    if (url.isEmpty || key.isEmpty) {
      _fail(context.l10n.instance_setup_missing_fields);
      return null;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
      _fail(context.l10n.instance_setup_invalid_url);
      return null;
    }
    return (url: url, key: key);
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
          _error = context.l10n.instance_setup_test_bad_key;
        case ConnectionCheckResult.unreachable:
          _error = context.l10n.instance_setup_unreachable;
      }
    });
  }

  Future<void> _connect() async {
    if (_connecting || _testing) return;
    final resolved = _resolve();
    if (resolved == null) return;

    // Already on this server
    final existing = InstanceRegistry.instance.byUrl(resolved.url);
    if (existing != null && existing.anonKey == resolved.key) {
      _fail(context.l10n.instance_setup_already_connected(existing.label));
      return;
    }

    setState(() {
      _connecting = true;
      _error = null;
    });

    // Connecting to a URL already in the registry replaces its entry in place,
    // keeping its id
    final replaced = existing == null
        ? null
        : (
            url: existing.url,
            key: existing.anonKey,
            name: existing.displayName
          );

    final instance = await InstanceRegistry.instance.connect(
      url: resolved.url,
      anonKey: resolved.key,
    );

    // Prove the instance answers before leaving this screen
    final config = await instance.api.fetchInstanceConfig();
    if (!config.success) {
      if (replaced == null) {
        await InstanceRegistry.instance.remove(instance.id);
      } else {
        await InstanceRegistry.instance.connect(
          url: replaced.url,
          anonKey: replaced.key,
          displayName: replaced.name,
        );
      }
      if (!mounted) return;
      setState(() => _connecting = false);
      _fail(context.l10n.instance_setup_unreachable);
      return;
    }

    // Bring Firebase up against the config that just arrived.
    await PushHelper.ensureRegistered(instance);

    if (!mounted) return;

    setState(() => _connected = true);
    await Future.delayed(_successHold);
    if (!mounted) return;

    if (widget.addingAnother) {
      // Sign in right away
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => LoginPage(
          instance: instance,
          enterAppOnSuccess: false,
        ),
      ));
      if (!mounted) return;
      Navigator.of(context).pop(instance);
      return;
    }

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => LoginPage(instance: instance)),
      (route) => false,
    );
  }

  /// Switch between pasting a token and typing the details out.
  Widget _modeSwitch(BuildContext context) {
    return TextButton(
      onPressed: (_connecting || _testing)
          ? null
          : () => setState(() {
                _manual = !_manual;
                _error = null;
                _connected = false;
              }),
      child: Text(
        _manual
            ? context.l10n.instance_setup_use_token
            : context.l10n.instance_setup_use_manual,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final busy = _connecting || _testing;

    // Already connected to this server.
    final duplicate = busy ? null : _duplicate;

    return AuthScaffold(
      title: context.l10n.instance_setup_title,
      subtitle: _manual
          ? context.l10n.instance_setup_subtitle
          : context.l10n.instance_setup_token_subtitle,
      success: _connected,
      footer: _modeSwitch(context),
      children: [
        if (_manual) ...[
          RoundedInputField(
            controller: _urlController,
            hintText: context.l10n.instance_setup_url_hint,
            icon: const Icon(Icons.link_rounded),
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.next,
            enabled: !busy,
          ),
          RoundedInputField(
            controller: _keyController,
            hintText: context.l10n.instance_setup_key_hint,
            icon: const Icon(Icons.vpn_key_rounded),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _connect(),
            enabled: !busy,
          ),
        ] else
          RoundedInputField(
            controller: _tokenController,
            hintText: context.l10n.instance_setup_token_hint,
            icon: const Icon(Icons.vpn_key_rounded),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _connect(),
            enabled: !busy,
            suffixIcon: IconButton(
              icon: const Icon(Icons.content_paste_rounded, size: 20),
              tooltip: context.l10n.instance_setup_paste,
              onPressed: busy ? null : _pasteToken,
            ),
          ),
        const SizedBox(height: authGapM),
        AuthErrorBox(_error ??
            (duplicate == null
                ? null
                : context.l10n
                    .instance_setup_already_connected(duplicate.label))),

        // Testing button
        RectangleButton(
          label: _connected
              ? context.l10n.instance_setup_connected
              : _testing
                  ? context.l10n.instance_setup_testing
                  : context.l10n.instance_setup_test,
          icon: _connected
              ? Symbols.check_circle_rounded
              : Symbols.wifi_tethering_rounded,
          loading: _testing,
          style: _connected
              ? RectangleButtonStyle.filled
              : RectangleButtonStyle.outlined,
          backgroundColor: _connected ? GlobalThemeData.success : null,
          onPressed: (_connecting || duplicate != null) ? null : _test,
        ),
        const SizedBox(height: authGapS),
        RectangleButton(
          label: _connecting
              ? context.l10n.instance_setup_connecting
              : context.l10n.instance_setup_connect,
          icon: Symbols.arrow_forward_rounded,
          loading: _connecting,
          onPressed: (_testing || duplicate != null) ? null : _connect,
        ),
      ],
    );
  }
}
