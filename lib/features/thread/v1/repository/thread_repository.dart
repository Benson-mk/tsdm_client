import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/features/thread/v1/models/models.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// Repository of thread page of the app.
class ThreadRepository {
  String? _threadUrl;

  /// Getter to get the thread url.
  String? get threadUrl => _threadUrl;

  int? _pageNumber;

  /// getter of current thread page number.
  int? get pageNumber => _pageNumber;

  String _buildOperationUrl(String tid) =>
      '$baseUrl/forum.php?mod=misc&action=viewthreadmod&tid=$tid'
      '&infloat=yes&handlekey=viewthreadmod&inajax=1&ajaxtarget=fwin_content_viewthreadmod';

  /// Fetch the thread page with [tid] on page [pageNumber] as a document, for the readers that parse the page
  /// themselves (`parseThreadDocument`).
  ///
  /// The page is asked in the JSON mode of the forum's app API; whatever the answer is (the web page, or a JSON
  /// answer whose `document` holds the blocks of the page: the structured answer of plugin 2.1.0 carries them too),
  /// it is given as the document of the page. The thread page shown to the user is fetched with [fetchThreadPage],
  /// which reads the structured fields of such an answer instead.
  ///
  /// # Exception
  ///
  /// * **HttpRequestedFailedException** when http request failed.
  AsyncEither<uh.Document> fetchThread({
    String? tid,
    String? pid,
    int pageNumber = 1,
    String? onlyVisibleUid,
    bool? reverseOrder,
    int? exactOrder,
  }) =>
      _fetchAnswer(
        tid: tid,
        pid: pid,
        pageNumber: pageNumber,
        onlyVisibleUid: onlyVisibleUid,
        reverseOrder: reverseOrder,
        exactOrder: exactOrder,
      ).flatMap(
        (data) => AsyncEither(
          () async => tsdmAppAnswerWithoutPage(data)
              // The antitheft interceptor asked the web page again for an answer without a page; what is still one here
              // is a failed request, not a thread without posts (see tsdmAppAnswerWithoutPage).
              ? left(HttpRequestFailedException(HttpStatus.ok))
              : right(tsdmAppPageDocument(data)),
        ),
      );

  /// Fetch the thread page with [tid] on page [pageNumber], built.
  ///
  /// The page is asked in the JSON mode of the forum's app API. An answer of plugin 2.1.0 or later carries the page
  /// as structured fields (`schema: 3`), or is the forum's own message with `login` (no permission, please log in):
  /// the page is built from them ([threadPageFromApi]), its `document` never read. Any other answer (a web page from
  /// a forum without the plugin, an older plugin's answer, the antitheft challenge or the thread cache a guest is
  /// served, whose `document` holds the blocks of the page) is parsed as the web page ([parseThreadDocument]), with
  /// [pageNumber] as the page when the page does not tell.
  ///
  /// # Exception
  ///
  /// * **HttpRequestedFailedException** when http request failed.
  AsyncEither<ThreadPageInfo> fetchThreadPage({
    String? tid,
    String? pid,
    int pageNumber = 1,
    String? onlyVisibleUid,
    bool? reverseOrder,
    int? exactOrder,
  }) =>
      _fetchAnswer(
        tid: tid,
        pid: pid,
        pageNumber: pageNumber,
        onlyVisibleUid: onlyVisibleUid,
        reverseOrder: reverseOrder,
        exactOrder: exactOrder,
      ).flatMap(
        (data) => AsyncEither(() async {
          final api = threadApiAnswerOf(data);
          if (api != null) {
            return right(threadPageFromApi(api, pageNumber));
          }
          // An answer without a page is a failed request, not a thread without posts (see tsdmAppAnswerWithoutPage); the
          // antitheft interceptor asked the web page again for one already.
          if (tsdmAppAnswerWithoutPage(data)) {
            return left(HttpRequestFailedException(HttpStatus.ok));
          }
          return right(parseThreadDocument(tsdmAppPageDocument(data), pageNumber));
        }),
      );

  /// The body of the thread page answer: the web page, or the JSON answer of the forum's app API (which may be one
  /// without a page, see [tsdmAppAnswerWithoutPage]: the callers tell).
  AsyncEither<Object?> _fetchAnswer({
    required String? tid,
    required String? pid,
    required int pageNumber,
    required String? onlyVisibleUid,
    required bool? reverseOrder,
    required int? exactOrder,
  }) => AsyncEither(() async {
    assert(tid != null || pid != null, 'tid and pid MUST not be null at the same time');

    /// Only visible uid.
    final visibleUid = onlyVisibleUid == null ? '' : '&authorid=$onlyVisibleUid';
    // ordertype: Control sort of post floors.
    // 1: desc (latest post first)
    // 2: asc (oldest post first)
    //
    // Some threads defined reverse order (latest post first) as default
    // post order, it's hard to detect the default order of a thread.
    //
    // Instead, always set `ordertype` query parameter to ensure all threads
    // are in the same default order.
    //
    // And in some situation, do NOT force reverse order, like user is going
    // to find a post in a certain page number, in this use case a manually
    // other override may going into different page that does NOT contain
    // the target post.
    final orderType = switch ((exactOrder, reverseOrder)) {
      (final int i, _) => '&ordertype=$i',
      (null, true) => '&ordertype=1',
      (null, false) => '&ordertype=2',
      (null, null) => '',
    };

    _pageNumber = pageNumber;
    if (tid != null) {
      _threadUrl =
          '$baseUrl/forum.php?mod=viewthread&tid=$tid&extra=page%3D1'
          '$orderType$visibleUid'
          '&page=$pageNumber';
    } else {
      // The page came from where we redirect by finding a post.
      _threadUrl = '$baseUrl/forum.php?mod=redirect&goto=findpost&pid=$pid';
    }

    // With the forum's app API the page comes back as JSON without header, footer and sidebar (see TsdmAppApi);
    // the url kept for sharing and reloading stays the plain one.
    final respEither = await getIt.get<NetClientProvider>().get(withTsdmAppJson(_threadUrl!)).run();
    if (respEither.isLeft()) {
      return left(respEither.unwrapErr());
    }

    final resp = respEither.unwrap();
    if (resp.statusCode != HttpStatus.ok) {
      return left(HttpRequestFailedException(resp.statusCode));
    }

    return right(resp.data);
  });

  /// Fetch the operation log for thread [tid].
  AsyncEither<List<OperationLogItem>> fetchOperationLog(String tid) =>
      getIt.get<NetClientProvider>().get(_buildOperationUrl(tid)).mapHttp((resp) {
        final htmlData = parseXmlDocument(resp.data as String).documentElement?.nodes.firstOrNull?.text;
        if (htmlData == null) {
          // Safe to throw because we use it in a future builder.
          throw Exception('html data not found');
        }

        // The log table is `<table class="list">` with a `<thead>` row of `<td>` headers and one `<tr>` per action.
        //
        // When no operation log is available the server responds with a notice `<div class="alert_error">`, in
        // which case an empty list is returned.
        final doc = parseHtmlDocument(htmlData);
        final items = doc
            .querySelectorAll('table tr')
            .map(OperationLogItem.fromTr)
            .whereType<OperationLogItem>()
            .toList();
        return items;
      });
}
