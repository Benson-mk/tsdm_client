import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// The moderators of a forum group, as the site lists them in the group header ("分区版主: a, b"), GitHub #22.
///
/// Tapping a name opens that user's profile.
class GroupModeratorsRow extends StatelessWidget {
  /// Constructor.
  const GroupModeratorsRow({required this.moderators, this.large = false, super.key});

  /// Moderator names, in the site's order.
  final List<String> moderators;

  /// Bigger icon, label and chips, matching the large forum cards of the wide topics page.
  final bool large;

  @override
  Widget build(BuildContext context) {
    if (moderators.isEmpty) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    // A tinted block above the forum cards of the group (the list already gives the side padding): shield icon,
    // label, one rounded chip per name.
    return Padding(
      padding: EdgeInsets.only(bottom: large ? 12 : 8),
      child: AppInsetBlock(
        outlined: true,
        padding: large ? const EdgeInsets.symmetric(horizontal: 16, vertical: 12) : edgeInsetsL12T8R12B8,
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: large ? 8 : 6,
          runSpacing: large ? 6 : 4,
          children: [
            Icon(Icons.admin_panel_settings_outlined, size: large ? 22 : 18, color: scheme.primary),
            Text(
              context.t.topicsPage.moderators,
              style: (large ? textTheme.titleSmall : textTheme.labelMedium)?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
            for (final name in moderators)
              ActionChip(
                avatar: Icon(Icons.person_outline, size: large ? 18 : 16, color: scheme.onSurfaceVariant),
                label: Text(name),
                visualDensity: large ? VisualDensity.standard : VisualDensity.compact,
                padding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(appInnerRadius)),
                labelStyle: large ? textTheme.labelLarge : textTheme.labelMedium,
                onPressed: () async =>
                    context.pushNamed(ScreenPaths.profile, queryParameters: <String, String>{'username': name}),
              ),
          ],
        ),
      ),
    );
  }
}
