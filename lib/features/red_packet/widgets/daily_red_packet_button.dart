import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/red_packet/models/models.dart';
import 'package:tsdm_client/features/red_packet/repository/red_packet_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// Claims today's daily red packet with [formHash], e.g. [RedPacketRepository.claimDaily].
typedef DailyRedPacketClaim = AsyncEither<DailyRedPacketResult> Function(String formHash);

/// App bar button claiming today's daily red packet.
///
/// Shown while the homepage carries the daily red packet config. Once claimed (or when the server says it was already
/// claimed today) the icon button hides itself and the [labeled] one shows the claimed state; neither submits again.
class DailyRedPacketButton extends StatefulWidget {
  /// Constructor.
  const DailyRedPacketButton({
    required this.config,
    required this.formHash,
    this.repository = const RedPacketRepository(),
    this.claim,
    this.labeled = false,
    super.key,
  });

  /// Show a tonal button with a label instead of an icon button, e.g. on the homepage greeting card.
  final bool labeled;

  /// Today's packet.
  final DailyRedPacketConfig config;

  /// Form hash of the current session.
  final String formHash;

  /// Repository talking to the plugin.
  final RedPacketRepository repository;

  /// Claim request, [RedPacketRepository.claimDaily] of [repository] when null (tests pass a fake).
  final DailyRedPacketClaim? claim;

  @override
  State<DailyRedPacketButton> createState() => _DailyRedPacketButtonState();
}

class _DailyRedPacketButtonState extends State<DailyRedPacketButton> with LoggerMixin {
  bool _claiming = false;
  bool _claimed = false;

  AsyncEither<DailyRedPacketResult> _claimWithRepository(String formHash) =>
      widget.repository.claimDaily(formHash: formHash);

  Future<void> _claim() async {
    // One request at a time, none after the server confirmed the claim: a second tap in the same frame (before the
    // button is rebuilt disabled) does nothing.
    if (_claiming || _claimed) {
      return;
    }
    final tr = context.t.redPacket.daily;
    setState(() => _claiming = true);
    final request = widget.claim ?? _claimWithRepository;
    final result = await request(widget.formHash).run();
    if (!mounted) {
      return;
    }
    final String message;
    var claimed = false;
    switch (result) {
      case Left(:final value):
        handle(value);
        message = tr.failed(err: value.message ?? '$value');
      case Right(:final value) when value.ok:
        message = tr.claimed(amount: value.amount ?? '?', unit: value.unit ?? widget.config.unit);
        claimed = true;
      case Right(:final value) when value.already:
        message = value.error ?? tr.alreadyClaimed;
        claimed = true;
      case Right(:final value):
        message = tr.failed(err: value.error ?? '');
    }
    setState(() {
      _claiming = false;
      _claimed = claimed;
    });
    showSnackBar(context: context, message: message);
  }

  @override
  Widget build(BuildContext context) {
    final tooltip = context.t.redPacket.daily.tooltip;
    if (_claimed) {
      return widget.labeled ? const DailyRedPacketClaimedButton() : sizedBoxEmpty;
    }
    if (widget.labeled) {
      return FilledButton.tonalIcon(
        style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
        icon: _claiming ? sizedCircularProgressIndicator : const Icon(Icons.redeem_outlined),
        label: Text(tooltip),
        onPressed: _claiming ? null : _claim,
      );
    }
    if (_claiming) {
      return IconButton(icon: sizedCircularProgressIndicator, tooltip: tooltip, onPressed: null);
    }
    return IconButton(icon: const Icon(Icons.redeem_outlined), tooltip: tooltip, onPressed: _claim);
  }
}

/// Today's daily red packet is claimed: a disabled button saying so.
class DailyRedPacketClaimedButton extends StatelessWidget {
  /// Constructor.
  const DailyRedPacketClaimedButton({super.key});

  @override
  Widget build(BuildContext context) => FilledButton.tonalIcon(
    style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
    icon: const Icon(Icons.task_alt_outlined),
    label: Text(context.t.redPacket.daily.claimedToday),
    onPressed: null,
  );
}

/// The daily red packet entry of the homepage greeting, always visible with an honest state.
///
/// * No account: says a login is needed and opens the login page.
/// * A packet ([config]) and a [formHash] on the homepage: [DailyRedPacketButton], the real claim flow; it shows the
///   claimed state once the server answered "claimed" or "already claimed" for that packet.
/// * No packet: "none now" and a tap checks the packet again ([onCheck], only the packet of the greeting card is
///   updated, never a reload of the whole homepage); the tooltip says it may be claimed already or not open yet. An
///   empty page may also mean the plugin is off or the page was incomplete, and the app has no source for the forum's
///   day (no time zone of the site in the repo), so a page without a packet is never shown as "claimed today".
///
/// The labels are short enough for one line in the half-width button of phones; the full explanation is the tooltip.
class DailyRedPacketEntry extends StatelessWidget {
  /// Constructor.
  const DailyRedPacketEntry({
    required this.uid,
    required this.config,
    required this.formHash,
    required this.onCheck,
    this.checking = false,
    this.claim,
    super.key,
  });

  /// Logged in account, null without one.
  final int? uid;

  /// Today's packet from the homepage, null when the page had none.
  final DailyRedPacketConfig? config;

  /// Form hash of the homepage.
  final String? formHash;

  /// Check whether the forum offers a packet now, updating only this entry.
  final VoidCallback? onCheck;

  /// A check started by [onCheck] is running: the entry waits for it instead of starting another one.
  final bool checking;

  /// Claim request for [DailyRedPacketButton.claim].
  final DailyRedPacketClaim? claim;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.redPacket.daily;
    final uid = this.uid;
    final config = this.config;
    final formHash = this.formHash;
    if (uid == null) {
      return OutlinedButton.icon(
        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
        icon: const Icon(Icons.login_outlined),
        label: Text(tr.needLogin),
        onPressed: () async => context.pushNamed(ScreenPaths.login),
      );
    }
    if (config != null && formHash != null && formHash.isNotEmpty) {
      return DailyRedPacketButton(
        // A new account or a new day starts a new button: nothing of the previous claim state carries over.
        key: ValueKey('dailyRedPacket-$uid-${config.dateFlag}'),
        config: config,
        formHash: formHash,
        claim: claim,
        labeled: true,
      );
    }
    return Tooltip(
      message: tr.unavailableHint,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
        icon: checking ? sizedCircularProgressIndicator : const Icon(Icons.redeem_outlined),
        label: Text(tr.unavailable),
        onPressed: checking ? null : onCheck,
      ),
    );
  }
}
