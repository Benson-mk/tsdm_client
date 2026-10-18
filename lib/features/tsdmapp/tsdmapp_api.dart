import 'dart:convert';
import 'dart:io' if (dart.library.js) 'package:web/web.dart';

import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// The forum's app API, the `tsdmapp` Discuz plugin: `plugin.php?id=tsdmapp:api&action=…`, UTF-8 JSON.
///
/// The plugin is optional: every caller keeps its web page path and only uses an answer from here when there is one.
/// A forum without the plugin answers its "plugin not found" page instead of JSON; then the API is not asked again
/// for an hour, so polling does not cost an extra request each time.
///
/// Version 1 (plugin 1.0.0) is read-only: `status`, `notify`, `checkin`. Fields are only ever added; `api` is raised
/// when the meaning of a field changes. Since plugin 1.1.0 the forum can switch the API off (`error: off`, treated as
/// missing) and answers calls too close together with HTTP 429 (`error: busy`, a failed request here: the web path
/// is used for that one call).
///
/// Plugin 1.9.0 adds the private conversation list (`pmlist`) and `seen`, the only action that writes: it does what
/// opening the notice page and the private message page on the web does to the forum (the notices marked read, the
/// "new" prompts cleared), now that the notification fetch reads the lists from here instead of those pages. It is
/// sent with [post]; its `notify` answer carries the form hash for it ([notifyCarriesLists]).
abstract final class TsdmAppApi {
  /// Url of an action.
  static String url(String action, [Map<String, String> query = const {}]) => Uri.parse(
    '$baseUrl/plugin.php',
  ).replace(queryParameters: {'id': 'tsdmapp:api', 'action': action, ...query}).toString();

  /// How long a missing plugin is remembered.
  static const unavailableFor = Duration(hours: 1);

  static DateTime? _unavailableUntil;

  /// Whether the last answer said the forum has no API (for tests).
  static bool get knownUnavailable => _unavailableUntil != null && DateTime.now().isBefore(_unavailableUntil!);

  /// Forget a missing plugin (for tests, or after the user asks to check again).
  static void reset() => _unavailableUntil = null;

  /// Behave as on a forum without the plugin for [unavailableFor] (for tests of the web page paths).
  static void markUnavailable() => _unavailableUntil = DateTime.now().add(unavailableFor);

  /// Ask [action] with [client]; the parsed JSON object when the forum answered one, null otherwise.
  ///
  /// `{"ok":0,"error":"login"}` is an answer: the caller tells the expired session apart. A page that is not JSON
  /// marks the API missing for [unavailableFor]; a network error does not (the web path fails the same way).
  static Future<Map<String, dynamic>?> ask(
    NetClientProvider client,
    String action, [
    Map<String, String> query = const {},
  ]) => _ask(client, action, query, waitBusy: false, tries: 1);

  /// [ask], and an answer "too soon" (HTTP 429, `error: busy`, plugin 1.1.0) of a few seconds is waited for and asked
  /// once more: pages read the same action again right after a change (a title worn, a medal bought) to show the
  /// result, and the plugin takes one call per action and account every few seconds.
  static Future<Map<String, dynamic>?> askWaiting(
    NetClientProvider client,
    String action, [
    Map<String, String> query = const {},
  ]) => _ask(client, action, query, waitBusy: true, tries: 3);

  static Future<Map<String, dynamic>?> _ask(
    NetClientProvider client,
    String action,
    Map<String, String> query, {
    required bool waitBusy,
    required int tries,
  }) async {
    if (knownUnavailable) {
      return null;
    }
    final result = await client
        .get(
          url(action, query),
          options: waitBusy ? Options(validateStatus: (code) => code != null && (code < 300 || code == 429)) : null,
        )
        .run();
    if (waitBusy) {
      if (result case Right(value: final Response<dynamic> resp) when resp.statusCode == 429) {
        final data = resp.data;
        Object? json;
        try {
          json = data is Map ? data : jsonDecode('$data');
        } on FormatException {
          json = null;
        }
        final wait = json is Map ? (json['retry_after'] as num?)?.toInt() ?? 3 : 3;
        if (wait > 10) {
          return null;
        }
        await Future<void>.delayed(Duration(milliseconds: wait * 1000 + 300));
        // Another page or poller of the account may take the action again meanwhile: a few more waits, never the web
        // page of a plugin the parsers may not know any more.
        return _ask(client, action, query, waitBusy: tries > 2, tries: tries - 1);
      }
    }
    switch (result) {
      case Left(:final value):
        talker.debug('tsdmapp api $action failed: $value');
        return null;
      case Right(:final value):
        final decoded = _jsonObjectOf(value.data);
        if (decoded == null || decoded['ok'] is! int) {
          talker.info('tsdmapp api not available on the forum, using web pages for ${unavailableFor.inMinutes} min');
          _unavailableUntil = DateTime.now().add(unavailableFor);
          return null;
        }
        if (decoded['ok'] == 0 && decoded['error'] == 'off') {
          talker.info('tsdmapp api switched off on the forum, using web pages for ${unavailableFor.inMinutes} min');
          _unavailableUntil = DateTime.now().add(unavailableFor);
          return null;
        }
        if (decoded['ok'] == 0 && decoded['error'] == 'action') {
          // An older plugin without this action: not missing, just not for this question.
          return null;
        }
        return decoded;
    }
  }

  /// Post [form] to [action] with [client], once (no transport retry, no redirect followed); the parsed JSON object
  /// when the forum answered one, null otherwise. For `seen` (plugin 1.9.0), the only action that writes.
  ///
  /// Unlike [ask], an answer that is not JSON does not mark the API missing: Discuz itself answers a form hash it
  /// does not take with its "System Error" page, before the plugin is reached, and that tells nothing about the
  /// plugin. A failed request, HTTP 429 (`error: busy`), an older plugin without the action (`error: action`) and an
  /// API switched off (`error: off`) give null as well. The caller logs it and asks again on its next fetch.
  static Future<Map<String, dynamic>?> post(NetClientProvider client, String action, Map<String, String> form) async {
    if (knownUnavailable) {
      return null;
    }
    switch (await client.postForm(url(action), data: form, singleAttempt: true).run()) {
      case Left(:final value):
        talker.debug('tsdmapp api $action (post) failed: $value');
        return null;
      case Right(:final value):
        final decoded = _jsonObjectOf(value.data);
        if (decoded == null || decoded['ok'] is! int) {
          talker.warning('tsdmapp api $action (post) answered no JSON (HTTP ${value.statusCode})');
          return null;
        }
        if (decoded['ok'] == 0 && (decoded['error'] == 'action' || decoded['error'] == 'off')) {
          talker.debug('tsdmapp api $action (post) not available: ${decoded['error']}');
          return null;
        }
        return decoded;
    }
  }

  /// The JSON object of an answer body [data], null when it is not one.
  static Map<String, dynamic>? _jsonObjectOf(Object? data) {
    if (data is Map<String, dynamic>) {
      return data;
    }
    final text = data is String ? data : (data == null ? '' : jsonEncode(data));
    try {
      return switch (jsonDecode(text)) {
        final Map<String, dynamic> json => json,
        _ => null,
      };
    } on FormatException {
      return null;
    }
  }
}

/// What `notify` tells about the time since the last fetch.
sealed class TsdmAppNotifyGate {
  const TsdmAppNotifyGate();
}

/// Nothing new: the web pages need not be fetched.
final class TsdmAppNothingNew extends TsdmAppNotifyGate {
  /// Constructor.
  const TsdmAppNothingNew(this.serverTime);

  /// The forum's clock when it answered.
  final DateTime serverTime;
}

/// Something new, or the API could not tell: fetch the web pages as usual.
final class TsdmAppFetchPages extends TsdmAppNotifyGate {
  /// Constructor.
  const TsdmAppFetchPages();
}

/// The forum answered that the cookie is not logged in.
final class TsdmAppNotLoggedIn extends TsdmAppNotifyGate {
  /// Constructor.
  const TsdmAppNotLoggedIn();
}

/// Decide from a `notify` answer [json] whether anything arrived at or after [since] (seconds).
///
/// Notices and private messages carry the time they arrived. Broadcast messages carry the time they were written and
/// reach the members in batches (GitHub #154), so any unread one counts as new; the web path then decides from the
/// stored ones, as it always did.
///
/// `pms` lists the unread received conversations only: a conversation whose last message the user sent (in the app
/// or on the web), or read on the web, never showed there, and the private message page was not fetched for it, so
/// it never reached the stored list (GitHub #193). Plugin 1.8.0 adds `pm_last`, the time (seconds, forum clock) of the
/// latest change of any conversation of the user, sent or received, read or not (0 when there is none): a time after
/// [since] counts as new. An older plugin leaves it out and the gate decides as before.
TsdmAppNotifyGate notifyGateOf(Map<String, dynamic>? json, {required int since}) {
  if (json == null) {
    return const TsdmAppFetchPages();
  }
  if (json['ok'] != 1) {
    return json['error'] == 'login' ? const TsdmAppNotLoggedIn() : const TsdmAppFetchPages();
  }
  final notices = json['notices'];
  final announces = json['announces'];
  final time = (json['time'] as num?)?.toInt();
  if (time == null ||
      notices is! List ||
      announces is! List ||
      notices.whereType<Map<String, dynamic>>().any((e) => ((e['dateline'] as num?)?.toInt() ?? 0) >= since) ||
      announces.isNotEmpty ||
      notifyPmSignalOf(json, since: since)) {
    return const TsdmAppFetchPages();
  }
  return TsdmAppNothingNew(DateTime.fromMillisecondsSinceEpoch(time * 1000, isUtc: true));
}

/// Whether a `notify` answer [json] tells that a private conversation changed at or after [since] (seconds), the
/// private message part of [notifyGateOf]: an unread received conversation (`pms`) with its last message since then,
/// or the latest change of any conversation (`pm_last`, plugin 1.8.0) after it. A `pms` that is not a list cannot
/// tell, which counts as a change.
bool notifyPmSignalOf(Map<String, dynamic> json, {required int since}) {
  final pms = json['pms'];
  final pmLast = json['pm_last'];
  return pms is! List ||
      pms.whereType<Map<String, dynamic>>().any((e) => ((e['lastdateline'] as num?)?.toInt() ?? 0) >= since) ||
      (pmLast is num && pmLast.toInt() > since);
}

/// Whether a `notify` answer [json] carries the lists the notification fetch reads instead of the notice and private
/// message pages (plugin 1.9.0): the form hash `seen` is posted with, the notices, the unread broadcast messages and
/// the forum's clock. An older plugin leaves the form hash out; its answer only gates the pages ([notifyGateOf]).
bool notifyCarriesLists(Map<String, dynamic>? json) =>
    json != null &&
    json['ok'] == 1 &&
    json['formhash'] is String &&
    json['notices'] is List &&
    json['announces'] is List &&
    json['time'] is int;

/// The largest id of the unread notices in a `notify` answer [json], null when none is unread: the `notice` to post
/// with `seen`, which marks every unread notice read unless one newer than that arrived meanwhile.
int? notifyLatestUnreadNoticeOf(Map<String, dynamic> json) {
  final notices = json['notices'];
  if (notices is! List) {
    return null;
  }
  int? latest;
  for (final e in notices.whereType<Map<String, dynamic>>()) {
    final id = e['id'];
    if (e['new'] == 1 && id is int && (latest == null || id > latest)) {
      latest = id;
    }
  }
  return latest;
}

/// The checkin state told by `checkin`, null when the API cannot tell (missing plugin, no checkin plugin, old API).
({bool checkedToday, bool openNow})? checkinStateOf(Map<String, dynamic>? json) {
  if (json == null || json['ok'] != 1 || json['installed'] != 1) {
    return null;
  }
  final checked = json['checked_today'];
  final window = json['window'];
  if (checked is! int || window is! Map<String, dynamic> || window['open_now'] is! int) {
    return null;
  }
  return (checkedToday: checked == 1, openNow: window['open_now'] == 1);
}

/// Query parameter asking a forum page for its JSON mode (stage 2: thread and forum pages).
///
/// The forum renders the page as usual and, with the plugin, answers JSON holding the blocks the app's parsers read
/// (`document`), cut from its final output: same permissions and content as the web page, without header, footer and
/// sidebar. Without the plugin (or with it switched off) the parameter is ignored and the page comes back as usual.
const tsdmAppJsonQuery = 'tsdmapp=json';

/// Add [tsdmAppJsonQuery] to [url]; an AJAX url (`inajax=1`, answered as an XML fragment) is left as it is.
///
/// The parameter goes before a `#fragment`, which is never sent to the server: the chat history url ends with `#last`
/// and so was always answered the web page (roadmap item 3).
String withTsdmAppJson(String url) {
  final hash = url.indexOf('#');
  final base = hash < 0 ? url : url.substring(0, hash);
  if (base.contains('inajax=1') || base.contains(tsdmAppJsonQuery)) {
    return url;
  }
  final separator = !base.contains('?') ? '?' : (base.endsWith('?') || base.endsWith('&') ? '' : '&');
  return '$base$separator$tsdmAppJsonQuery${hash < 0 ? '' : url.substring(hash)}';
}

/// The document to parse from a forum page answer [data]: the web page itself, or the page rebuilt from the blocks of
/// a JSON answer. A thread answer also gets the `<link>` to the thread the thread parser reads the tid from.
uh.Document tsdmAppPageDocument(Object? data) {
  final Object? json;
  if (data is Map<String, dynamic>) {
    json = data;
  } else if (data is String && data.trimLeft().startsWith('{')) {
    try {
      json = jsonDecode(data);
    } on FormatException {
      return parseHtmlDocument(data);
    }
  } else {
    return parseHtmlDocument(data is String ? data : '');
  }
  if (json is! Map<String, dynamic> || json['document'] is! String) {
    return parseHtmlDocument(data is String ? data : '');
  }
  // The links of the page head (the thread parser and the report links read the tid from them); older answers had none.
  final tid = json['thread'] is Map<String, dynamic> ? (json['thread'] as Map<String, dynamic>)['tid'] : null;
  final head = json['head'] is String && (json['head'] as String).isNotEmpty
      ? json['head'] as String
      : (tid is int ? '<link href="forum.php?mod=viewthread&amp;tid=$tid" />' : '');
  // The blocks sit inside `div#wp.wp` on the web page and some parsers match through it.
  return parseHtmlDocument(
    '<html><head>$head</head><body><div id="wp" class="wp">${json['document']}</div></body></html>',
  );
}

/// Whether a forum page answer [data] has no page at all: a JSON answer the plugin failed to build
/// (`{"ok":0,"error":"internal"}`, without the page's blocks), an empty JSON body (the request died before the plugin
/// printed its answer; dio reads an empty `application/json` body as null), or a blank one served as a web page (a PHP
/// fatal error with the errors hidden, a proxy that cut the answer: dio reads it as an empty string). No forum page is
/// blank, and a blank JSON body is not read at all: dio throws on it, which is a failed request already. A caller that
/// would take an empty page for "nothing there" (the notification poll, which then moves its window on; the draft box,
/// which then finds no account on it; a list page, which then shows an empty list) treats it as a failed request: every
/// page asked in the JSON mode does, through [TsdmAppPageHttpExt.mapHttpPage] or [fetchTsdmAppPageHtml] where it does
/// not check by itself.
bool tsdmAppAnswerWithoutPage(Object? data) => switch (data) {
  null => true,
  final String text when text.trim().isEmpty => true,
  _ => switch (_tsdmAppAnswerJson(data)) {
    final Map<dynamic, dynamic> json => json['document'] is! String,
    _ => false,
  },
};

/// Whether a thread page answer [data] holds neither the thread nor a forum message: no page at all
/// ([tsdmAppAnswerWithoutPage]), or a JSON answer that is not `ok` 1, not a forum message (`error: message`: no
/// permission, no such thread…, which the web page shows the same) and without posts in its document.
///
/// A thread page gives that when the forum answered the antitheft (防采集) challenge instead: the plugin buffers the
/// page from its first hook and turns whatever was printed into JSON when the request ends, and the challenge script is
/// printed (and the request ended) before the thread is built. The answer is `{"ok":0,"error":"unknown"}` with only a
/// form hash for a document, the script is lost, and the challenge can only be solved on the web page
/// (`AntitheftInterceptor`).
///
/// A guest may be served the forum's thread cache instead (`viewthread_loadcache`): the cached page is printed and the
/// request ended before the thread is built too, so the answer is `unknown` as well, but its document holds the whole
/// post list and is parsed as it is, as the web page would be. The cache is only read after the antitheft check passed.
bool tsdmAppAnswerWithoutContent(Object? data) {
  if (tsdmAppAnswerWithoutPage(data)) {
    return true;
  }
  final json = _tsdmAppAnswerJson(data);
  if (json == null || json['ok'] == 1 || json['error'] == 'message') {
    return false;
  }
  return parseHtmlDocument(json['document'] as String).querySelector('div#postlist, div[id^="post_"]') == null;
}

/// The JSON object of a forum page answer [data], null when it is a web page.
Map<dynamic, dynamic>? _tsdmAppAnswerJson(Object? data) {
  if (data is Map) {
    return data;
  }
  if (data is! String || !data.trimLeft().startsWith('{')) {
    return null;
  }
  try {
    return switch (jsonDecode(data)) {
      final Map<dynamic, dynamic> json => json,
      _ => null,
    };
  } on FormatException {
    return null;
  }
}

/// The html of a forum page answer [data], for callers that hand a page around as a string: the web page itself, or
/// the page rebuilt from the blocks of a JSON answer (see [tsdmAppPageDocument]).
String tsdmAppPageHtml(Object? data) {
  if (data is String && !data.trimLeft().startsWith('{')) {
    return data;
  }
  return tsdmAppPageDocument(data).documentElement?.outerHtml ?? '';
}

/// [FPHttpExt.mapHttp] for a forum page asked in the JSON mode ([withTsdmAppJson]), given the document of the answer
/// ([tsdmAppPageDocument]).
///
/// An answer without a page ([tsdmAppAnswerWithoutPage]) is a failed request like a bad status code is. Taken as the
/// empty document it would be, the page would show an empty list (or ask the user to log in) for a forum that merely
/// failed to answer. A JSON answer that carries a page is parsed as ever, whether its list is empty or its `ok` is 0
/// (a forum message such as "no permission" is a page too).
extension TsdmAppPageHttpExt on AsyncEither<Response<dynamic>> {
  /// * Return error if any.
  /// * Return `HttpRequestFailedException` when status code is not 200, or the answer has no page.
  /// * Return result called on [onPage] when ok.
  AsyncEither<T> mapHttpPage<T>(T Function(uh.Document document) onPage) => AsyncEither(
    () async => switch (await run()) {
      Left(:final value) => left(value),
      Right(:final value) when value.statusCode != HttpStatus.ok || tsdmAppAnswerWithoutPage(value.data) => left(
        HttpRequestFailedException(value.statusCode),
      ),
      Right(:final value) => right(onPage(tsdmAppPageDocument(value.data))),
    },
  );
}

/// The html of the forum page [url] asked of [client] in the JSON mode ([withTsdmAppJson]), for the pages that hand a
/// page around as a string ([tsdmAppPageHtml]). Throws the failure of the request, and [HttpRequestFailedException]
/// for an answer without a page ([tsdmAppAnswerWithoutPage]): an empty string would be read as a page without the
/// account, a list or a form, and not as the failure it is.
Future<String> fetchTsdmAppPageHtml(NetClientProvider client, String url) async =>
    switch (await client.get(withTsdmAppJson(url)).run()) {
      Right(:final value) when tsdmAppAnswerWithoutPage(value.data) => throw HttpRequestFailedException(
        value.statusCode,
      ),
      Right(:final value) => tsdmAppPageHtml(value.data),
      Left(:final value) => throw value,
    };
