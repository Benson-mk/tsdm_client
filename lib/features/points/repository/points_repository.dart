import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/points/repository/model/models.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;

/// Repository of points statistics page and points changelog page.
///
/// Both pages are asked in the JSON mode of the forum's app API (plugin 1.7.0): the forum answers the blocks the parsers
/// read (the main column `#ct` with the points, the changelog table, its filters and pages) without header, footer and
/// sidebar. With an older plugin the parameter is ignored and the web page comes back, parsed as before.
final class PointsRepository with LoggerMixin {
  static const _statisticsPageUrl = '$baseUrl/home.php?mod=spacecp&ac=credit&op=base';
  static const _changelogPageUrl = '$baseUrl/home.php?mod=spacecp&op=log&ac=credit';

  /// Fetch the points statistics page.
  AsyncEither<uh.Document> fetchStatisticsPage() => _fetchPage(_statisticsPageUrl);

  /// Fetch the points changelog page with given [parameter].
  AsyncEither<uh.Document> fetchChangelogPage(ChangelogParameter parameter) =>
      _fetchPage('$_changelogPageUrl$parameter');

  /// A JSON answer without a page ([tsdmAppAnswerWithoutPage]: the plugin failed to build it, or an empty body) is a
  /// failed request, not a page without points or changes.
  static AsyncEither<uh.Document> _fetchPage(String url) => AsyncEither(
    () async => switch (await getIt.get<NetClientProvider>().get(withTsdmAppJson(url)).run()) {
      Left(:final value) => left(value),
      Right(:final value) when value.statusCode != HttpStatus.ok || tsdmAppAnswerWithoutPage(value.data) => left(
        HttpRequestFailedException(value.statusCode),
      ),
      Right(:final value) => right(tsdmAppPageDocument(value.data)),
    },
  );
}
