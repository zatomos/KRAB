import 'package:flutter/material.dart';

import 'package:krab/widgets/auth/auth_back_button.dart';
import 'package:krab/widgets/auth/auth_card.dart';

const double authGapXS = 4;
const double authGapS = 8;
const double authGapM = 16;
const double authGapL = 24;

/// The frame the connect and login screens share.
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({
    super.key,
    required this.title,
    this.subtitle,
    required this.children,
    this.footer,
    this.success = false,
    this.onBack,
    this.showBack = true,
  });

  /// The card's heading.
  final String title;

  /// A line under the heading explaining what to do.
  final String? subtitle;

  /// The form itself, inside the card.
  final List<Widget> children;

  /// Offered below the card, outside it.
  final Widget? footer;

  /// Rings the card in green once whatever this screen asked for has worked.
  final bool success;

  /// Where back goes. Null pops and shows no button.
  final VoidCallback? onBack;

  /// False leaves the back button off however this screen was reached.
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                    horizontal: authGapM, vertical: authGapM),
                child: ConstrainedBox(
                  constraints:
                      const BoxConstraints(maxWidth: AuthCard.maxWidth),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Image.asset('logo/krab_logo.png', height: 96),
                      Text(
                        'KRAB',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                          letterSpacing: 5,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: authGapL),
                      AuthCard(
                        success: success,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              title,
                              style: theme.textTheme.headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            if (subtitle != null) ...[
                              const SizedBox(height: authGapS),
                              Text(
                                subtitle!,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                            const SizedBox(height: authGapM),
                            ...children,
                          ],
                        ),
                      ),
                      if (footer != null) ...[
                        const SizedBox(height: authGapS),
                        Center(child: footer),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            AuthBackButton(onBack: onBack, enabled: showBack),
          ],
        ),
      ),
    );
  }
}
