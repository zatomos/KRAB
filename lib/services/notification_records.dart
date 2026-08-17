import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Bookkeeping about the notifications this device has posted, keyed by
/// notification id and kept in SharedPreferences.
abstract class NotificationRecordStore<T> {
  String get prefsKey;
  Duration get maxAge;

  /// When the notification this record describes was last posted.
  DateTime timestampOf(T record);

  Map<String, dynamic> toJson(T record);

  /// Reads one entry back, or null when it cannot be understood.
  T? fromJson(Object? raw);

  Future<void> _tail = Future.value();

  /// Runs bodies one after another.
  Future<R> serialized<R>(Future<R> Function() body) {
    final result = _tail.then((_) => body());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<Map<int, T>> readAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();

    final raw = prefs.getString(prefsKey);
    if (raw == null || raw.isEmpty) return {};

    final entries = <int, T>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final cutoff = DateTime.now().subtract(maxAge);
      for (final entry in decoded.entries) {
        final id = int.tryParse(entry.key.toString());
        final value = fromJson(entry.value);
        if (id == null || value == null) continue;
        if (timestampOf(value).isBefore(cutoff)) continue;
        entries[id] = value;
      }
    } catch (e) {
      debugPrint('notif: unreadable $prefsKey: $e');
      return {};
    }
    return entries;
  }

  Future<T?> read(int id) async => (await readAll())[id];

  /// Record what the notification now says, replacing any earlier record of it.
  Future<void> record(int id, T entry) async {
    final entries = await readAll();
    entries[id] = entry;
    await writeAll(entries);
  }

  Future<void> forget(Iterable<int> ids) async {
    if (ids.isEmpty) return;
    final entries = await readAll();
    var changed = false;
    for (final id in ids) {
      if (entries.remove(id) != null) changed = true;
    }
    if (changed) await writeAll(entries);
  }

  Future<void> writeAll(Map<int, T> entries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      prefsKey,
      jsonEncode({
        for (final entry in entries.entries) '${entry.key}': toJson(entry.value)
      }),
    );
  }
}

/// The entries of a stored list that could still be read back.
List<T> _readList<T>(List<Object?>? raw, T? Function(Object?) parse) {
  final entries = <T>[];
  for (final item in raw ?? const []) {
    final parsed = parse(item);
    if (parsed != null) entries.add(parsed);
  }
  return entries;
}

/// One comment shown by an image's comment notification.
class ThreadMessage {
  const ThreadMessage({
    required this.authorId,
    required this.authorUsername,
    required this.text,
    required this.at,
  });

  final String authorId;
  final String authorUsername;
  final String text;
  final DateTime at;

  Map<String, dynamic> toJson() => {
        'author_id': authorId,
        'author_username': authorUsername,
        'text': text,
        'at': at.toIso8601String(),
      };

  static ThreadMessage? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final at = DateTime.tryParse(raw['at']?.toString() ?? '');
    if (at == null) return null;
    return ThreadMessage(
      authorId: raw['author_id']?.toString() ?? '',
      authorUsername: raw['author_username']?.toString() ?? '',
      text: raw['text']?.toString() ?? '',
      at: at,
    );
  }
}

/// Every comment one notification is showing for one image in one group.
class CommentThread {
  const CommentThread({
    required this.instanceId,
    required this.groupId,
    required this.groupName,
    required this.imageId,
    required this.messages,
    required this.shownAt,
    this.uploaderUsername = '',
    this.uploaderIsMe = false,
  });

  final String instanceId;
  final String groupId;
  final String groupName;
  final String imageId;

  /// Oldest first.
  final List<ThreadMessage> messages;

  final DateTime shownAt;
  final String uploaderUsername;
  final bool uploaderIsMe;

  /// How many comments a thread notification shows before dropping the oldest.
  static const int maxMessages = 8;

  Map<String, dynamic> toJson() => {
        'instance_id': instanceId,
        'group_id': groupId,
        'group_name': groupName,
        'image_id': imageId,
        'messages': [for (final m in messages) m.toJson()],
        'shown_at': shownAt.toIso8601String(),
        if (uploaderUsername.isNotEmpty) 'uploader_username': uploaderUsername,
        if (uploaderIsMe) 'uploader_is_me': true,
      };

  static CommentThread? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final shownAt = DateTime.tryParse(raw['shown_at']?.toString() ?? '');
    if (shownAt == null) return null;
    return CommentThread(
      instanceId: raw['instance_id']?.toString() ?? '',
      groupId: raw['group_id']?.toString() ?? '',
      groupName: raw['group_name']?.toString() ?? '',
      imageId: raw['image_id']?.toString() ?? '',
      messages: _readList((raw['messages'] as List?), ThreadMessage.fromJson),
      shownAt: shownAt,
      uploaderUsername: raw['uploader_username']?.toString() ?? '',
      uploaderIsMe: raw['uploader_is_me'] == true,
    );
  }

  CommentThread withMessage(ThreadMessage arriving) {
    final kept = [
      for (final message in messages)
        if (!_isSame(message, arriving)) message,
      arriving,
    ];
    kept.sort((a, b) => a.at.compareTo(b.at));

    return CommentThread(
      instanceId: instanceId,
      groupId: groupId,
      groupName: groupName,
      imageId: imageId,
      messages: kept.length > maxMessages
          ? kept.sublist(kept.length - maxMessages)
          : kept,
      shownAt: DateTime.now(),
      uploaderUsername: uploaderUsername,
      uploaderIsMe: uploaderIsMe,
    );
  }

  /// Two deliveries of one comment.
  static bool _isSame(ThreadMessage a, ThreadMessage b) =>
      a.authorId == b.authorId &&
      a.text == b.text &&
      a.at.difference(b.at).abs() < const Duration(seconds: 1);

  /// The people in the thread, newest comment first, each named once.
  List<({String id, String username})> get participants {
    final seen = <String>{};
    final people = <({String id, String username})>[];
    for (final message in messages.reversed) {
      if (!seen.add(message.authorId)) continue;
      people.add((id: message.authorId, username: message.authorUsername));
    }
    return people;
  }
}

/// The comment threads on screen, by notification id.
class CommentThreads extends NotificationRecordStore<CommentThread> {
  CommentThreads._();
  static final CommentThreads instance = CommentThreads._();

  static const String storeKey = 'krab_comment_threads';
  static const Duration storeMaxAge = Duration(days: 2);

  @override
  String get prefsKey => storeKey;

  @override
  Duration get maxAge => storeMaxAge;

  @override
  DateTime timestampOf(CommentThread record) => record.shownAt;

  @override
  Map<String, dynamic> toJson(CommentThread record) => record.toJson();

  @override
  CommentThread? fromJson(Object? raw) => CommentThread.fromJson(raw);

  /// The ids of the threads about one image.
  Future<List<int>> idsForImage(String imageId) async {
    if (imageId.isEmpty) return const [];
    final entries = await readAll();
    return [
      for (final entry in entries.entries)
        if (entry.value.imageId == imageId) entry.key
    ];
  }
}

/// One person's reaction to an image.
class ReactionEntry {
  const ReactionEntry({
    required this.reactorId,
    required this.reactorUsername,
    required this.emoji,
    required this.at,
  });

  final String reactorId;
  final String reactorUsername;
  final String emoji;
  final DateTime at;

  Map<String, dynamic> toJson() => {
        'reactor_id': reactorId,
        'reactor_username': reactorUsername,
        'emoji': emoji,
        'at': at.toIso8601String(),
      };

  static ReactionEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final at = DateTime.tryParse(raw['at']?.toString() ?? '');
    if (at == null) return null;
    return ReactionEntry(
      reactorId: raw['reactor_id']?.toString() ?? '',
      reactorUsername: raw['reactor_username']?.toString() ?? '',
      emoji: raw['emoji']?.toString() ?? '',
      at: at,
    );
  }
}

/// Every reaction one notification is showing for one image.
class ReactionTally {
  const ReactionTally({
    required this.instanceId,
    required this.imageId,
    required this.reactions,
    required this.shownAt,
    this.uploaderUsername = '',
  });

  final String instanceId;
  final String imageId;

  /// Oldest first.
  final List<ReactionEntry> reactions;

  final DateTime shownAt;
  final String uploaderUsername;

  /// How many reactors a notification names before dropping the oldest.
  static const int maxReactions = 8;

  Map<String, dynamic> toJson() => {
        'instance_id': instanceId,
        'image_id': imageId,
        'reactions': [for (final r in reactions) r.toJson()],
        'shown_at': shownAt.toIso8601String(),
        if (uploaderUsername.isNotEmpty) 'uploader_username': uploaderUsername,
      };

  static ReactionTally? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final shownAt = DateTime.tryParse(raw['shown_at']?.toString() ?? '');
    if (shownAt == null) return null;
    return ReactionTally(
      instanceId: raw['instance_id']?.toString() ?? '',
      imageId: raw['image_id']?.toString() ?? '',
      reactions: _readList((raw['reactions'] as List?), ReactionEntry.fromJson),
      shownAt: shownAt,
      uploaderUsername: raw['uploader_username']?.toString() ?? '',
    );
  }

  ReactionTally withReaction(ReactionEntry arriving) {
    final kept = [
      for (final reaction in reactions)
        if (reaction.reactorId != arriving.reactorId) reaction,
      arriving,
    ];

    return ReactionTally(
      instanceId: instanceId,
      imageId: imageId,
      reactions: kept.length > maxReactions
          ? kept.sublist(kept.length - maxReactions)
          : kept,
      shownAt: DateTime.now(),
      uploaderUsername: uploaderUsername,
    );
  }

  List<ReactionEntry> get newestFirst => reactions.reversed.toList();
}

/// The reaction notifications on screen, by notification id.
class ReactionTallies extends NotificationRecordStore<ReactionTally> {
  ReactionTallies._();
  static final ReactionTallies instance = ReactionTallies._();

  static const String storeKey = 'krab_reaction_tallies';
  static const Duration storeMaxAge = Duration(days: 2);

  @override
  String get prefsKey => storeKey;

  @override
  Duration get maxAge => storeMaxAge;

  @override
  DateTime timestampOf(ReactionTally record) => record.shownAt;

  @override
  Map<String, dynamic> toJson(ReactionTally record) => record.toJson();

  @override
  ReactionTally? fromJson(Object? raw) => ReactionTally.fromJson(raw);
}
