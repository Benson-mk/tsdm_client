import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/points/repository/model/models.dart';
import 'package:tsdm_client/features/points/utils/credit_page_api.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;

/// Repository of points statistics page and points changelog page.
///
/// Both pages are asked in the JSON mode of the forum's app API (plugin 1.7.0): the forum answers the blocks the parsers
/// read (the main column `#ct` with the points, the changelog table, its filters and pages) without header, footer and
/// sidebar. With an older plugin the parameter is ignored and the web page comes back, parsed as before. Plugin 2.5.0
/// answers the changelog page (`op=log`) as structured fields (`schema: 12`, [creditApiAnswerOf]), kept as a
/// [TsdmAppStructuredPage] for `pointsChangelogFromApi`; the statistics page (`op=base`) is still read from its
/// blocks.
final class PointsRepository with LoggerMixin {
  static const _statisticsPageUrl = '$baseUrl/home.php?mod=spacecp&ac=credit&op=base';
  static const _changelogPageUrl = '$baseUrl/home.php?mod=spacecp&op=log&ac=credit';

  /// Fetch the points statistics page.
  ///
  /// A JSON answer without a page ([tsdmAppAnswerWithoutPage]: the plugin failed to build it, or an empty body) is a
  /// failed request, not a page without points ([TsdmAppPageHttpExt.mapHttpPage]).
  AsyncEither<uh.Document> fetchStatisticsPage() =>
      getIt.get<NetClientProvider>().get(withTsdmAppJson(_statisticsPageUrl)).mapHttpPage((document) => document);

  /// Fetch the points changelog page with given [parameter]: the structured answer ([TsdmAppStructuredPage]) or the
  /// web page ([TsdmAppWebPage]), which parses as before. An answer without a page is a failed request, not a page
  /// without changes ([TsdmAppPageHttpExt.mapHttpPageAnswer]).
  AsyncEither<TsdmAppPageAnswer> fetchChangelogPage(ChangelogParameter parameter) => getIt
      .get<NetClientProvider>()
      .get(withTsdmAppJson('$_changelogPageUrl$parameter'))
      .mapHttpPageAnswer(creditApiAnswerOf);
}
