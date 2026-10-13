import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/features/homepage/widgets/user_operation_dialog.dart';
import 'package:tsdm_client/features/multi_user/cubit/current_account_cubit.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/heroes.dart';

/// The [CurrentAccountState] above [context], watched; null when no [CurrentAccountCubit] is provided.
///
/// Pages and widgets built in tests without the app's providers then show nothing extra.
CurrentAccountState? watchCurrentAccount(BuildContext context) {
  try {
    return context.watch<CurrentAccountCubit>().state;
  } on ProviderNotFoundException {
    return null;
  }
}

/// Avatar of the account in use for app bars, shown only when more than one account is saved (GitHub #184).
///
/// Tapping it opens the same user operations as the avatar on the homepage. Nothing is built otherwise.
class CurrentAccountAvatarButton extends StatelessWidget {
  /// Constructor.
  const CurrentAccountAvatarButton({super.key});

  @override
  Widget build(BuildContext context) {
    final state = watchCurrentAccount(context);
    if (state == null || !state.showsAccount) {
      return const SizedBox.shrink();
    }
    final username = state.username;
    final heroTag = 'CurrentAccount_$username';
    return IconButton(
      key: const ValueKey('current_account_avatar_button'),
      tooltip: context.t.currentAccount.tooltip(username: username),
      icon: SizedBox(
        width: 32,
        height: 32,
        child: HeroUserAvatar(
          key: ValueKey(username),
          username: username,
          avatarUrl: state.avatarUrl,
          heroTag: heroTag,
        ),
      ),
      onPressed: () async => showHeroDialog(
        context,
        (context, _, _) => UserOperationDialog(
          username: username,
          avatarUrl: state.avatarUrl,
          heroTag: heroTag,
          // Only the homepage knows the latest thread; the entry shows disabled elsewhere.
          latestThreadUrl: null,
        ),
      ),
    );
  }
}

/// Small avatar and username of the account in use, for the editors (GitHub #184).
///
/// Shown only when more than one account is saved, like [CurrentAccountAvatarButton].
class CurrentAccountChip extends StatelessWidget {
  /// Constructor.
  const CurrentAccountChip({super.key});

  @override
  Widget build(BuildContext context) {
    final state = watchCurrentAccount(context);
    if (state == null || !state.showsAccount) {
      return const SizedBox.shrink();
    }
    final username = state.username;
    return Tooltip(
      key: const ValueKey('current_account_chip'),
      message: context.t.currentAccount.postingAs(username: username),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 6,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: HeroUserAvatar(
                key: ValueKey(username),
                username: username,
                avatarUrl: state.avatarUrl,
                disableHero: true,
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 120),
              child: Text(username, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }
}
