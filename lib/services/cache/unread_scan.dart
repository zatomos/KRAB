import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:krab/models/group.dart';
import 'package:krab/services/cache/seen_state.dart';
import 'package:krab/user_preferences.dart';
import 'package:krab/services/api/krab_api.dart';
import 'package:krab/services/instance/instance_registry.dart';

/// One reading of what is waiting unopened shared by everything that shows it.
class UnreadScan extends ChangeNotifier {
  UnreadScan._();

  static final UnreadScan instance = UnreadScan._();

  /// How long a reading stands before taking a new one.
  static const Duration freshFor = Duration(minutes: 2);

  /// The recent images of each group.
  final Map<String, List<({String identity, DateTime? uploadedAt})>> _recent =
      {};

  final Set<String> _muted = {};

  DateTime? _scannedAt;
  Future<void>? _running;

  static String groupKey(String instanceId, String groupId) =>
      '$instanceId/$groupId';

  /// Whether a reading has been taken
  bool get hasScanned => _scannedAt != null;

  bool get _isFresh {
    final at = _scannedAt;
    return at != null && DateTime.now().difference(at) < freshFor;
  }

  /// How many of a group's recent images have not been opened.
  int countFor(String instanceId, String groupId) {
    final key = groupKey(instanceId, groupId);
    if (_muted.contains(key)) return 0;
    return SeenState.instance.newImageCount(_recent[key] ?? const []);
  }

  /// Whether a count is only as high as the scan can see
  bool isCapped(int count) => count >= SeenState.lookback;

  /// Everything unopened across every group, counted once however many groups
  /// an image is in.
  int get total {
    final counted = <String>{};
    var unopened = 0;
    for (final entry in _recent.entries) {
      if (_muted.contains(entry.key)) continue;
      final images = entry.value;
      for (final image in images) {
        if (!counted.add(image.identity)) continue;
        if (SeenState.instance.isImageNew(image.identity, image.uploadedAt)) {
          unopened++;
        }
      }
    }
    return unopened;
  }

  bool get anyUnread => total > 0;

  /// Take a reading, unless a recent one stands or one is already being taken.
  Future<void> refresh({List<Group>? groups, bool force = false}) {
    if (!force && _isFresh) return Future.value();
    return _running ??= _scan(groups).whenComplete(() {
      _running = null;
    });
  }

  Future<void> _scan(List<Group>? known) async {
    await reloadMuted(notify: false);
    final groups = known ?? await _listGroups();
    final readings =
        <String, List<({String identity, DateTime? uploadedAt})>>{};

    await Future.wait(groups.map((group) async {
      final instance = InstanceRegistry.instance.byId(group.instanceId);
      if (instance == null) return;
      final response = await instance.api
          .getLatestImages(SeenState.lookback, groupIds: [group.id]);
      final images = response.data;
      if (images == null) return;
      readings[groupKey(group.instanceId, group.id)] = [
        for (final image in images)
          (identity: image.identity, uploadedAt: image.uploadedAt)
      ];
    }));

    _recent.addAll(readings);
    _scannedAt = DateTime.now();
    notifyListeners();
  }

  Future<List<Group>> _listGroups() async {
    final instances = InstanceRegistry.instance.signedIn;
    final responses =
        await Future.wait(instances.map((i) => i.api.getUserGroups()));
    return [
      for (final response in responses) ...?response.data,
    ];
  }

  Future<void> reloadMuted({bool notify = true}) async {
    final muted = await UserPreferences.getMutedGroups();
    _muted
      ..clear()
      ..addAll(muted);
    if (notify) notifyListeners();
  }

  /// Forget everything. Called on logout.
  void clear() {
    _recent.clear();
    _muted.clear();
    _scannedAt = null;
    notifyListeners();
  }
}
