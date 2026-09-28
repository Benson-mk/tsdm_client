import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/list.dart';
import 'package:tsdm_client/features/points/bloc/points_bloc.dart';
import 'package:tsdm_client/features/points/repository/points_repository.dart';
import 'package:tsdm_client/features/points/widgets/points_card.dart';
import 'package:tsdm_client/features/points/widgets/points_query_form.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// Page to show current logged user's points statistics and changelog.
class PointsPage extends StatefulWidget {
  /// Constructor
  const PointsPage({super.key});

  @override
  State<PointsPage> createState() => _PointsPageState();
}

class _PointsPageState extends State<PointsPage> with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late final EasyRefreshController _statisticsRefreshController;
  late final ScrollController _statisticsScrollController;
  late final EasyRefreshController _changelogRefreshController;
  late final ScrollController _changelogScrollController;

  Widget _buildStatisticsTab(BuildContext context, PointsStatisticsState state) {
    if (state.status == PointsStatus.loading) {
      return const CenteredCircularIndicator();
    }
    _statisticsRefreshController.finishRefresh();

    final attrList = state.pointsMap.entries.toList();

    return EasyRefresh(
      controller: _statisticsRefreshController,
      scrollController: _statisticsScrollController,
      header: const MaterialHeader(),
      onRefresh: () {
        context.read<PointsStatisticsBloc>().add(PointsStatisticsRefreshRequested());
      },
      child: AppCenteredList(
        builder: (context, side, width) {
          // Value tiles size with the text instead of a fixed 70px grid cell, so large fonts are not clipped.
          final scale = MediaQuery.textScalerOf(context).scale(1);
          // Room inside the surface: page width minus the centering padding and the surface padding.
          final contentWidth = width - side.horizontal - 32;
          final columns = (contentWidth / (150 * scale)).floor().clamp(1, 4);
          final rows = appRowCount(attrList.length, columns);
          return SingleChildScrollView(
            controller: _statisticsScrollController,
            padding: side.copyWith(top: 12, bottom: 12).add(context.safePadding()),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (attrList.isEmpty)
                  AppStateView(icon: Icons.bar_chart_outlined, message: context.t.general.noData, scrollable: false)
                else
                  AppSurface(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AppSectionHeader(
                          context.t.pointsPage.statisticsTab.title,
                          icon: Icons.bar_chart_outlined,
                          padding: const EdgeInsets.only(bottom: 8),
                        ),
                        for (var row = 0; row < rows; row++)
                          Padding(
                            padding: EdgeInsets.only(top: row == 0 ? 0 : 8),
                            child: IntrinsicHeight(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  for (var column = 0; column < columns; column++) ...[
                                    if (column > 0) sizedBoxW8H8,
                                    Expanded(
                                      child: row * columns + column < attrList.length
                                          ? _PointsValue(
                                              name: attrList[row * columns + column].key,
                                              value: attrList[row * columns + column].value,
                                            )
                                          : sizedBoxEmpty,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                sizedBoxW12H12,
                AppSectionHeader(
                  context.t.pointsPage.statisticsTab.recentChangelog,
                  icon: Icons.history_outlined,
                  trailing: TextButton(
                    child: Text(context.t.general.more),
                    onPressed: () {
                      _tabController.animateTo(1);
                    },
                  ),
                ),
                if (state.recentChangelog.isEmpty)
                  AppStateView(icon: Icons.history_outlined, message: context.t.general.noData, scrollable: false),
                ...state.recentChangelog
                    .map(PointsChangeCard.new)
                    .toList()
                    .cast<Widget>()
                    .insertBetween(appListSeparator),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildChangelogTab(BuildContext context, PointsChangelogState state) {
    late final Widget body;
    if (state.status == PointsStatus.loading) {
      body = const Expanded(child: CenteredCircularIndicator());
    } else {
      final changelogList = EasyRefresh(
        controller: _changelogRefreshController,
        scrollController: _changelogScrollController,
        header: const MaterialHeader(),
        footer: const MaterialFooter(),
        onLoad: () async {
          if (state.currentPage >= state.totalPages) {
            _changelogRefreshController.finishLoad(IndicatorResult.noMore);
            showNoMoreSnackBar(context);
            return;
          }
          context.read<PointsChangelogBloc>().add(PointsChangelogLoadMoreRequested(state.currentPage));
        },
        onRefresh: () {
          context.read<PointsChangelogBloc>().add(PointsChangelogRefreshRequested());
        },
        child: AppCenteredList(
          builder: (context, side, _) => state.fullChangelog.isEmpty
              ? ListView(
                  padding: side.copyWith(top: 8, bottom: 12).add(context.safePadding()),
                  children: [
                    AppStateView(icon: Icons.history_outlined, message: context.t.general.noData, scrollable: false),
                  ],
                )
              : ListView.separated(
                  shrinkWrap: true,
                  padding: side.copyWith(top: 8, bottom: 12).add(context.safePadding()),
                  itemCount: state.fullChangelog.length,
                  itemBuilder: (_, index) => PointsChangeCard(state.fullChangelog[index]),
                  separatorBuilder: (_, _) => appListSeparator,
                ),
        ),
      );

      body = Expanded(child: changelogList);
    }

    _changelogRefreshController
      ..finishLoad()
      ..finishRefresh();

    // The opened filter form scrolls on its own within 60% of the height (landscape phones, large fonts), so the
    // records below always keep some room.
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: constraints.maxHeight * 0.6),
            child: AppCenteredList(
              builder: (context, side, _) => SingleChildScrollView(
                padding: side.copyWith(top: 12, bottom: 4),
                child: PointsQueryForm(state.allParameters),
              ),
            ),
          ),
          body,
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _statisticsRefreshController = EasyRefreshController(controlFinishRefresh: true);
    _statisticsScrollController = ScrollController();
    _changelogRefreshController = EasyRefreshController(controlFinishRefresh: true, controlFinishLoad: true);
    _changelogScrollController = ScrollController();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _statisticsRefreshController.dispose();
    _statisticsScrollController.dispose();
    _changelogRefreshController.dispose();
    _changelogScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.pointsPage;
    return MultiBlocProvider(
      providers: [
        RepositoryProvider(create: (_) => PointsRepository()),
        BlocProvider(
          create: (context) =>
              PointsStatisticsBloc(pointsRepository: context.repo())..add(PointsStatisticsRefreshRequested()),
        ),
        BlocProvider(
          create: (context) =>
              PointsChangelogBloc(pointsRepository: context.repo())..add(PointsChangelogRefreshRequested()),
        ),
      ],
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr.title),
          bottom: TabBar(
            controller: _tabController,
            tabs: [
              Tab(text: tr.statisticsTab.title),
              Tab(text: tr.changelogTab.title),
            ],
          ),
        ),
        body: SafeArea(
          bottom: false,
          child: TabBarView(
            controller: _tabController,
            children: [
              BlocBuilder<PointsStatisticsBloc, PointsStatisticsState>(builder: _buildStatisticsTab),
              BlocBuilder<PointsChangelogBloc, PointsChangelogState>(builder: _buildChangelogTab),
            ],
          ),
        ),
      ),
    );
  }
}

/// One kind of points: name above, the value in bold; both wrap with large fonts.
class _PointsValue extends StatelessWidget {
  const _PointsValue({required this.name, required this.value});

  final String name;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return AppInsetBlock(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(name, style: textTheme.labelMedium?.copyWith(color: colorScheme.onSurfaceVariant)),
          sizedBoxW4H4,
          Text(
            value,
            style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold, color: colorScheme.primary),
          ),
        ],
      ),
    );
  }
}
