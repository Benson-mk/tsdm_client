import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/extensions/duration.dart';
import 'package:tsdm_client/features/packet/cubit/packet_detail_cubit.dart';
import 'package:tsdm_client/features/packet/models/models.dart';
import 'package:tsdm_client/features/packet/repository/packet_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/heroes.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// Page showing packet statistics detail data for a given thread.
class PacketDetailPage extends StatefulWidget {
  /// Constructor.
  const PacketDetailPage(this.tid, {super.key});

  /// Thread id.
  final int tid;

  @override
  State<PacketDetailPage> createState() => _PacketDetailPageState();
}

enum _SortBy { time, coinsLeast, coinsMost }

extension _LoopExt on _SortBy {
  _SortBy loopNext() => this == _SortBy.values.last ? _SortBy.values.first : _SortBy.values[index + 1];

  String loopNextTip(BuildContext context) => loopNext().tip(context);

  String tip(BuildContext context) => switch (this) {
    _SortBy.time => context.t.packetDetailPage.sort.sortByTime,
    _SortBy.coinsLeast => context.t.packetDetailPage.sort.sortByLeastCoins,
    _SortBy.coinsMost => context.t.packetDetailPage.sort.sortByMostCoins,
  };
}

class _PacketDetailPageState extends State<PacketDetailPage> {
  _SortBy _sortByCoins = _SortBy.time;

  String _nextSortTip = '';

  /// Totals of the packet (time from first to last claim, claimers, coins); tapping shows them as a sentence.
  Widget _buildSummary(BuildContext context, List<PacketDetailModel> data) {
    final tr = context.t.packetDetailPage;
    final colorScheme = Theme.of(context).colorScheme;

    final timeElapsed = data.first.time.difference(data.last.time).readable(context);
    final userCount = data.length;
    final coinsCount = data.fold(0, (prev, e) => prev + e.coins);

    Widget value(IconData icon, String text) => AppInsetBlock(
      color: colorScheme.surfaceContainerHigh,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: colorScheme.secondary, size: 16),
          sizedBoxW8H8,
          Flexible(
            child: Text(
              text,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(color: colorScheme.secondary),
            ),
          ),
        ],
      ),
    );

    return AppSurface(
      onTap: () async => showMessageSingleButtonDialog(
        context: context,
        title: tr.title,
        message: tr.statistics(users: userCount, coins: coinsCount, time: timeElapsed),
      ),
      child: Row(
        children: [
          const AppIconTile(Icons.redeem_outlined),
          sizedBoxW12H12,
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                value(Icons.timelapse_outlined, timeElapsed),
                value(Icons.person_outline, '$userCount'),
                value(FontAwesomeIcons.coins, '$coinsCount'),
                value(Icons.sort_outlined, _sortByCoins.tip(context)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(BuildContext context, List<PacketDetailModel> data) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final dataSorted = switch (_sortByCoins) {
      _SortBy.time => data.toList(),
      _SortBy.coinsLeast => data.sortedByCompare((e) => e.coins, (lhs, rhs) => lhs - rhs).toList(),
      _SortBy.coinsMost => data.sortedByCompare((e) => e.coins, (lhs, rhs) => rhs - lhs).toList(),
    };

    return AppCenteredList(
      builder: (context, side, _) => ListView.separated(
        padding: side.copyWith(top: 12, bottom: 12).add(context.safePadding()),
        itemCount: data.length + 1,
        separatorBuilder: (_, _) => appListSeparator,
        itemBuilder: (context, index) {
          if (index == 0) return _buildSummary(context, data);
          final item = dataSorted[index - 1];
          return AppSurface(
            key: ValueKey(item.id),
            padding: edgeInsetsL12T8R12B8,
            onTap: () async => context.pushNamed(ScreenPaths.profile, queryParameters: {'username': item.username}),
            child: Row(
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 32),
                  child: Text(
                    '${item.id}',
                    textAlign: TextAlign.center,
                    style: textTheme.titleMedium?.copyWith(color: colorScheme.secondary, fontWeight: FontWeight.bold),
                  ),
                ),
                sizedBoxW8H8,
                HeroUserAvatar(username: item.username, avatarUrl: null),
                sizedBoxW12H12,
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.username,
                        style: textTheme.titleSmall?.copyWith(color: colorScheme.primary, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        item.time.yyyyMMDDHHMMSS(),
                        style: textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                sizedBoxW8H8,
                AppInsetBlock(
                  color: colorScheme.secondaryContainer,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${item.coins}',
                        style: textTheme.labelLarge?.copyWith(color: colorScheme.onSecondaryContainer),
                      ),
                      sizedBoxW4H4,
                      Icon(FontAwesomeIcons.coins, size: 12, color: colorScheme.onSecondaryContainer),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _nextSortTip = _sortByCoins.loopNextTip(context);
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        RepositoryProvider(create: (_) => PacketRepository()),
        BlocProvider(
          create: (context) {
            final cubit = PacketDetailCubit(context.repo());
            unawaited(cubit.fetchDetail(widget.tid));
            return cubit;
          },
        ),
      ],
      child: BlocBuilder<PacketDetailCubit, PacketDetailState>(
        builder: (context, state) {
          final tr = context.t.packetDetailPage;

          final body = switch (state) {
            PacketDetailInitial() || PacketDetailLoading() => const CenteredCircularIndicator(),
            PacketDetailFailure() => Center(
              child: buildRetryButton(context, () async => context.read<PacketDetailCubit>().fetchDetail(widget.tid)),
            ),
            PacketDetailSuccess(:final data) when data.isEmpty => AppStateView(
              icon: Icons.redeem_outlined,
              message: context.t.general.noData,
            ),
            PacketDetailSuccess(:final data) => _buildContent(context, data),
          };

          return Scaffold(
            appBar: AppBar(
              title: Text(tr.title),
              actions: [
                IconButton(
                  icon: const Icon(Icons.sort_outlined),
                  tooltip: _nextSortTip,
                  onPressed: state is PacketDetailSuccess
                      ? () => setState(() {
                          _sortByCoins = _sortByCoins.loopNext();
                          _nextSortTip = _sortByCoins.loopNextTip(context);
                        })
                      : null,
                ),
              ],
            ),
            body: SafeArea(bottom: false, child: body),
          );
        },
      ),
    );
  }
}
