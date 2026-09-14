import 'package:flutter/material.dart';
import 'package:krab/l10n/l10n.dart';

/// How long ago the date was, as a bare span.
String? _spanSince(BuildContext context, DateTime date) {
  final diff = DateTime.now().difference(date);
  final l10n = context.l10n;

  if (diff.inMinutes < 1) return null;
  if (diff.inMinutes < 60) return l10n.minutes_ago(diff.inMinutes);
  if (diff.inHours < 24) return l10n.hours_ago(diff.inHours);
  if (diff.inDays < 7) return l10n.days_ago(diff.inDays);
  if (diff.inDays < 30) return l10n.weeks_ago((diff.inDays / 7).floor());
  return l10n.months_ago((diff.inDays / 30).floor());
}

String timeAgoShort(BuildContext context, DateTime date) =>
    _spanSince(context, date) ?? context.l10n.just_now;

String timeAgoLong(BuildContext context, DateTime date) {
  final span = _spanSince(context, date);
  return span == null ? context.l10n.just_now : context.l10n.time_ago(span);
}
