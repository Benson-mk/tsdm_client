import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/poll/cubit/poll_cubit.dart';
import 'package:tsdm_client/features/poll/models/forum_poll.dart';
import 'package:tsdm_client/features/poll/repository/poll_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// Ordinary poll embedded in the first post, shared by both thread readers.
class PollCard extends StatefulWidget {
  /// [controller] permits deterministic UI tests; production creates its own.
  const PollCard(this.pid, {super.key, this.controller});

  /// First post identifier used by the forum redirect route.
  final String pid;

  /// Optional test controller, owned by its caller.
  final PollCubit? controller;
  @override
  State<PollCard> createState() => _PollCardState();
}

class _PollCardState extends State<PollCard> {
  late PollCubit _cubit;
  StreamSubscription<AuthStatus>? _authSubscription;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    if (widget.controller case final controller?) {
      _cubit = controller;
    } else {
      final auth = context.read<AuthenticationRepository>();
      _cubit = PollCubit(
        url: '$baseUrl/forum.php?mod=redirect&goto=findpost&pid=${Uri.encodeQueryComponent(widget.pid)}',
        currentUid: () => auth.effectiveCurrentUid,
        repository: () => PollRepository.network(getIt.get<NetClientProvider>()),
      );
      _authSubscription = auth.status.listen((status) {
        _cubit.invalidate();
        if (status is! AuthStatusLoading) unawaited(_cubit.load());
      });
    }
    unawaited(_cubit.load());
  }

  @override
  void didUpdateWidget(PollCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pid != widget.pid || oldWidget.controller != widget.controller) {
      unawaited(_authSubscription?.cancel());
      if (oldWidget.controller == null) unawaited(_cubit.close());
      _start();
    }
  }

  @override
  void dispose() {
    unawaited(_authSubscription?.cancel());
    if (widget.controller == null) unawaited(_cubit.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => BlocBuilder<PollCubit, PollState>(
    bloc: _cubit,
    builder: (context, state) {
      final tr = context.t.pollVoting;
      final poll = state.poll;
      final colorScheme = Theme.of(context).colorScheme;
      final textTheme = Theme.of(context).textTheme;
      // Header: title, deadline under it, a spinner while busy. Status lines are banners, choices in the middle,
      // actions at the bottom.
      return AppEmbedCard(
        icon: Icons.poll_outlined,
        title: context.t.pollCard.title,
        subtitle: (poll?.deadline.isNotEmpty ?? false) ? poll!.deadline : null,
        trailing: state.busy ? const SizedBox(width: 20, height: 20, child: CircularIndicator()) : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (state.submissionUnconfirmed)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: AppNoticeBanner(tone: AppNoticeTone.warning, icon: Icons.help_outline, message: tr.unconfirmed),
              ),
            if (state.failed)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: AppNoticeBanner(tone: AppNoticeTone.error, message: context.t.general.failedToLoad),
              ),
            if (poll != null) ...[
              if (poll.summary.isNotEmpty) Text(poll.summary, style: textTheme.bodyMedium),
              if (poll.availability == PollAvailability.available)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    tr.selection(count: state.choices.length, max: poll.maxChoices!),
                    style: textTheme.labelMedium?.copyWith(color: colorScheme.primary),
                  ),
                ),
              if (poll.availability == PollAvailability.available && poll.maxChoices == 1)
                RadioGroup<String>(
                  groupValue: state.choices.firstOrNull,
                  onChanged: (value) {
                    if (value != null) _cubit.select(value, selected: true);
                  },
                  child: Column(
                    children: [
                      for (final option in poll.options)
                        RadioListTile<String>(
                          value: option.id!,
                          enabled: !state.busy,
                          contentPadding: EdgeInsets.zero,
                          title: Text(option.label),
                          subtitle: option.result == null ? null : Text(option.result!),
                        ),
                    ],
                  ),
                )
              else ...[
                for (final option in poll.options)
                  if (poll.availability == PollAvailability.available && option.id != null)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(option.label),
                      subtitle: option.result == null ? null : Text(option.result!),
                      value: state.choices.contains(option.id),
                      onChanged:
                          state.busy ||
                              (poll.maxChoices != 1 &&
                                  !state.choices.contains(option.id) &&
                                  state.choices.length >= poll.maxChoices!)
                          ? null
                          : (value) => _cubit.select(option.id!, selected: value ?? false),
                    )
                  else
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(option.label),
                      subtitle: option.result == null ? null : Text(option.result!),
                    ),
              ],
              if (poll.notice.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: AppNoticeBanner(message: poll.notice),
                ),
              if (poll.availability != PollAvailability.available)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: AppNoticeBanner(
                    icon: switch (poll.availability) {
                      PollAvailability.voted => Icons.how_to_vote_outlined,
                      PollAvailability.closed => Icons.lock_outline,
                      PollAvailability.loginRequired => Icons.login_outlined,
                      _ => Icons.info_outline,
                    },
                    message: switch (poll.availability) {
                      PollAvailability.voted => tr.voted,
                      PollAvailability.closed => tr.closed,
                      PollAvailability.loginRequired => tr.loginRequired,
                      PollAvailability.denied => tr.denied,
                      _ => tr.unsupported,
                    },
                  ),
                ),
            ],
            sizedBoxW8H8,
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (poll?.availability == PollAvailability.available)
                  // Plain constructor on purpose: the only FilledButton of the card (widget tests look it up by type).
                  FilledButton(
                    onPressed: state.busy || !poll!.accepts(state.choices) ? null : _cubit.submit,
                    child: Text(tr.submit),
                  ),
                if (poll?.availability == PollAvailability.loginRequired)
                  TextButton(
                    onPressed: () async {
                      await context.pushNamed(ScreenPaths.login);
                      if (mounted) await _cubit.load();
                    },
                    child: Text(tr.loginRequired),
                  ),
                TextButton.icon(
                  onPressed: state.busy ? null : _cubit.load,
                  icon: const Icon(Icons.refresh),
                  label: Text(tr.refresh),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.open_in_browser_outlined),
                  label: Text(context.t.pollCard.openInBrowser),
                  onPressed: () async => context.dispatchAsUrl(_cubit.url, external: true),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}
