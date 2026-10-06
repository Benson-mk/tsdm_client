/// The forum's app API, stage 2: thread and forum pages in JSON mode (`tsdmapp=json`).
///
/// The forum renders the page as usual and the plugin answers the blocks the app's parsers read, cut from the final
/// output (`document`): same permissions and content as the web page, without header, footer and sidebar. The app
/// parses that with its existing parsers, so everything must come out exactly as from the web page.
///
/// The fixtures are pairs taken from the test forum (Discuz X5.0.2 with the plugin, test account ag_low, 2026-10-06):
/// the web page and the JSON answer of the same address, a few seconds apart.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_mappable/dart_mappable.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/forum/utils/forum_page_parser.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/parsing.dart';

String _read(String name) => File('test/data/tsdmapp/$name').readAsStringSync();

/// The text of an html fragment: serializers write `<br />` or `<br>`, quote attributes differently.
String _text(String? html) => html == null
    ? ''
    : (parseHtmlDocument('<html><body>$html</body></html>').body?.innerText ?? '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();

/// A model map with html strings reduced to their text, and fields that differ between two requests removed.
Object? _norm(Object? v) => switch (v) {
  final Map<String, dynamic> m => {
    for (final e in m.entries)
      if (!const {'postTime'}.contains(e.key)) e.key: _norm(e.value),
  },
  final List<dynamic> l => l.map(_norm).toList(),
  final String s when s.contains('<') => _text(s),
  _ => v,
};

/// Colors and font weights parsed from styles have no mapper of their own; the comparison only needs their value.
final class _ColorMapper extends SimpleMapper<Color> {
  const _ColorMapper();

  @override
  Color decode(Object value) => Color(value as int);

  @override
  Object? encode(Color self) => self.toARGB32();
}

final class _FontWeightMapper extends SimpleMapper<FontWeight> {
  const _FontWeightMapper();

  @override
  FontWeight decode(Object value) => FontWeight.values.firstWhere((e) => e.value == value);

  @override
  Object? encode(FontWeight self) => self.value;
}

final class _ThreadStateMapper extends SimpleMapper<ThreadStateModel> {
  const _ThreadStateMapper();

  @override
  ThreadStateModel decode(Object value) => ThreadStateModel.values.byName(value as String);

  @override
  Object? encode(ThreadStateModel self) => self.name;
}

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    MapperContainer.globals.useAll([const _ColorMapper(), const _FontWeightMapper(), const _ThreadStateMapper()]);
  });

  test('a web page answer is parsed as it is', () {
    final doc = tsdmAppPageDocument('<html><body><div id="postlist">x</div></body></html>');
    expect(doc.querySelector('div#postlist')?.innerText, 'x');
  });

  test('a JSON answer becomes the page of its blocks, with the link to the thread', () {
    final doc = tsdmAppPageDocument(
      jsonEncode({
        'ok': 1,
        'type': 'thread',
        'thread': {'tid': 42},
        'document': '<div id="postlist">x</div>',
      }),
    );
    expect(doc.querySelector('head > link')?.attributes['href'], 'forum.php?mod=viewthread&tid=42');
    expect(doc.querySelector('div#postlist')?.innerText, 'x');
  });

  test('withTsdmAppJson keeps the query', () {
    expect(
      withTsdmAppJson('https://x/forum.php?mod=viewthread&tid=1'),
      'https://x/forum.php?mod=viewthread&tid=1&tsdmapp=json',
    );
  });

  for (final name in ['thread_plain', 'thread_hide', 'thread_paid', 'thread_page2', 'thread_denied']) {
    test('$name: the JSON answer parses like the web page', () {
      final web = parseThreadDocument(parseHtmlDocument(_read('$name.html')), 1);
      final api = parseThreadDocument(tsdmAppPageDocument(_read('$name.json')), 1);
      expect(api.postList, isNotEmpty);
      expect(api.tid, web.tid);
      expect(api.title, web.title);
      expect(api.fid, web.fid);
      expect(api.forumName, web.forumName);
      expect(api.currentPage, web.currentPage);
      expect(api.totalPages, web.totalPages);
      expect(api.havePermission, web.havePermission);
      expect(api.needLogin, web.needLogin);
      expect(api.threadClosed, web.threadClosed);
      expect(api.threadSoftClosed, web.threadSoftClosed);
      expect(api.isDraft, web.isDraft);
      expect(api.latestModAct, web.latestModAct);
      // The JSON answer was fetched a moment after the web page, its view count is one more: not compared.
      expect(api.replyCount, web.replyCount);
      expect(api.threadType?.name, web.threadType?.name);
      expect(api.breadcrumbs.map((e) => e.description), web.breadcrumbs.map((e) => e.description));
      expect(api.postMedals.length, web.postMedals.length);
      expect(_norm(api.replyParameters?.toMap()), _norm(web.replyParameters?.toMap()));
      expect(api.postList.length, web.postList.length);
      for (var i = 0; i < web.postList.length; i++) {
        // Locked parts (purchase, reply to see…) have no mapper: compared by their description.
        expect(api.postList[i].locked.map((e) => '$e'), web.postList[i].locked.map((e) => '$e'), reason: 'post #$i');
        expect(
          _norm(api.postList[i].copyWith(locked: const []).toMap()),
          _norm(web.postList[i].copyWith(locked: const []).toMap()),
          reason: 'post #$i',
        );
      }
    });
  }

  test('a thread with hidden content: the hidden part stays hidden as on the web page', () {
    final web = parseThreadDocument(parseHtmlDocument(_read('thread_hide.html')), 1);
    final api = parseThreadDocument(tsdmAppPageDocument(_read('thread_hide.json')), 1);
    expect(api.postList.first.locked.length, web.postList.first.locked.length);
    expect(_text(api.postList.first.data), contains('如果您要查看本帖隐藏内容'));
    expect(_read('thread_hide.json'), isNot(contains('HIDDEN_SENTINEL_A')));
  });

  test('the JSON answer carries no member data beyond the page', () {
    for (final name in ['thread_plain', 'thread_hide', 'thread_paid', 'thread_page2', 'forum_fid2']) {
      final raw = _read('$name.json');
      for (final key in ['"password"', '"email"', '"secmobile"', '"loginname"', '"regip"', '"lastip"', '"useip"']) {
        expect(raw, isNot(contains(key)), reason: '$name $key');
      }
    }
  });

  test('forum page: the JSON answer parses like the web page', () {
    final web = parseForumPage(parseHtmlDocument(_read('forum_fid2.html')), '2');
    final api = parseForumPage(tsdmAppPageDocument(_read('forum_fid2.json')), '2');
    // The test forum's X5 template lists threads as <li>, which the app (written for the forum's own <tbody> rows)
    // does not read on either page; the production pages are compared outside the repository (see the spec).
    expect(api.title, web.title);
    expect(api.needLogin, web.needLogin);
    expect(api.havePermission, web.havePermission);
    expect(api.canLoadMore, web.canLoadMore);
    expect(api.currentPage, web.currentPage);
    expect(api.totalPages, web.totalPages);
    expect(_text(api.rulesElement?.innerHtml), _text(web.rulesElement?.innerHtml));
    expect(
      _norm(api.normalThreadList.map((e) => e.toMap()).toList()),
      _norm(web.normalThreadList.map((e) => e.toMap()).toList()),
    );
    expect(
      _norm(api.stickThreadList.map((e) => e.toMap()).toList()),
      _norm(web.stickThreadList.map((e) => e.toMap()).toList()),
    );
    expect(
      _norm(api.subredditList.map((e) => e.toMap()).toList()),
      _norm(web.subredditList.map((e) => e.toMap()).toList()),
    );
    expect(api.filterTypeList.map((e) => e.name), web.filterTypeList.map((e) => e.name));
    expect(api.filterSpecialTypeList.length, web.filterSpecialTypeList.length);
    expect(api.filterOrderList.length, web.filterOrderList.length);
    expect(api.filterDatelineList.length, web.filterDatelineList.length);
  });

  test('forum page without permission: the same message, nothing listed', () {
    final web = parseForumPage(parseHtmlDocument(_read('forum_denied.html')), '26');
    final api = parseForumPage(tsdmAppPageDocument(_read('forum_denied.json')), '26');
    expect(api.havePermission, web.havePermission);
    expect(api.havePermission, isFalse);
    expect(api.needLogin, web.needLogin);
    expect(api.permissionDeniedMessage?.innerText.trim(), web.permissionDeniedMessage?.innerText.trim());
    expect(api.normalThreadList, isEmpty);
  });
}
