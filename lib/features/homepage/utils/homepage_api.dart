import 'package:collection/collection.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
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

  /// The request the answer names when it is the forum's own, else the one the page's scripts hold, if any.
  @override
  Uri? get dailyVisitUri => rewards.dailyVisitUriOfSource(checknewpm ?? '') ?? rewards.dailyVisitUri(document);
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
/// The page is then built by `homepageStateFromApi` and [forumGroupsFromApi]; the `document` of the answer, when
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

/// The status bar of a structured homepage answer [json] (`stats`: 今日, 昨日, 帖子), as the web page's `p.chart.z`
/// is read; empty when the answer has none (a message).
ForumStatus forumStatusFromApi(Map<String, dynamic> json) {
  final stats = json['stats'];
  if (stats is! Map<String, dynamic>) {
    return const ForumStatus.empty();
  }
  return ForumStatus(
    todayCount: '${_int(stats['todayposts'])}',
    yesterdayCount: '${_int(stats['yesterdayposts'])}',
    threadCount: '${_int(stats['posts'])}',
  );
}

/// The viewer of a structured homepage answer [json] with the links of its status bar (`user`, `links`: 我的帖子,
/// 最新回复 when the guide is on), as the web page's header and `div#chart > div.y` are read: the account [username]
/// the app has wins, as it always did (the answer's name otherwise, empty for a guest); the avatar [avatarUrl] the
/// app has wins, the answer's is taken when the app has none.
LoggedUserInfo loggedUserInfoFromApi(Map<String, dynamic> json, {String? username, String? avatarUrl}) {
  final user = _map(json['user']);
  final avatar = _text(user['avatar']);
  final links = _list(json['links'])
      .map((e) => (_text(e['title']), _text(e['url'])))
      .where((e) => e.$2.isNotEmpty)
      .map((e) => (e.$1.isEmpty ? 'unknown' : e.$1, e.$2))
      .toList();
  return LoggedUserInfo(
    username: username ?? _text(user['username']),
    relatedLinkPairList: links,
    avatarUrl: avatarUrl ?? (avatar.isEmpty ? null : avatar),
  );
}

/// The swiper of a structured homepage answer [json] (`slides`): every slide with a picture, in the order given.
List<SwiperUrl> swiperUrlsFromApi(Map<String, dynamic> json) => _list(json['slides'])
    .map((e) => SwiperUrl(coverUrl: _text(e['image']), linkUrl: _text(e['url'])))
    .where((e) => e.coverUrl.isNotEmpty)
    .toList();

/// The unread notice count and the new message mark of a structured homepage answer [json] (`unread`), as the web
/// page's header is read (`buildUnreadInfoStatus`).
(int unreadNoticeCount, bool hasUnreadMessage) unreadInfoFromApi(Map<String, dynamic> json) {
  final unread = _map(json['unread']);
  return (_int(unread['notice']), _int(unread['pm']) > 0);
}

/// The `Kahrpba` tabs of a structured homepage answer [json] (`blocks`), in the order given, see
/// `homepageStateFromApi`; empty for a guest (the forum prints the block to members only) and on a forum without
/// the plugin.
///
/// A `Kahrpba` template the plugin cannot read (an older one, on the production forum) gives no `blocks` and the
/// whole `table#Kahrpba` as `blocks_html` instead: the tabs are then parsed from it as from the page
/// ([parsePinnedThreadGroupsFromDocument]), with the reordering and the rank mark of that parser.
List<PinnedThreadGroup> pinnedThreadGroupsFromApi(Map<String, dynamic> json) {
  final blocks = _list(json['blocks']);
  final blocksHtml = _text(json['blocks_html']);
  if (blocks.isEmpty && blocksHtml.trim().isNotEmpty) {
    return parsePinnedThreadGroupsFromDocument(parseHtmlDocument('<html><body>$blocksHtml</body></html>'));
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

/// For the following structure, filter and combine thread and its author.
///
/// <div class="Kahrpba_threads">
///   <a href="thread_url">
///     thread_title
///   </a>
///   <a href="author_url">
///     <em>author_name</em>
///   </a>
///
/// Filter out thread_url, thread_title, author_url and author_name.
///
/// Where [element] is <div class="Kahrpba_threads"> node.
PinnedThread? _pinnedThreadOfElement(uh.Element element) {
  final allNode = element.querySelectorAll('a').toList();
  // The "见习天使" (new members) tab lists one link per row, to the new member's space: "欢迎NAME加入~" (GitHub #155).
  // The member is both the row and its "author", so the tile shows the avatar and name and opens the profile.
  if (allNode.length == 1) {
    final url = allNode.single.attributes['href'];
    final text = allNode.single.firstEndDeepText()?.trim();
    if (url == null || text == null || text.isEmpty || !url.contains('mod=space')) {
      talker.info('skip pinned row with one link that is not a user space');
      return null;
    }
    final name = RegExp('^欢迎(.+?)加入').firstMatch(text)?.group(1)?.trim();
    return PinnedThread(
      threadUrl: url,
      threadTitle: text,
      authorUrl: url,
      authorName: name == null || name.isEmpty ? text : name,
    );
  }
  // There should be two <a> in children.
  if (allNode.length != 2) {
    talker.info(
      'skip build thread author pair: '
      'node count is ${allNode.length}',
    );
    return null;
  }

  final threadUrl = allNode[0].attributes['href'];
  if (threadUrl == null) {
    talker.info('skip incomplete thread author pair: thread url not found');
    return null;
  }

  final threadTitle = allNode[0].firstEndDeepText();
  if (threadTitle == null) {
    talker.info('skip incomplete thread author pair: thread title not found');
    return null;
  }

  final authorUrl = allNode[1].attributes['href'];
  if (authorUrl == null) {
    talker.info('skip incomplete thread author pair: author url not found');
    return null;
  }

  final authorName = allNode[1].firstEndDeepText();
  if (authorName == null) {
    talker.info('skip incomplete thread author pair: author name not found');
    return null;
  }

  return PinnedThread(threadUrl: threadUrl, threadTitle: threadTitle, authorUrl: authorUrl, authorName: authorName);
}

/// The tabs of the homepage block of the `Kahrpba` plugin (最新活动, 见习天使, ..., 发帖排行) read from the web page
/// [document] (or the `blocks_html` of a structured answer), in the order the website shows them; tabs without any
/// row the app can show are left out (GitHub #155).
List<PinnedThreadGroup> parsePinnedThreadGroupsFromDocument(uh.Document document) {
  final pinnedThreadGroupList = <PinnedThreadGroup>[];
  final navNameList = document
      .querySelector('td#Kahrpba_nav')
      ?.children
      .map((e) => e.firstEndDeepText())
      .whereType<String>()
      .toList();
  final navShowList = document
      .querySelector('td#Kahrpba_show')
      ?.children
      .where((e) => e.id.startsWith('Kahrpba_c'))
      .whereType<uh.Element>()
      .toList();

  if (navNameList != null && navShowList != null && navNameList.length == navShowList.length) {
    if (navNameList.length >= 7) {
      navNameList
        ..swap(4, 6)
        ..swap(5, 6);
    }
    final count = navNameList.length;
    for (var i = 0; i < count; i++) {
      final threadList = navShowList[i]
          .querySelectorAll('div.Kahrpba_threads')
          .map(_pinnedThreadOfElement)
          .whereType<PinnedThread>()
          .toList();
      // Kept even when empty here so the reordering below still finds every tab where it expects it; empty
      // groups are left out after that.
      final group = PinnedThreadGroup(title: navNameList[i], threadList: threadList);
      pinnedThreadGroupList.add(group);
    }

    // The sort on server side is not as displayed, fix the sort to keep the
    // same with website appearance.
    if (pinnedThreadGroupList.length >= 7) {
      pinnedThreadGroupList
        ..swap(4, 5)
        ..swap(5, 6);
      // The rank is the last tab once reordered; marked before empty tabs are left out and the indices move.
      pinnedThreadGroupList[6] = pinnedThreadGroupList[6].copyWith(isRank: true);
    }
  }
  // A tab without any row the app can show would be an empty card as tall as the full ones (GitHub #155).
  pinnedThreadGroupList.removeWhere((e) => e.threadList.isEmpty);
  return pinnedThreadGroupList;
}

/// The forum groups of a structured homepage answer [json] for the topics tab, as `buildGroupListFromDocument`
/// reads them from the web page: the "我收藏的版块" panel first when the viewer has favorite forums
/// (`favorite_forums`, each looked up among the forums of the categories, or among their subforums, which the page
/// lists by name only; one listed nowhere, a forum the viewer may not see, is left out of the panel but still
/// seeded, see [favoriteForumIdsOf]), then every category (`forum.php?gid=`) with its forums ([Forum.fromApi]: the
/// latest thread, the subforums the forum's setting lists) and its moderators (`moderators`, the names of the page's
/// 分区版主 row, plugin 2.4.0; none before).
List<ForumGroup> forumGroupsFromApi(Map<String, dynamic> json) {
  final categories = _list(json['categories']);
  final groups = categories
      .map(
        (c) => ForumGroup(
          name: _text(c['name']),
          url: 'forum.php?gid=${_int(c['fid'])}',
          forumList: _list(c['forums']).map(Forum.fromApi).toList(),
          moderators: c['moderators'] is List
              ? (c['moderators'] as List).whereType<String>().where((e) => e.isNotEmpty).toList()
              : const [],
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
  // A subforum is listed under its forum by id and name only: the panel shows it with those, as the page does.
  final subforums = {
    for (final c in categories)
      for (final f in _list(c['forums']))
        for (final sub in _list(f['subforums']))
          if (_int(sub['fid']) > 0) _int(sub['fid']): Forum.fromApi({'fid': _int(sub['fid']), 'name': sub['name']}),
  };
  final favorites = favoriteIds.map((fid) => forums[fid] ?? subforums[fid]).whereType<Forum>().toList();
  if (favorites.length != favoriteIds.length) {
    talker.info(
      'favorite forums not among the categories left out of the panel: '
      '${favoriteIds.where((e) => !forums.containsKey(e) && !subforums.containsKey(e))}',
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
