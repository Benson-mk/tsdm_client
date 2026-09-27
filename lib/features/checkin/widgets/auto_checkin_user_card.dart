import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// Card to show auto checkin info.
class AutoCheckinUserCard extends StatelessWidget {
  /// Constructor.
  const AutoCheckinUserCard(this.userInfo, this.message, {this.failure, super.key});

  /// User info to display.
  final UserLoginInfo userInfo;

  /// Optional message describes checkin result.
  final String? message;

  /// Flag indicating a success login or not.
  final bool? failure;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    // null: waiting or running, false: done (checked in or already checked), true: failed.
    final (IconData icon, Color tile, Color onTile) = switch (failure) {
      true => (Icons.error_outline, colorScheme.errorContainer, colorScheme.onErrorContainer),
      false => (Icons.check_circle_outline, colorScheme.primaryContainer, colorScheme.onPrimaryContainer),
      null => (Icons.schedule_outlined, colorScheme.surfaceContainerHighest, colorScheme.onSurfaceVariant),
    };
    final username = userInfo.username ?? '';

    return AppSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(child: Text(username.isEmpty ? '?' : username.characters.first)),
              sizedBoxW12H12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(username, style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                    Text(
                      'UID ${userInfo.uid ?? '-'}',
                      style: textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              sizedBoxW8H8,
              AppIconTile(icon, size: 32, color: tile, foregroundColor: onTile),
            ],
          ),
          if (message != null) ...[
            sizedBoxW8H8,
            AppInsetBlock(
              color: failure ?? false ? colorScheme.errorContainer : null,
              child: Text(
                message!,
                style: textTheme.bodySmall?.copyWith(
                  color: failure ?? false ? colorScheme.onErrorContainer : colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
