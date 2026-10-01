/// GitHub #154 and #155.
///
/// #154: a public message sent while the app was running never showed up. The forum stamps it with the time it was
/// written but delivers it to the members in batches, so it reaches an account with an old time; the running app had
/// moved its fetch window past that time and dropped it. Unread broadcast messages are now kept whatever their time.
///
/// #155: the homepage block of the `Kahrpba` plugin is back, and its "见习天使" (new members) tab lists one link per
/// row ("欢迎NAME加入~"). The parser wanted a thread and an author link, dropped every row and left an empty card as
/// tall as the full ones. Such rows are parsed now, and tabs without any row are left out.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/homepage/bloc/homepage_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:universal_html/parsing.dart';

String _data(String name) => File('test/data/$name').readAsStringSync();

/// The public message list page with one message, as the forum renders it (2026-10-01, formhash removed).
String _announcePage({required bool unread, String time = '2026-10-1 11:16'}) =>
    '''
<html><body><div class="pml">
<dl id="gpmlist_5" class="bbda cur1 cl${unread ? ' newpm' : ''}">
<dd class="y mtm pm_o"><a href="javascript:;" id="pm_g_5" class="o">菜单</a></dd>
<dd class="m avt">${unread ? '<div class="newpm_avt" title="有未读消息"></div>' : ''}
<a href="home.php?mod=space&amp;do=pm&amp;subop=viewg&amp;pmid=5"><img src="static/image/common/systempm.png" alt="" /></a>
</dd>
<dd class="ptm pm_c">
<span id="p_gpmid_5">【坛庆】天使动漫16周年~跟帖送祝福发50威望50天使币，还有各种活动等你参加~~</span> &nbsp;
<span class="xg1"><span title="$time">9&nbsp;小时前</span></span>&nbsp;
<a href="home.php?mod=space&amp;do=pm&amp;subop=viewg&amp;pmid=5" id="gpmlist_5_a">查看</a>
</dd>
</dl>
</div></body></html>''';

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('#154 public messages', () {
    final empty = parseHtmlDocument('<html><body></body></html>');
    final sent = DateTime(2026, 10, 1, 11, 16).millisecondsSinceEpoch ~/ 1000;
    // The running app polls every minute: its window starts two hours after the message was written.
    final since = sent + 2 * 3600;

    NotificationV2 fetch({required bool unread, int? since}) => NotificationV2.fromDocuments(
      noticeDoc: empty,
      personalMessageDoc: empty,
      broadcastMessageDoc: parseHtmlDocument(_announcePage(unread: unread)),
      since: since,
    );

    test('the live markup parses: pmid, time of writing, unread flag', () {
      final message = fetch(unread: true).broadcastMessageList.single;
      expect(message.pmid, 5);
      expect(message.timestamp, sent);
      expect(message.alreadyRead, isFalse);
      expect(message.data, contains('坛庆'));
    });

    test('an unread message older than the fetch window is still fetched', () {
      expect(fetch(unread: true, since: since).broadcastMessageList.map((e) => e.pmid), [5]);
    });

    test('a read message older than the window stays out, as before', () {
      expect(fetch(unread: false, since: since).broadcastMessageList, isEmpty);
      expect(fetch(unread: false, since: sent).broadcastMessageList, hasLength(1), reason: 'inside the window');
    });

    test('it is news once: not stored yet it notifies, stored by pmid it does not', () {
      final fetched = fetch(unread: true, since: since);
      const none = NotificationGroup(noticeList: [], personalMessageList: [], broadcastMessageList: []);
      expect(freshNotifications(fetched: fetched, stored: none).broadcastMessageList, hasLength(1));
      final stored = NotificationGroup(
        noticeList: const [],
        personalMessageList: const [],
        broadcastMessageList: [BroadcastMessageEntity(uid: 1000, timestamp: sent, data: 'x', pmid: 5)],
      );
      expect(freshNotifications(fetched: fetched, stored: stored).broadcastMessageList, isEmpty);
    });
  });

  group('#155 homepage tabs', () {
    final groups = HomepageBloc.parsePinnedThreadGroups(parseHtmlDocument(_data('homepage_kahrpba_tabs_x5.html')));

    test('every tab of the live block, in the order of the website', () {
      expect(groups.map((e) => e.title), ['最新活动', '见习天使', '动漫新闻', '最新主题', '今日话题', '动漫讨论', '发帖排行']);
      expect(groups.every((e) => e.threadList.isNotEmpty), isTrue);
      expect(groups.map((e) => e.isRank), [false, false, false, false, false, false, true]);
    });

    test('the new members tab lists the members: name, profile link, welcome text', () {
      final members = groups[1].threadList;
      expect(members, hasLength(9));
      final first = members.first;
      expect(first.authorName, 'user16');
      expect(first.threadTitle, '欢迎user16加入~');
      expect(first.authorUrl, contains('mod=space'));
      expect(first.threadUrl, first.authorUrl, reason: 'tapping the row opens the profile');
    });

    test('the rank rows keep a user and a post count', () {
      final rank = groups.last.threadList.first;
      expect(rank.threadUrl, contains('mod=space'));
      expect(rank.authorName, startsWith('今日共发'));
    });

    test('a tab without any row the app can show is left out instead of an empty card', () {
      final html = _data('homepage_kahrpba_tabs_x5.html').replaceAllMapped(
        RegExp('(<div id="Kahrpba_c_3"[^>]*>)(.*?)(<div id="Kahrpba_c_4")', dotAll: true),
        (m) => '${m.group(1)}</div>${m.group(3)}',
      );
      final left = HomepageBloc.parsePinnedThreadGroups(parseHtmlDocument(html));
      expect(left.map((e) => e.title), isNot(contains('动漫新闻')));
      expect(left, hasLength(6));
      expect(left.last.isRank, isTrue, reason: 'the rank is still known after the empty tab is left out');
      expect(left.where((e) => e.isRank), hasLength(1));
    });

    test('a page without the block has no tabs', () {
      expect(HomepageBloc.parsePinnedThreadGroups(parseHtmlDocument('<html><body></body></html>')), isEmpty);
    });
  });
}
