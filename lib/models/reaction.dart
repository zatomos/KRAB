/// An aggregated tally for a single emoji on an image within one group.
class ReactionSummary {
  final String emoji;

  /// How many group members reacted with this emoji.
  final int count;

  /// Whether the current user is one of them.
  final bool reactedByMe;

  const ReactionSummary({
    required this.emoji,
    required this.count,
    required this.reactedByMe,
  });

  ReactionSummary copyWith({int? count, bool? reactedByMe}) => ReactionSummary(
        emoji: emoji,
        count: count ?? this.count,
        reactedByMe: reactedByMe ?? this.reactedByMe,
      );

  static ReactionSummary fromJson(Map<String, dynamic> json) => ReactionSummary(
        emoji: json['emoji']?.toString() ?? '',
        count: (json['count'] as num?)?.toInt() ?? 0,
        reactedByMe: json['reacted_by_me'] == true,
      );
}
