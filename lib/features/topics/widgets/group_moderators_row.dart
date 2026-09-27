import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// The moderators of a forum group, as the site lists them in the group header ("分区版主: a, b"), GitHub #22.
///
/// Tapping a name opens that user's profile.
class GroupModeratorsRow extends StatelessWidget {
  /// Constructor.
  const GroupModeratorsRow({required this.moderators, super.key});

  /// Moderator names, in the site's order.
  final List<String> moderators;

  @override
  Widget build(BuildContext context) {
    if (moderators.isEmpty) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    // A tinted block above the forum cards of the group (the list already gives the side padding): shield icon,
    // label, one rounded chip per name.
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppInsetBlock(
        outlined: true,
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6,
          runSpacing: 4,
          children: [
            Icon(Icons.admin_panel_settings_outlined, size: 18, color: scheme.primary),
            Text(
              context.t.topicsPage.moderators,
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: scheme.primary, fontWeight: FontWeight.bold),
            ),
            for (final name in moderators)
              ActionChip(
                avatar: Icon(Icons.person_outline, size: 16, color: scheme.onSurfaceVariant),
                label: Text(name),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(appInnerRadius)),
                labelStyle: Theme.of(context).textTheme.labelMedium,
                onPressed: () async =>
                    context.pushNamed(ScreenPaths.profile, queryParameters: <String, String>{'username': name}),
              ),
          ],
        ),
      ),
    );
  }
}
