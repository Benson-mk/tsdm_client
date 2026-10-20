import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/homepage/bloc/homepage_bloc.dart';
import 'package:tsdm_client/features/homepage/models/models.dart';
import 'package:tsdm_client/features/red_packet/models/models.dart';
import 'package:tsdm_client/features/red_packet/repository/daily_rewards_repository.dart' as rewards;
import 'package:tsdm_client/features/red_packet/utils/parse_red_packet.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// The id of the "发帖排行" block of the homepage (`Kahrpba`): each row is a member and a post count, not a thread
/// and its author.
const _rankBlockId = 5;

/// The forum's homepage (`forum.php`) as the shared repository fetched it: the web page (or an older plugin's answer,
/// rebuilt as one), or the structured answer of the forum's app API (plugin 2.3.0, `schema: 5`).
///
/// The homepage tab, the topics tab and the activities page read it through the path the page needs, so that the
/// web page is parsed as it always was and the structured answer is never parsed from a `document` (which a lean
/// answer, `nodoc=1`, does not even carry).
sealed class ForumHomePage {
  const ForumHomePage();

  /// The uid the page was served to, null for a guest (the `parseLoggedUidFromDocument` of the web page).
  int? get servedUid;

  /// Today's daily red packet the page offers, null when there is none or it was claimed already.
  DailyRedPacketConfig? get dailyRedPacket;

  /// The form hash of the session the page was served to, null when the page names none.
  String? get formHash;

  /// The forum's own `checknewpm` request of the page (`dailyVisitUri` of the daily rewards), which also credits
  /// the daily login: the web page carries it in a script; an answer of plugin 2.3.0 names it in `checknewpm`
  /// (`''` when the page printed none), since the script is in no lean answer's `document`.
  Uri? get dailyVisitUri;
}

/// The web page of the homepage (or an older plugin's answer, whose `document` holds its blocks), parsed as before.
final class ForumHomeWebPage extends ForumHomePage {
  /// Constructor.
  ///
  /// [checknewpm] is the `checknewpm` of the JSON answer the document came from, when it is one of plugin 2.3.0
  /// (the `unknown` answer of the cached guest index): the script it names is in no lean answer's `document`.
  const ForumHomeWebPage(this.document, {this.checknewpm});

  /// The page.
  final uh.Document document;

  /// The `checknewpm` of the answer, null for the web page and an older plugin's answer.
  final String? checknewpm;

  @override
  int? get servedUid => parseLoggedUidFromDocument(document);

  @override
  DailyRedPacketConfig? get dailyRedPacket => parseDailyRedPacketConfig(document);

  @override
  String? get formHash => parseFormHash(document);

  @override
  Uri? get dailyVisitUri => switch (checknewpm) {
    final String source when source.isNotEmpty => rewards.dailyVisitUriOfSource(source),
    _ => rewards.dailyVisitUri(document),
  };
}

/// The structured answer of the forum's app API ([indexApiAnswerOf]): the homepage, or the forum's message.
final class ForumHomeApiPage extends ForumHomePage {
  /// Constructor.
  const ForumHomeApiPage(this.json);

  /// The answer.
  final Map<String, dynamic> json;

  /// The page is served to the account `uid` names (0 for a guest); a message answer names no account.
  @override
  int? get servedUid {
    final uid = _int(json['ok'] == 1 ? json['uid'] : null);
    return uid > 0 ? uid : null;
  }

  @override
  DailyRedPacketConfig? get dailyRedPacket => dailyRedPacketFromApi(json);

  @override
  String? get formHash {
    final hash = _text(json['formhash']);
    return hash.isEmpty ? null : hash;
  }

  @override
  Uri? get dailyVisitUri => rewards.dailyVisitUriOfSource(_text(json['checknewpm']));
}

/// The structured homepage answer in [data]: a JSON answer of the forum's app API that carries every field the app
/// reads (plugin 2.3.0, `type: index` with `schema` 5 or later: the statistics, the viewer, the links of the status
/// bar, the categories with their forums, the favorite forums, the `Kahrpba` blocks and slides, the daily red
/// packet), or the forum's own message of such a plugin (the site closed, please log in: `ok` 0, `error: message`,
/// with `login` telling a guest apart). Null when the answer has to be read from its `document` as before: a web
/// page, another page's answer, an older plugin's answer (`type: index` without `schema`), a failed build.
///
/// The page is then built by [homepageStateFromApi] and [forumGroupsFromApi]; the `document` of the answer, when
/// there is one, is never parsed.
Map<String, dynamic>? indexApiAnswerOf(Object? data) {
  final json = tsdmAppAnswerJson(data);
  if (json == null) {
    return null;
  }
  final schema = json['schema'];
  final structured = schema is num && schema >= 5;
  if (json['ok'] == 1) {
    return structured && json['type'] == 'index' ? json : null;
  }
  if (json['ok'] == 0 && json['error'] == 'message' && (structured || json['login'] is int)) {
    return json;
  }
  return null;
}

/// The account a structured homepage answer [json] was served to, null for a guest or a message answer (which names
/// no username): what the web page's header user node tells (`parseLoggedUserFromDocument`).
UserLoginInfo? servedUserOf(Map<String, dynamic> json) {
  if (json['ok'] != 1) {
    return null;
  }
  final user = _map(json['user']);
  final uid = _int(user['uid']);
  final username = _text(user['username']);
  if (uid <= 0 || username.isEmpty) {
    return null;
  }
  return UserLoginInfo(uid: uid, username: username);
}

/// Whether a structured homepage answer [json] is the guest's: the page served to nobody (`uid` 0), or the forum's
/// login prompt (`login` 1). With an account in use, that session is dead (issue #25), as the guest web page tells.
bool indexAnswerIsGuest(Map<String, dynamic> json) => json['ok'] == 1 ? _int(json['uid']) <= 0 : json['login'] == 1;

/// Today's daily red packet of a structured homepage answer [json]: `red_packet` is the object the forum's footer
/// passes to `hongbaoDailyInit` while the viewer has not claimed it today, null otherwise.
DailyRedPacketConfig? dailyRedPacketFromApi(Map<String, dynamic> json) {
  final packet = json['red_packet'];
  return packet is Map<String, dynamic> && packet.containsKey('dateflag')
      ? DailyRedPacketConfig.fromServerJson(packet)
      : null;
}

/// Build the homepage state from a structured answer [json] of the forum's app API ([indexApiAnswerOf]), for the
/// account [username] the app has (null to take the one the answer names) with the avatar [avatarUrl] the app has
/// (null to take the one the answer names), as the web page is parsed with them.
///
/// The same [HomepageState] the web page gives, from the fields instead of the html:
///
/// * `stats` is the status bar (今日, 昨日, 帖子), `links` its links (我的帖子, 最新回复 when the guide is on);
/// * `user` is the viewer: the account named by the app wins, as it always did; the avatar of the answer is taken
///   when the app has none;
/// * `blocks` are the `Kahrpba` tabs in the order the website shows them (the plugin reads the nav: no reordering
///   here), `id` 5 the rank; a row without a link (a new member who did not report in) is left out as the page
///   parser leaves it out, and a tab without any row is left out (GitHub #155);
/// * `slides` is the swiper: every slide with a picture;
/// * `unread` is the header's notice count and new message mark;
/// * `red_packet` is today's daily red packet (none for a guest), `formhash` the form hash to claim it with.
///
/// The forum's message (`ok` 0): the login prompt (`login` 1) asks to log in; any other message, or the prompt for
/// an app that has no account, is the failure the web page of it would be parsed as.
HomepageState homepageStateFromApi(Map<String, dynamic> json, String? username, {String? avatarUrl}) {
  if (json['ok'] != 1) {
    return HomepageState(
      status: username == null || json['login'] == 1 ? HomepageStatus.needLogin : HomepageStatus.failure,
    );
  }
  final user = _map(json['user']);
  final loggedUsername = username ?? _text(user['username']);
  final avatar = _text(user['avatar']);
  final stats = json['stats'];
  final forumStatus = stats is Map<String, dynamic>
      ? ForumStatus(
          todayCount: '${_int(stats['todayposts'])}',
          yesterdayCount: '${_int(stats['yesterdayposts'])}',
          threadCount: '${_int(stats['posts'])}',
        )
      : const ForumStatus.empty();
  final links = _list(json['links'])
      .map((e) => (_text(e['title']), _text(e['url'])))
      .where((e) => e.$2.isNotEmpty)
      .map((e) => (e.$1.isEmpty ? 'unknown' : e.$1, e.$2))
      .toList();
  final unread = _map(json['unread']);
  return HomepageState(
    status: loggedUsername.isNotEmpty ? HomepageStatus.success : HomepageStatus.needLogin,
    forumStatus: forumStatus,
    loggedUserInfo: LoggedUserInfo(
      username: loggedUsername,
      relatedLinkPairList: links,
      avatarUrl: avatarUrl ?? (avatar.isEmpty ? null : avatar),
    ),
    pinnedThreadGroupList: pinnedThreadGroupsFromApi(json),
    swiperUrlList: _list(json['slides'])
        .map((e) => SwiperUrl(coverUrl: _text(e['image']), linkUrl: _text(e['url'])))
        .where((e) => e.coverUrl.isNotEmpty)
        .toList(),
    unreadNoticeCount: _int(unread['notice']),
    hasUnreadMessage: _int(unread['pm']) > 0,
    // As from the page: the forum only offers the packet to a member.
    dailyRedPacket: loggedUsername.isEmpty ? null : dailyRedPacketFromApi(json),
    formHash: ForumHomeApiPage(json).formHash,
  );
}

/// The `Kahrpba` tabs of a structured homepage answer [json] (`blocks`), in the order given, see
/// [homepageStateFromApi]; empty for a guest (the forum prints the block to members only) and on a forum without
/// the plugin.
///
/// A `Kahrpba` template the plugin cannot read (an older one, on the production forum) gives no `blocks` and the
/// whole `table#Kahrpba` as `blocks_html` instead: the tabs are then parsed from it as from the page
/// ([HomepageBloc.parsePinnedThreadGroups]), with the reordering and the rank mark of that parser.
List<PinnedThreadGroup> pinnedThreadGroupsFromApi(Map<String, dynamic> json) {
  final blocks = _list(json['blocks']);
  final blocksHtml = _text(json['blocks_html']);
  if (blocks.isEmpty && blocksHtml.trim().isNotEmpty) {
    return HomepageBloc.parsePinnedThreadGroups(parseHtmlDocument('<html><body>$blocksHtml</body></html>'));
  }
  final groups = <PinnedThreadGroup>[];
  for (final block in blocks) {
    final rows = _list(block['rows']).map(_pinnedThreadOf).whereType<PinnedThread>().toList();
    if (rows.isEmpty) {
      // A tab without any row the app can show would be an empty card as tall as the full ones (GitHub #155).
      continue;
    }
    groups.add(
      PinnedThreadGroup(title: _text(block['title']), threadList: rows, isRank: _int(block['id']) == _rankBlockId),
    );
  }
  return groups;
}

/// A row of a `Kahrpba` tab: the link (a thread, a member's space, or the member of the rank) with its title, and
/// the author (the member of a thread, the post count of the rank, the new member of 见习天使) with the link to the
/// member's space when the page has one (empty otherwise: the rank's count, a new member named in a thread's title).
/// Null for a row without a link (a new member who did not report in: a span, not a link, on the page), which the
/// page parser never gave either.
PinnedThread? _pinnedThreadOf(Map<String, dynamic> row) {
  final url = _text(row['url']);
  final title = _text(row['title']);
  if (url.isEmpty || title.isEmpty) {
    talker.info('skip pinned row without a link: ${row['title']}');
    return null;
  }
  final author = _text(row['author']);
  return PinnedThread(
    threadUrl: url,
    threadTitle: title,
    authorUrl: _text(row['author_url']),
    authorName: author.isEmpty ? title : author,
  );
}

/// The forum groups of a structured homepage answer [json] for the topics tab, as `buildGroupListFromDocument`
/// reads them from the web page: the "我收藏的版块" panel first when the viewer has favorite forums
/// (`favorite_forums`, each looked up among the forums of the categories; one that is not listed there, a subforum
/// or a forum the viewer may not see, is left out of the panel but still seeded, see [favoriteForumIdsOf]), then
/// every category (`forum.php?gid=`) with its forums ([Forum.fromApi]: the latest thread, the subforums the forum's
/// setting lists). The answer names no group moderators.
List<ForumGroup> forumGroupsFromApi(Map<String, dynamic> json) {
  final groups = _list(json['categories'])
      .map(
        (c) => ForumGroup(
          name: _text(c['name']),
          url: 'forum.php?gid=${_int(c['fid'])}',
          forumList: _list(c['forums']).map(Forum.fromApi).toList(),
        ),
      )
      .toList();
  final favoriteIds = favoriteForumIdsOf(json);
  if (favoriteIds.isEmpty) {
    return groups;
  }
  final forums = {
    for (final g in groups)
      for (final f in g.forumList) f.forumID: f,
  };
  final favorites = favoriteIds.map((fid) => forums[fid]).whereType<Forum>().toList();
  if (favorites.length != favoriteIds.length) {
    talker.info(
      'favorite forums not among the categories left out of the panel: ${favoriteIds.where((e) => !forums.containsKey(e))}',
    );
  }
  if (favorites.isEmpty) {
    return groups;
  }
  return [
    ForumGroup(name: '我收藏的版块', url: 'home.php?mod=space&do=favorite&type=forum', forumList: favorites),
    ...groups,
  ];
}

/// The forums the viewer of a structured homepage answer [json] has favorited (`favorite_forums`, the ids the
/// page's "我收藏的版块" panel lists), in the page's order; empty for a guest and for a member without any.
List<int> favoriteForumIdsOf(Map<String, dynamic> json) {
  final ids = json['favorite_forums'];
  if (ids is! List) {
    return const [];
  }
  return ids.map(_int).where((e) => e > 0).toList();
}

Map<String, dynamic> _map(Object? value) => value is Map<String, dynamic> ? value : const {};

List<Map<String, dynamic>> _list(Object? value) =>
    value is List ? value.whereType<Map<String, dynamic>>().toList() : const [];

int _int(Object? value) => switch (value) {
  final int v => v,
  final num v => v.toInt(),
  final String v => int.tryParse(v) ?? 0,
  _ => 0,
};

String _text(Object? value) => value is String ? value : '';
