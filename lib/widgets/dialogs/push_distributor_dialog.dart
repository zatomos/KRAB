import 'package:flutter/material.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/services/push_helper.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/widgets/soft_button.dart';

/// Lets the user choose which UnifiedPush distributor delivers their pushes.
class PushDistributorDialog extends StatefulWidget {
  const PushDistributorDialog({super.key});

  @override
  State<PushDistributorDialog> createState() => _PushDistributorDialogState();
}

class _PushDistributorDialogState extends State<PushDistributorDialog> {
  List<String>? _distributors;
  String? _current;
  bool _switching = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final distributors = await PushHelper.availableDistributors();
    final current = await PushHelper.currentDistributor();
    if (!mounted) return;
    setState(() {
      _distributors = distributors;
      _current = current;
    });
  }

  Future<void> _select(String distributor) async {
    if (_switching || distributor == _current) return;
    setState(() {
      _switching = true;
      _error = null;
    });

    final ok = await PushHelper.useDistributor(distributor);
    if (!mounted) return;

    if (!ok) {
      setState(() {
        _switching = false;
        _error = context.l10n.push_distributor_failed;
      });
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final distributors = _distributors;

    return AlertDialog(
      title: Text(context.l10n.push_distributor_title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.l10n.push_distributor_description),
          const SizedBox(height: 12),
          if (distributors == null)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (distributors.isEmpty)
            Text(
              context.l10n.push_distributor_none,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
              ),
            )
          else
            IgnorePointer(
              ignoring: _switching,
              child: RadioGroup<String>(
                groupValue: _current,
                onChanged: (v) => _select(v!),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final d in distributors)
                      RadioListTile<String>(
                        value: d,
                        title: Text(d, style: const TextStyle(fontSize: 14)),
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                      ),
                  ],
                ),
              ),
            ),
          if (_switching)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
      actionsOverflowButtonSpacing:
          GlobalThemeData.dialogActionsOverflowSpacing,
      actions: [
        SoftButton(
          onPressed: _switching ? () {} : () => Navigator.of(context).pop(),
          label: context.l10n.close,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ],
    );
  }
}
