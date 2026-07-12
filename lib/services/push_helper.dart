import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:unifiedpush/unifiedpush.dart';

import 'package:krab/app_globals.dart';
import 'package:krab/services/api/supabase.dart';
import 'package:krab/services/auth/app_auth.dart';
import 'package:krab/services/debug_notifier.dart';
import 'package:krab/services/notification_router.dart';
import 'package:krab/user_preferences.dart';

/// Decodes a decrypted push body into the flat string map the routers expect.
Map<String, String>? decodePushPayload(Uint8List content) {
  try {
    final decoded = jsonDecode(utf8.decode(content));
    if (decoded is! Map) {
      debugPrint('Push: unexpected payload shape, ignoring');
      return null;
    }
    return decoded.map((k, v) => MapEntry('$k', '$v'));
  } catch (e) {
    debugPrint('Push: could not decode payload: $e');
    return null;
  }
}

/// Push delivery over UnifiedPush / Web Push.
///
/// The app asks a distributor to open a subscription on its behalf, and hands
/// the resulting endpoint to whichever KRAB backend the user is signed in to.
/// The backend authenticates its pushes with a VAPID keypair it generated itself.
///
/// The one thing that must happen before subscribing is fetching this
/// instance's VAPID public key.
class PushHelper {
  static bool _initialized = false;
  static StreamSubscription<AppAuthStatus>? _authSubscription;

  /// The instance's VAPID public key
  static String? _vapidKey;

  /// The key we have actually registered against in this process
  static String? _registeredWith;

  /// The subscription the distributor last handed us. A distributor only hands
  /// an endpoint over once, so it is kept here until it has been stored against
  /// a user, which can be well after it arrives: the connect screen and a cold
  /// start both register before anyone has logged in.
  static _Subscription? _pending;

  /// The user [_pending] has been stored for, so a second user signing in on
  /// this device gets a subscription of their own rather than inheriting one.
  static String? _savedForUser;

  /// Wires the UnifiedPush callbacks. Safe to call from the background
  /// entrypoint.
  static Future<bool> initialize({required bool background}) async {
    final alreadyRegistered = await UnifiedPush.initialize(
      onNewEndpoint: _onNewEndpoint,
      onRegistrationFailed: _onRegistrationFailed,
      onUnregistered: _onUnregistered,
      onMessage: (message, instance) => _onMessage(message, background),
    );

    if (!_initialized && !background) {
      _initialized = true;
      // Signing in is the point at which a subscription can finally be stored:
      // it is what gives us a user to store it against.
      _authSubscription = AppAuth.instance.events.listen((status) async {
        if (status == AppAuthStatus.signedIn) {
          await ensureRegistered();
        }
      });
    }

    return alreadyRegistered;
  }

  static Future<void> dispose() async {
    await _authSubscription?.cancel();
    _authSubscription = null;
    _initialized = false;
    // Called on logout, after which the next user may be on another instance.
    _registeredWith = null;
    _vapidKey = null;
    _pending = null;
    _savedForUser = null;
  }

  /// Subscribes via the user's current distributor, falling back to the system
  /// default. Returns false when no distributor could be used at all.
  ///
  /// Called both before and after a login, so it has to cope with arriving when
  /// there is no session yet, and with being called again once there is one.
  static Future<bool> ensureRegistered() async {
    try {
      // A subscription taken out before the user logged in is still perfectly
      // good; it just had nobody to belong to. Store it now rather than
      // re-registering, because the distributor will not hand it over twice.
      if (await _savePending()) return true;

      final usable = await UnifiedPush.tryUseCurrentOrDefaultDistributor();
      if (!usable) {
        debugPrint('Push: no usable distributor');
        return false;
      }
      await _register();
      return true;
    } catch (e, st) {
      debugPrint('Push: ensureRegistered failed: $e\n$st');
      return false;
    }
  }

  /// Stores the subscription we are holding, if there is one and it is not
  /// already stored against the signed-in user. Returns whether that leaves
  /// nothing more for [ensureRegistered] to do.
  static Future<bool> _savePending() async {
    final pending = _pending;
    if (pending == null) return false;

    final userId = AppAuth.instance.currentUserId;
    if (userId == null) {
      // Still nobody to attach it to. Keep hold of it; the signedIn listener
      // comes back through here.
      debugPrint('Push: no session; holding the subscription');
      return false;
    }

    if (_savedForUser == userId) return true;

    final res = await savePushSubscription(
      endpoint: pending.endpoint,
      p256dh: pending.p256dh,
      auth: pending.auth,
    );

    if (res.success) {
      _savedForUser = userId;
      debugPrint('Push: subscription saved');
      await DebugNotifier.instance.notifyPushSubscriptionSaved();
      return true;
    }

    debugPrint('Push: failed to save subscription: ${res.error}');
    await DebugNotifier.instance.notifyPushSubscriptionFailed('${res.error}');
    return false;
  }

  /// Distributors installed on the device, so the user can be offered a choice.
  ///
  /// On a device with no Play Services and no UnifiedPush app installed this is
  /// empty,and the user needs to install a distributor.
  static Future<List<String>> availableDistributors() =>
      UnifiedPush.getDistributors();

  /// The distributor currently in use, or null if none has been picked yet.
  static Future<String?> currentDistributor() => UnifiedPush.getDistributor();

  /// Moves to distributor. Returns whether a subscription was taken out.
  static Future<bool> useDistributor(String distributor) async {
    await UnifiedPush.saveDistributor(distributor);
    _registeredWith = null;
    _pending = null;
    _savedForUser = null;
    await _register();
    return _registeredWith != null;
  }

  static Future<void> unregister() async {
    await UnifiedPush.unregister();
    _registeredWith = null;
    _pending = null;
    _savedForUser = null;
  }

  /// Registers against the current backend's VAPID key.
  static Future<void> _register() async {
    final vapid = await _vapidPublicKey();
    if (vapid == null) {
      debugPrint('Push: no VAPID key for this instance; not registering');
      return;
    }

    if (vapid == _registeredWith) {
      debugPrint('Push: already registered with this instance, skipping');
      return;
    }

    await UnifiedPush.register(vapid: vapid);
    _registeredWith = vapid;
  }

  static Future<String?> _vapidPublicKey() async {
    if (_vapidKey != null) return _vapidKey;

    final cached = UserPreferences.vapidPublicKey;
    if (cached.isNotEmpty) {
      _vapidKey = cached;
      return cached;
    }

    if (!isSupabaseInitialized) return null;

    // The key arrives as part of this instance's config, which is cached, so
    // this fetch happens once per backend rather than once per registration.
    final res = await fetchInstanceConfig();
    if (!res.success) {
      debugPrint('Push: could not fetch the instance config: ${res.error}');
      return null;
    }

    final key = UserPreferences.vapidPublicKey;
    if (key.isEmpty) {
      debugPrint('Push: this instance has not configured push');
      return null;
    }

    _vapidKey = key;
    return _vapidKey;
  }

  static Future<void> _onNewEndpoint(
      PushEndpoint endpoint, String instance) async {
    final keys = endpoint.pubKeySet;
    if (keys == null) {
      // Without the key set the backend has nothing to encrypt to.
      // Storing the endpoint alone would just make every later push fail.
      debugPrint('Push: endpoint carries no Web Push keys, ignoring');
      return;
    }

    // A new endpoint supersedes whatever we held, and is not yet stored for
    // anyone.
    _pending = _Subscription(
      endpoint: endpoint.url,
      p256dh: keys.pubKey,
      auth: keys.auth,
    );
    _savedForUser = null;

    await _savePending();
  }

  static Future<void> _onMessage(PushMessage message, bool background) async {
    debugPrint('Push: message received '
        '(decrypted=${message.decrypted}, ${message.content.length} bytes, '
        'background=$background)');

    // An undecrypted message is one we hold no key for. It is not ours to read,
    // and its bytes are ciphertext, so there is nothing to route.
    if (!message.decrypted) {
      debugPrint('Push: received an undecryptable message, ignoring');
      return;
    }

    final data = decodePushPayload(message.content);
    if (data == null) return;

    debugPrint('Push: payload = $data');

    try {
      await handlePushPayload(data, background: background);
      debugPrint('Push: handler returned');
    } catch (e, st) {
      debugPrint('Push: failed to handle message: $e\n$st');
    }
  }

  static void _onRegistrationFailed(FailedReason reason, String instance) {
    debugPrint('Push: registration failed ($reason)');
  }

  static void _onUnregistered(String instance) {
    debugPrint('Push: unregistered');
  }
}

/// A Web Push subscription handed over by a distributor.
class _Subscription {
  final String endpoint;
  final String p256dh;
  final String auth;

  const _Subscription({
    required this.endpoint,
    required this.p256dh,
    required this.auth,
  });
}
