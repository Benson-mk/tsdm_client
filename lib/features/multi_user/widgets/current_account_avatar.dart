import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/features/homepage/widgets/user_operation_dialog.dart';
import 'package:tsdm_client/features/multi_user/cubit/current_account_cubit.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/heroes.dart';

/// The [CurrentAccountState] above [context], watched (read only, outside a build, with [listen] false); null when no
/// [CurrentAccountCubit] is provided.
///
/// Pages and widgets built in tests without the app's providers then show nothing extra.
CurrentAccountState? watchCurrentAccount(BuildContext context, {bool listen = true}) {
  try {
    return listen ? context.watch<CurrentAccountCubit>().state : context.read<CurrentAccountCubit>().state;
  } on ProviderNotFoundException {
    return null;
  }
}

/// Avatar of the account in use for app bars, shown only when more than one account is saved (GitHub #184).
///
/// Tapping it opens the same user operations as the avatar on the homepage. Nothing is built otherwise.
class CurrentAccountAvatarButton extends StatelessWidget {
  /// Constructor.
  const CurrentAccountAvatarButton({this.lastAction = false, super.key});

  /// Whether the button ends the app bar actions: it then keeps the 4px gap the homepage leaves after its avatar, so
  /// the avatar sits at the same place on both pages.
  final bool lastAction;

  @override
  Widget build(BuildContext context) {
    final state = watchCurrentAccount(context);
    if (state == null || !state.showsAccount) {
      return const SizedBox.shrink();
    }
    final username = state.username;
    final button = IconButton(
      key: const ValueKey('current_account_avatar_button'),
      tooltip: context.t.currentAccount.tooltip(username: username),
      icon: SizedBox(
        width: 32,
        height: 32,
        child: HeroUserAvatar(
          key: ValueKey(username),
          username: username,
          avatarUrl: state.avatarUrl,
          // The button sits in pages kept alive off screen (the topics tab), where a hero would fly in from the
          // corner; the operations dialog does not pair with it either.
          disableHero: true,
        ),
      ),
      onPressed: () async => showHeroDialog(
        context,
        (context, _, _) => UserOperationDialog(
          username: username,
          avatarUrl: state.avatarUrl,
          heroTag: 'CurrentAccount_$username',
          // Only the homepage knows the latest thread; the entry shows disabled elsewhere.
          latestThreadUrl: null,
        ),
      ),
    );
    if (!lastAction) {
      return button;
    }
    return Padding(padding: const EdgeInsets.only(right: 4), child: button);
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

/// The [PostingAsBar] for an app bar `bottom`, or null when it is not shown (one saved account, not logged in).
///
/// Watches the account, so the bar appears, disappears and renames itself on account changes.
PreferredSizeWidget? postingAsBarOf(BuildContext context) {
  final account = watchCurrentAccount(context);
  if (account == null || !account.showsAccount) {
    return null;
  }
  return PostingAsBar(username: account.username, avatarUrl: account.avatarUrl);
}

/// A line under the app bar title of an editor naming the account the post goes out as (#184).
///
/// Users with several saved accounts sometimes posted with the wrong one. A line of its own keeps the title and the
/// action buttons their room on a narrow phone, like the peer line of the chat pages. Build it with
/// [postingAsBarOf].
class PostingAsBar extends StatelessWidget implements PreferredSizeWidget {
  /// Constructor.
  const PostingAsBar({required this.username, required this.avatarUrl, super.key});

  /// Name of the account in use.
  final String username;

  /// Avatar of the account in use on the forum.
  final String? avatarUrl;

  /// Height of the line.
  static const height = 36.0;

  @override
  Size get preferredSize => const Size.fromHeight(height);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // A fixed height line: large fonts are clamped a little so the line is not cut, like the chat peer line.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.2,
      child: SizedBox(
        key: const ValueKey('posting-as-bar'),
        height: height,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            spacing: 6,
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: HeroUserAvatar(
                  key: ValueKey(username),
                  username: username,
                  avatarUrl: avatarUrl,
                  disableHero: true,
                ),
              ),
              Flexible(
                child: Text(
                  context.t.currentAccount.postingAs(username: username),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
