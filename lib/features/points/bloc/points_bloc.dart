import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/features/points/models/models.dart';
import 'package:tsdm_client/features/points/repository/model/models.dart';
import 'package:tsdm_client/features/points/repository/points_repository.dart';
import 'package:tsdm_client/features/points/utils/credit_page_api.dart';
import 'package:tsdm_client/features/points/utils/parse_points.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;

part 'points_bloc.mapper.dart';

part 'points_event.dart';

part 'points_state.dart';

/// Statistics emitter.
typedef PointsStatisticsEmitter = Emitter<PointsStatisticsState>;

/// Changelog emitter.
typedef PointsChangelogEmitter = Emitter<PointsChangelogState>;

/// Bloc of user points statistics page.
final class PointsStatisticsBloc extends Bloc<PointsStatisticsEvent, PointsStatisticsState> with LoggerMixin {
  /// Constructor.
  PointsStatisticsBloc({required PointsRepository pointsRepository})
    : _pointsRepository = pointsRepository,
      super(const PointsStatisticsState()) {
    on<PointsStatisticsRefreshRequested>(_onPointsStatisticsRefreshRequested);
  }

  final PointsRepository _pointsRepository;

  Future<void> _onPointsStatisticsRefreshRequested(
    PointsStatisticsRefreshRequested event,
    PointsStatisticsEmitter emit,
  ) async {
    emit(state.copyWith(status: PointsStatus.loading));
    await _pointsRepository
        .fetchStatisticsPage()
        .match(
          (e) {
            handle(e);
            error('failed to fetch points statistics page: $e');
            emit(state.copyWith(status: PointsStatus.failed));
          },
          (v) {
            final document = v;
            final result = parseStatisticsDocument(document);
            if (result == null) {
              emit(state.copyWith(status: PointsStatus.failed));
              return;
            }
            emit(state.copyWith(status: PointsStatus.success, pointsMap: result.$1, recentChangelog: result.$2));
          },
        )
        .run();
  }
}

/// Bloc of the points changelog page.
final class PointsChangelogBloc extends Bloc<PointsChangelogEvent, PointsChangelogState> with LoggerMixin {
  /// Constructor.
  PointsChangelogBloc({required PointsRepository pointsRepository})
    : _pointsRepository = pointsRepository,
      super(const PointsChangelogState()) {
    on<PointsChangelogRefreshRequested>(_onPointsChangelogRefreshRequested);
    on<PointsChangelogLoadMoreRequested>(_onPointsChangelogLoadMoreRequested);
    on<PointsChangelogQueryRequested>(_onPointsChangelogQueryRequested);
  }

  /// Repository of changelog.
  final PointsRepository _pointsRepository;

  Future<void> _onPointsChangelogRefreshRequested(
    PointsChangelogRefreshRequested event,
    PointsChangelogEmitter emit,
  ) async {
    emit(state.copyWith(status: PointsStatus.loading, fullChangelog: []));
    await _pointsRepository.fetchChangelogPage(state.parameter.copyWith(pageNumber: 1)).match(
      (e) {
        handle(e);
        error('failed to refresh changelog tab: $e');
        emit(state.copyWith(status: PointsStatus.failed));
      },
      (v) => emit(_parseAnswer(v, state.currentPage).copyWith(allParameters: _allParametersOf(v))),
    ).run();
  }

  Future<void> _onPointsChangelogLoadMoreRequested(
    PointsChangelogLoadMoreRequested event,
    PointsChangelogEmitter emit,
  ) async {
    await _pointsRepository.fetchChangelogPage(state.parameter.copyWith(pageNumber: state.currentPage + 1)).match((e) {
      handle(e);
      error('failed to load more points changelog: $e');
      emit(state.copyWith(status: PointsStatus.failed));
    }, (v) => emit(_parseAnswer(v, event.pageNumber))).run();
  }

  Future<void> _onPointsChangelogQueryRequested(
    PointsChangelogQueryRequested event,
    PointsChangelogEmitter emit,
  ) async {
    emit(state.copyWith(status: PointsStatus.loading, fullChangelog: [], parameter: event.parameter));
    await _pointsRepository.fetchChangelogPage(state.parameter.copyWith(pageNumber: 1)).match(
      (e) {
        error('failed to refresh changelog tab: $e');
        emit(state.copyWith(status: PointsStatus.failed));
      },
      (v) => emit(_parseAnswer(v, state.currentPage).copyWith(allParameters: _allParametersOf(v))),
    ).run();
  }

  /// The page [answer] into state: the structured answer of the forum's app API (plugin 2.5.0) built from its
  /// fields ([pointsChangelogFromApi]), the web page (or an older plugin's answer) parsed as before
  /// ([_parseDocument]).
  PointsChangelogState _parseAnswer(TsdmAppPageAnswer answer, int pageNumber) => switch (answer) {
    TsdmAppStructuredPage(:final json) => _parseApi(json, pageNumber),
    TsdmAppWebPage(:final document) => _parseDocument(document, pageNumber),
  };

  /// The filters of the query form of the page [answer]: of the structured answer, or of the web page as before.
  ChangelogAllParameters _allParametersOf(TsdmAppPageAnswer answer) => switch (answer) {
    TsdmAppStructuredPage(:final json) => changelogParametersFromApi(json),
    TsdmAppWebPage(:final document) => parseAllParameters(document),
  };

  /// The structured answer [json] into state: failed for the forum's message (a guest), as a page without the
  /// changelog table is; [pageNumber] is the page recorded so far, the fallback when the answer names no page (as
  /// [_parseDocument] falls back).
  PointsChangelogState _parseApi(Map<String, dynamic> json, int pageNumber) {
    final page = pointsChangelogFromApi(json, fallbackPage: pageNumber);
    if (page == null) {
      error('points change log not in the answer');
      return state.copyWith(status: PointsStatus.failed);
    }
    return state.copyWith(
      status: PointsStatus.success,
      fullChangelog: [...state.fullChangelog, ...page.changes],
      currentPage: page.currentPage,
      totalPages: page.totalPages,
    );
  }

  /// parse [document] into state.
  ///
  /// * [pageNumber] is the current recorded current page number. Used as a
  /// fallback page number if current page or total pages not found in document.
  PointsChangelogState _parseDocument(uh.Document document, int pageNumber) {
    final tableNode = document.querySelector('table.dt');
    if (tableNode == null) {
      error('points change table not found');
      return state.copyWith(status: PointsStatus.failed);
    }
    final changeList = buildChangeListFromTable(tableNode);
    final currentPage = document.currentPage() ?? pageNumber;
    final totalPages = document.totalPages() ?? pageNumber;
    return state.copyWith(
      status: PointsStatus.success,
      fullChangelog: [...state.fullChangelog, ...changeList],
      currentPage: currentPage,
      totalPages: totalPages,
    );
  }
}
