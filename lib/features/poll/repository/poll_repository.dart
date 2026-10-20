import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/poll/models/forum_poll.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// Account-bound access to a poll. No automatic POST retry or persisted forms.
class PollRepository {
  /// Inject transports in tests; production binds a client to the active identity.
  PollRepository({required this.getPage, required this.postForm});

  /// Build using the app's existing cookie, identity and error handling.
  ///
  /// The poll's post is read in the JSON mode of the forum's app API (roadmap item 3): the `findpost` redirect is
  /// carried to the thread page, whose blocks hold the poll form and the `discuz_uid` the identity check reads. Without
  /// the plugin the web page comes back. A card in the thread page shows the form of that page instead; it asks when it
  /// cannot, after a vote and after a login (see PollCard).
  ///
  /// An answer without a page (an empty body) fails the read ([fetchTsdmAppPageHtml]) instead of being a page served
  /// to nobody, which the card would show as a poll to log in for.
  factory PollRepository.network(NetClientProvider client) => PollRepository(
    getPage: (url) => fetchTsdmAppPageHtml(client, url),
    // The write result of the forum's app API (plugin 2.6.0) is read as the page it stands for.
    postForm: (url, body) async => switch (await client.postForm(url, data: body).run()) {
      Right(:final value) => tsdmAppWriteAnswerHtml(value.data),
      Left(:final value) => throw value,
    },
  );

  /// GET transport.
  final Future<String> Function(String url) getPage;

  /// POST transport. Indexed PHP array keys preserve every choice while keeping
  /// the string-valued map required by the Android Kotlin HTTP adapter.
  final Future<String> Function(String url, Map<String, String> body) postForm;

  /// Fetch a fresh form and verify which account the server rendered it for.
  Future<ForumPoll> fetch(String url, int? uid) async {
    final document = parseHtmlDocument(await getPage(url));
    return pollOfPage(document, servedUid: parseLoggedUidFromDocument(document), uid: uid);
  }

  /// The poll of [document], a page the forum served to [servedUid] (null: a guest page, or one that does not say),
  /// for the account [uid] now in use. Throws when the page belongs to another account: its form and formhash are
  /// that account's.
  static ForumPoll pollOfPage(uh.Document document, {required int? servedUid, required int? uid}) {
    if (servedUid != null && servedUid != uid) throw const FormatException('Poll identity changed');
    return parseForumPoll(document, loggedIn: uid != null && servedUid == uid);
  }

  /// Submit only the exact choices allowed by the latest form.
  ///
  /// The caller must refresh via GET afterwards even on error: a timed-out POST
  /// may have been accepted, and must never be retried automatically.
  Future<void> vote(ForumPoll poll, Set<String> choices) async {
    if (!poll.accepts(choices) || poll.action == null || poll.formHash == null) {
      throw const FormatException('Invalid poll selection');
    }
    final selected = choices.toList();
    final body = <String, String>{
      'formhash': poll.formHash!,
      'pollsubmit': 'true',
      for (var index = 0; index < selected.length; index++) 'pollanswers[$index]': selected[index],
    };
    // The response itself is not evidence of success. The next GET is authoritative.
    await postForm(poll.action!, body);
  }
}
