import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/draft_box/models/draft_data.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// Read-only access bound to one account's network client.
class DraftRepository {
  /// Injectable transport for deterministic tests: the page as html, or the answer of the forum's app API.
  DraftRepository(this.getPage);

  /// Production transport.
  ///
  /// Pages are asked in the JSON mode of the forum's app API (roadmap item 3): the draft list (`do=thread`) since
  /// plugin 1.6.0, the draft thread since 1.4.0. Both keep the `discuz_uid` the identity check reads; an older plugin
  /// answers the web page. A JSON answer without a page ([tsdmAppAnswerWithoutPage]: the plugin failed to build it, or
  /// an empty body) is a failed request, not a page without the account, which the check would take for an expired
  /// session. The draft thread of plugin 2.1.0 comes as structured fields (`schema: 3`), read by [resolve].
  factory DraftRepository.network(NetClientProvider client) =>
      DraftRepository((url) => fetchTsdmAppPageAnswer(client, url));

  /// No POST is performed by this repository. The answer is the web page, or the JSON answer of the forum's app API
  /// (decoded, or as text), see [tsdmAppPageHtml].
  final Future<Object?> Function(String url) getPage;

  Future<uh.Document> _fetch(String url, int uid) async => _checked(await getPage(url), uid);

  uh.Document _checked(Object? answer, int uid) {
    final document = parseHtmlDocument(tsdmAppPageHtml(answer));
    if (uid <= 0 || parseLoggedUidFromDocument(document) != uid) {
      throw const FormatException('Draft login expired');
    }
    return document;
  }

  /// Fetch a validated page of drafts.
  Future<DraftPage> load(int uid, {int page = 1}) async => parseDraftPage(
    await _fetch(draftBoxUrl(page: page), uid),
    page: page,
    uid: uid,
  );

  /// Resolve an existing draft through GET only.
  ///
  /// The thread page built from a structured answer tells the account it was served to and the draft
  /// ([draftTargetOfPage]); any other answer is parsed as before ([parseDraftTarget]).
  Future<DraftEditTarget> resolve(DraftEntry entry, int uid) async {
    final answer = await getPage(entry.url);
    final api = threadApiAnswerOf(answer);
    if (api != null) {
      if (uid <= 0 || threadApiViewerUid(api) != uid) {
        throw const FormatException('Draft login expired');
      }
      return draftTargetOfPage(threadPageFromApi(api, 1), entry);
    }
    return parseDraftTarget(_checked(answer, uid), entry);
  }
}
