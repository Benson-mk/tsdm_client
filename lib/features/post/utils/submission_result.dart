import 'package:dio/dio.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/draft_box/models/draft_data.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// Convert a verified viewthread redirect into a canonical read-only URL.
String? submittedThreadUrl(String? location, {String? expectedTid}) {
  final uri = draftForumUri(location);
  if (uri == null) return null;
  final rewritten = RegExp(r'^/thread-([1-9]\d*)-\d+-\d+\.html$').firstMatch(uri.path);
  final tid =
      rewritten?.group(1) ??
      (uri.path == '/forum.php' && uri.queryParameters['mod'] == 'viewthread' ? uri.queryParameters['tid'] : null);
  if (tid == null || !RegExp(r'^[1-9]\d*$').hasMatch(tid) || expectedTid != null && expectedTid != tid) return null;
  return '$baseUrl/forum.php?mod=viewthread&tid=$tid';
}

/// HTTP 200 alone is not success. Accept only a thread redirect or explicit success page.
///
/// With the forum's app API (plugin 2.6.0) the answer is its write result ([tsdmAppWriteResultOf]): the redirect
/// the forum would have answered (`redirect`, its `url`), the success page (`message` with `alert_right` and its
/// `url`), or a page, read as the forum's page is. The login prompt and a refusal are no success.
String? parseSubmissionResult(Response<dynamic> response, {String? expectedTid}) {
  if (![200, 301, 302, 303].contains(response.statusCode)) return null;
  final redirected = submittedThreadUrl(response.headers.value('location'), expectedTid: expectedTid);
  if (redirected != null) return redirected;
  if (tsdmAppWriteResultOf(response.data) case final result?) {
    return switch (result.kind) {
      TsdmAppWriteKind.redirect ||
      TsdmAppWriteKind.handle => result.succeeded ? submittedThreadUrl(result.url, expectedTid: expectedTid) : null,
      TsdmAppWriteKind.message =>
        result.succeeded && result.alert == 'right' ? submittedThreadUrl(result.url, expectedTid: expectedTid) : null,
      TsdmAppWriteKind.page => _submissionResultOfPage(result.document, expectedTid: expectedTid),
    };
  }
  if (response.data is! String) return null;
  return _submissionResultOfPage(parseHtmlDocument(response.data as String), expectedTid: expectedTid);
}

/// [parseSubmissionResult] of the page [document] the forum answered: the link of an explicit success message, or
/// the canonical url of the thread page itself.
String? _submissionResultOfPage(uh.Document document, {String? expectedTid}) {
  final message = document.querySelector('#messagetext');
  if (message != null) {
    if (!message.classes.contains('alert_right')) return null;
    return submittedThreadUrl(
      message.querySelector('p.alert_btnleft a[href]')?.attributes['href'],
      expectedTid: expectedTid,
    );
  }
  if (document.querySelector('#postlist div[id^="post_"]') == null) return null;
  return submittedThreadUrl(
    document.querySelector('head link[rel="canonical"]')?.attributes['href'],
    expectedTid: expectedTid,
  );
}
