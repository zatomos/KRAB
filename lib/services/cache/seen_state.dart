import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef CommentThread = ({
  String instanceId,
  String groupId,
  int count,
  DateTime? latestAt,
});

/// What this device has already shown the user.
class SeenState extends ChangeNotifier {
  SeenState._();

  static final SeenState instance = SeenState._();

  static const String prefsKey = 'krab_seen_state';

  /// How many images the badges ask about.
  static const int lookback = 99;

  /// How many opened images are remembered.
  static const int _maxImages = 1000;

  /// How many comment and reaction baselines are remembered.
  static const int _maxTallies = 1000;

  final Map<String, int> _images = {};
  final Map<String, int> _comments = {};

  /// When the newest comment already shown under each of those keys landed.
  final Map<String, int> _commentsAt = {};

  final Map<String, Map<String, int>> _reactions = {};

  /// When counting started on this device.
  DateTime? _trackingSince;

  /// When each counted entry was last written, so the oldest go first.
  final Map<String, int> _touched = {};

  bool _loaded = false;
  Timer? _saveTimer;

  /// Nothing before this is new.
  DateTime get _floor => _trackingSince ?? DateTime.now();

  static String commentsKey(
          String instanceId, String groupId, String identity) =>
      '$instanceId/$groupId/$identity';

  /// The key for an image's comments counted across every group at once.
  static String allCommentsKey(String identity) => 'all-comments/$identity';

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(prefsKey);
    if (raw == null || raw.isEmpty) {
      _trackingSince = DateTime.now();
      _scheduleSave();
      return;
    }
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      _readInts(decoded['images'], _images);
      _readInts(decoded['comments'], _comments);
      _readInts(decoded['comments_at'], _commentsAt);
      _readTallies(decoded['reactions'], _reactions);
      _readInts(decoded['touched'], _touched);
      final since = decoded['tracking_since'];
      _trackingSince = since is int
          ? DateTime.fromMillisecondsSinceEpoch(since)
          : DateTime.now();
    } catch (e) {
      debugPrint('seen: unreadable store, starting over: $e');
      _images.clear();
      _comments.clear();
      _commentsAt.clear();
      _reactions.clear();
      _touched.clear();
      _trackingSince = DateTime.now();
    }
    _prune();
  }

  static void _readTallies(Object? raw, Map<String, Map<String, int>> into) {
    if (raw is! Map) return;
    for (final entry in raw.entries) {
      final tally = <String, int>{};
      _readInts(entry.value, tally);
      if (tally.isNotEmpty) into[entry.key.toString()] = tally;
    }
  }

  static void _readInts(Object? raw, Map<String, int> into) {
    if (raw is! Map) return;
    for (final entry in raw.entries) {
      final value = entry.value;
      if (value is int) into[entry.key.toString()] = value;
    }
  }

  bool isImageNew(String identity, DateTime? uploadedAt) {
    if (uploadedAt == null || !uploadedAt.isAfter(_floor)) return false;
    return !_images.containsKey(identity);
  }

  int newImageCount(
      Iterable<({String identity, DateTime? uploadedAt})> images) {
    var count = 0;
    for (final image in images) {
      if (isImageNew(image.identity, image.uploadedAt)) count++;
    }
    return count;
  }

  bool hasNewComments(
          String instanceId, String groupId, String identity, int count,
          {DateTime? latestAt}) =>
      _hasNewComments(
          commentsKey(instanceId, groupId, identity), count, latestAt);

  bool hasNewCommentsAnywhere(String identity, int totalCount,
          {DateTime? latestAt}) =>
      _hasNewComments(allCommentsKey(identity), totalCount, latestAt);

  bool _hasNewComments(String key, int count, DateTime? latestAt) {
    if (latestAt == null) {
      final seen = _comments[key] ?? 0;
      if (count < seen) _lowerCommentBaseline(key, count);
      return count > seen;
    }
    final seenAt = _commentsAt[key];
    if (seenAt == null) return latestAt.isAfter(_floor);
    return latestAt.millisecondsSinceEpoch > seenAt;
  }

  /// Take the baseline down to what is actually there.
  void _lowerCommentBaseline(String key, int count) {
    _comments[key] = count;
    _touched[key] = DateTime.now().millisecondsSinceEpoch;
    _scheduleSave();
  }

  void markAllCommentsSeen(String identity, int totalCount,
          {DateTime? latestAt}) =>
      _markComments(allCommentsKey(identity), totalCount, latestAt);

  void _markComments(String key, int count, DateTime? latestAt) {
    if (latestAt != null) {
      _commentsAt[key] = latestAt.millisecondsSinceEpoch;
    }
    _remember(key, count, _comments);
    if (latestAt != null) {
      _touched[key] = DateTime.now().millisecondsSinceEpoch;
      _scheduleSave();
      notifyListeners();
    }
  }

  bool hasNewReactions(String identity, Map<String, int> tally,
      {DateTime? uploadedAt}) {
    final seen = _reactions[identity];
    if (seen == null) {
      return uploadedAt != null &&
          uploadedAt.isAfter(_floor) &&
          tally.values.any((count) => count > 0);
    }
    for (final entry in tally.entries) {
      if (entry.value > (seen[entry.key] ?? 0)) return true;
    }
    return false;
  }

  void markImageSeen(String identity, DateTime? uploadedAt) {
    final at = uploadedAt ?? DateTime.now();
    if (_images[identity] == at.millisecondsSinceEpoch) return;
    _images[identity] = at.millisecondsSinceEpoch;
    _scheduleSave();
    notifyListeners();
  }

  void markCommentsSeen(
      String instanceId, String groupId, String identity, int count,
      {DateTime? latestAt}) {
    _markComments(commentsKey(instanceId, groupId, identity), count, latestAt);
  }

  /// Settle the across-all-groups tally, but only when no group is still
  /// unread.
  ///
  /// An image carries two tallies: one per group, for a single group's feed,
  /// and one across every group, for the feed that mixes them. Reading a
  /// thread settles only its own group, which used to leave the cross-group
  /// badge lit after the comments had plainly been read. Switching between the
  /// two feeds then showed a badge that reading could not clear.
  void markAllCommentsSeenIfCaughtUp(
      String identity, Iterable<CommentThread> threads) {
    var total = 0;
    DateTime? newest;
    for (final thread in threads) {
      if (hasNewComments(
          thread.instanceId, thread.groupId, identity, thread.count,
          latestAt: thread.latestAt)) {
        return;
      }
      total += thread.count;
      final at = thread.latestAt;
      if (at != null && (newest == null || at.isAfter(newest))) newest = at;
    }
    markAllCommentsSeen(identity, total, latestAt: newest);
  }

  void markReactionsSeen(String identity, Map<String, int> tally) {
    final seen = _reactions[identity];
    if (seen != null && mapEquals(seen, tally)) return;
    _reactions[identity] = Map<String, int>.from(tally);
    _touched[identity] = DateTime.now().millisecondsSinceEpoch;
    _scheduleSave();
    notifyListeners();
  }

  void _remember(String key, int count, Map<String, int> seen) {
    if (seen[key] == count) return;
    seen[key] = count;
    _touched[key] = DateTime.now().millisecondsSinceEpoch;
    _scheduleSave();
    notifyListeners();
  }

  /// Forget everything.
  Future<void> clear() async {
    _images.clear();
    _comments.clear();
    _commentsAt.clear();
    _reactions.clear();
    _touched.clear();
    _trackingSince = DateTime.now();
    await _save();
    notifyListeners();
  }

  /// Keep the store bounded.
  @visibleForTesting
  void prune() => _prune();

  @visibleForTesting
  int get storedImageCount => _images.length;

  void _prune() {
    final floor = _floor.millisecondsSinceEpoch;
    _images.removeWhere((_, uploadedAt) => uploadedAt < floor);
    _touched.removeWhere((key, at) {
      if (at >= floor) return false;
      _comments.remove(key);
      _commentsAt.remove(key);
      _reactions.remove(key);
      return true;
    });

    if (_images.length > _maxImages) {
      final byAge = _images.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      final dropping = byAge.take(_images.length - _maxImages);
      var raisedTo = 0;
      for (final entry in dropping) {
        _images.remove(entry.key);
        if (entry.value > raisedTo) raisedTo = entry.value;
      }
      if (raisedTo > floor) {
        _trackingSince = DateTime.fromMillisecondsSinceEpoch(raisedTo);
      }
    }

    if (_touched.length > _maxTallies) {
      final byAge = _touched.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      for (final entry in byAge.take(_touched.length - _maxTallies)) {
        _touched.remove(entry.key);
        _comments.remove(entry.key);
        _commentsAt.remove(entry.key);
        _reactions.remove(entry.key);
      }
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), _save);
  }

  Future<void> _save() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    _prune();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      prefsKey,
      jsonEncode({
        'tracking_since':
            (_trackingSince ?? DateTime.now()).millisecondsSinceEpoch,
        'images': _images,
        'comments': _comments,
        'comments_at': _commentsAt,
        'reactions': _reactions,
        'touched': _touched,
      }),
    );
  }

  @visibleForTesting
  Future<void> flush() => _save();

  @visibleForTesting
  void resetForTest({DateTime? trackingSince}) {
    _loaded = false;
    _images.clear();
    _comments.clear();
    // Left behind, this outlives the reset and answers for comments the next
    // test never marked.
    _commentsAt.clear();
    _reactions.clear();
    _touched.clear();
    _trackingSince = trackingSince;
  }
}
