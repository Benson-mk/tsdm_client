import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// Widget showing a bounty info in thread.
class BountyCard extends StatelessWidget {
  /// Constructor.
  const BountyCard({required this.resolved, required this.price, super.key});

  /// Flag indicating the bounty state.
  ///
  /// Is resolved or not.
  final bool resolved;

  /// Price of this bounty.
  final String price;

  @override
  Widget build(BuildContext context) {
    final secondaryColor = Theme.of(context).colorScheme.secondary;
    final tertiaryColor = Theme.of(context).colorScheme.tertiary;
    final bountyStatusTextStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(color: tertiaryColor);
    final bountyStatusTextResolvedStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(color: secondaryColor);

    // Bounty status.
    late final Widget bountyStatusWidget;
    if (resolved) {
      bountyStatusWidget = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.done, color: secondaryColor),
          sizedBoxW4H4,
          Flexible(child: Text(context.t.bountyCard.resolved, style: bountyStatusTextResolvedStyle)),
        ],
      );
    } else {
      bountyStatusWidget = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.pending, color: tertiaryColor),
          sizedBoxW4H4,
          Flexible(child: Text(context.t.bountyCard.processing, style: bountyStatusTextStyle)),
        ],
      );
    }

    // State (resolved / in progress) under the title, the reward as a highlighted line; both wrap with large text.
    return AppEmbedCard(
      icon: Icons.emoji_events_outlined,
      title: context.t.bountyCard.title,
      margin: EdgeInsets.zero,
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          bountyStatusWidget,
          AppInsetBlock(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(FontAwesomeIcons.coins, size: 18, color: Theme.of(context).colorScheme.primary),
                sizedBoxW8H8,
                Flexible(
                  child: Text(context.t.bountyCard.price(price: price), style: Theme.of(context).textTheme.bodyLarge),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
