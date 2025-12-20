import 'package:flutter/material.dart';
import 'package:krab/l10n/l10n.dart';

String timeAgoShort(BuildContext context, DateTime date) {
  final now = DateTime.now();
  final diff = now.difference(date);

  if (diff.inMinutes < 1) return context.l10n.just_now;
  if (diff.inMinutes < 60) return context.l10n.minutes_ago(diff.inMinutes);
  if (diff.inHours < 24) return context.l10n.hours_ago(diff.inHours);
  if (diff.inDays < 7) return context.l10n.days_ago(diff.inDays);
  if (diff.inDays < 30) {
    return context.l10n.weeks_ago((diff.inDays / 7).floor());
  }

  return context.l10n.months_ago((diff.inDays / 30).floor());
}

String timeAgoLong(BuildContext context, DateTime date) {
  final now = DateTime.now();
  final diff = now.difference(date);

  if (diff.inMinutes < 1) return context.l10n.just_now;
  if (diff.inMinutes < 60) return context.l10n.time_ago(context.l10n.minutes_ago(diff.inMinutes));
  if (diff.inHours < 24) return context.l10n.time_ago(context.l10n.hours_ago(diff.inHours));
  if (diff.inDays < 7) return context.l10n.time_ago(context.l10n.days_ago(diff.inDays));
  if (diff.inDays < 30) {
    return context.l10n.time_ago(context.l10n.weeks_ago((diff.inDays / 7).floor()));
  }

  return context.l10n.time_ago(context.l10n.months_ago((diff.inDays / 30).floor()));
}