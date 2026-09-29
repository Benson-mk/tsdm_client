import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_bbcode_parser/dart_bbcode_parser.dart';
import 'package:dart_quill_delta/dart_quill_delta.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bbcode_editor/flutter_bbcode_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/bbcode_editor_controller.dart';
import 'package:tsdm_client/features/editor/bloc/user_mention_cubit.dart';
import 'package:tsdm_client/features/editor/repository/mention_repository.dart';
import 'package:tsdm_client/features/editor/utils/mention.dart';
import 'package:tsdm_client/features/editor/utils/mention_trigger.dart';
import 'package:tsdm_client/features/editor/widgets/mention_picker.dart';
import 'package:tsdm_client/features/friend/utils/parse_friend.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:universal_html/parsing.dart';

/// Issue #8: typing `@` in the editor opens the mention picker, and the picker lists the current user's own friends
/// (from the friends list page, with uid and avatar) besides the official `@` list, which may be empty for the user
/// group even when the user has friends. Fixtures are the friend list pages of test_024/test_041 (uids 1000/1001,
/// Alice/Bob) and the getatuser document of test_022.
const _atUserXml = '<?xml version="1.0" encoding="utf-8"?>\n<root><![CDATA[Alice,Bob, Carol,]]></root>';

String _data(String name) => File('test/data/$name').readAsStringSync();

/// Serves the friends list (first page and `page=2`) and the official `@` list, recording every request.
final class _RoutingAdapter implements HttpClientAdapter {
  _RoutingAdapter({
    this.friendsFirst = 'friend_list_own_x5.html',
    this.friendsStatus = 200,
    this.atStatus = 200,
    this.atplus = false,
  });

  /// Whether the forum has the `atplus` plugin: `plugin.php?id=atplus:search` answers its JSON.
  bool atplus;

  /// Form fields of every `atplus` request, in order.
  final atplusForms = <Map<String, String>>[];

  static const friendsNext = 'friend_list_last_x5.html';
  static const String atUsers = _atUserXml;

  final String friendsFirst;
  int friendsStatus;
  int atStatus;

  final requests = <Uri>[];

  /// When set, every answer waits for it first (a slow connection).
  Completer<void>? gate;

  Iterable<Uri> get friendRequests => requests.where((u) => u.path == '/home.php');
  Iterable<Uri> get atRequests => requests.where((u) => u.path == '/misc.php');
  Iterable<Uri> get atplusRequests => requests.where((u) => u.path == '/plugin.php');

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    requests.add(uri);
    if (gate != null) {
      await gate!.future;
    }
    if (atplus && uri.path == '/plugin.php' && uri.queryParameters['id'] == 'atplus:search') {
      final data = options.data;
      final form = data is Map ? data.map((k, v) => MapEntry('$k', '$v')) : Uri.splitQueryString('${data ?? ''}');
      atplusForms.add(form);
      final body = switch (form['op']) {
        'init' => _atplusInit,
        'search' => form['q'] == 'dave' ? _atplusSearchDave : '{"ok":1,"list":[]}',
        _ => '{"ok":0}',
      };
      return ResponseBody.fromString(
        body,
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json; charset=utf-8'],
        },
      );
    }
    if (uri.path == '/misc.php' && uri.queryParameters['mod'] == 'getatuser') {
      return ResponseBody.fromString(
        atUsers,
        atStatus,
        headers: {
          Headers.contentTypeHeader: ['text/xml; charset=utf-8'],
        },
      );
    }
    if (uri.path == '/home.php' && uri.queryParameters['do'] == 'friend') {
      final name = uri.queryParameters['page'] == '2' ? friendsNext : friendsFirst;
      return ResponseBody.fromString(
        _data(name),
        friendsStatus,
        headers: {
          Headers.contentTypeHeader: ['text/html; charset=utf-8'],
        },
      );
    }
    return ResponseBody.fromString('not found', 404);
  }

  @override
  void close({bool force = false}) {}
}

/// `op=init` of the `atplus` plugin: one recent user, one friend (shape of the live answer, fake users).
const _atplusInit =
    '{"ok":1,"recent":[{"uid":1002,"username":"Carol","avatar":"./data/avatar/000/00/10/02_avatar_small.jpg",'
    '"group":"使者","friend":0}],"friends":[{"uid":1001,"username":"Bob",'
    '"avatar":"./data/avatar/000/00/10/01_avatar_small.jpg","group":"梦幻","friend":1}],"groups":[]}';

/// `op=search` of the `atplus` plugin for `dave`.
const _atplusSearchDave =
    '{"ok":1,"list":[{"uid":1003,"username":"Dave","avatar":"./data/avatar/000/00/10/03_avatar_small.jpg",'
    '"group":"使者","friend":0},{"uid":1001,"username":"Bob","avatar":"","group":"梦幻","friend":1}]}';

/// Never answers: avatars are not fetched in tests.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late _RoutingAdapter adapter;

  Future<void> registerNet(_RoutingAdapter a) async {
    adapter = a;
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter),
      );
    await settings.init();
  }

  Future<void> unregisterNet() async {
    await getIt.reset();
    await settings.dispose();
    await db.close();
  }

  group('MentionRepository merges the own friends list and the official @ list', () {
    tearDown(unregisterNet);

    test('friends first with uid and avatar, then the @ names that are not friends; one request per source', () async {
      await registerNet(_RoutingAdapter());
      final repo = MentionRepository();
      final result = (await repo.loadCandidates(selfUid: '1000').run()).toNullable()!;
      expect(result.friends.map((e) => (e.uid, e.username)), [('1001', 'Bob')]);
      expect(result.friends.single.avatarUrl, 'https://example.com/avatar/1.png');
      expect(result.others, ['Alice', 'Carol'], reason: 'Bob is a friend already');
      expect(result.friendsMessage, isNull);

      expect(adapter.friendRequests, hasLength(1));
      final friendUri = adapter.friendRequests.single;
      expect(friendUri.host, baseHost);
      expect(friendUri.queryParameters, containsPair('mod', 'space'));
      expect(friendUri.queryParameters, containsPair('uid', '1000'));
      expect(friendUri.queryParameters, containsPair('do', 'friend'));
      expect(adapter.atRequests, hasLength(1));
      expect(adapter.atRequests.single.queryParameters, containsPair('mod', 'getatuser'));

      final again = (await repo.loadCandidates(selfUid: '1000').run()).toNullable()!;
      expect(again.friends.single.username, 'Bob');
      expect(
        adapter.atplusRequests,
        hasLength(1),
        reason: 'the atplus plugin is asked first, it is not installed here',
      );
      expect(adapter.requests, hasLength(3), reason: 'reopening the picker uses the cache');

      await repo.loadCandidates(selfUid: '1000', force: true).run();
      expect(adapter.requests, hasLength(6), reason: 'the reload button asks the plugin and both sources again');
    });

    test('follows the next page link and keeps friends unique by uid', () async {
      await registerNet(_RoutingAdapter(friendsFirst: 'friend_list_x5.html'));
      final first = parseFriendListPage(parseHtmlDocument(_data('friend_list_x5.html')));
      final last = parseFriendListPage(parseHtmlDocument(_data('friend_list_last_x5.html')));
      final expected = {...first.items.map((e) => e.uid), ...last.items.map((e) => e.uid)};
      expect(first.items, hasLength(24));
      expect(last.items, hasLength(19));

      final result = (await MentionRepository().loadCandidates(selfUid: '1000').run()).toNullable()!;
      expect(result.friends.map((e) => e.uid).toSet(), expected);
      expect(result.friends, hasLength(expected.length));
      expect(result.friends.first.username, 'Carol');
      expect(adapter.friendRequests, hasLength(2));
      expect(adapter.friendRequests.last.queryParameters, containsPair('page', '2'));
    });

    test('the @ list failing still gives the friends, and the failure is not cached', () async {
      await registerNet(_RoutingAdapter(atStatus: 500));
      final repo = MentionRepository();
      final result = (await repo.loadCandidates(selfUid: '1000').run()).toNullable()!;
      expect(result.friends.map((e) => e.username), ['Bob']);
      expect(result.others, isEmpty);
      expect(result.friendsMessage, isNull);

      adapter.atStatus = 200;
      final healed = (await repo.loadCandidates(selfUid: '1000').run()).toNullable()!;
      expect(healed.others, ['Alice', 'Carol']);
      expect(adapter.atRequests, hasLength(2));
    });

    test('the friends list failing still gives the @ names, with a message', () async {
      await registerNet(_RoutingAdapter(friendsStatus: 500));
      final result = (await MentionRepository().loadCandidates(selfUid: '1000').run()).toNullable()!;
      expect(result.friends, isEmpty);
      expect(result.others, ['Alice', 'Bob', 'Carol']);
      expect(result.friendsMessage, isNotNull);
    });

    test('a private friends list answers its notice as the message', () async {
      await registerNet(_RoutingAdapter(friendsFirst: 'friend_list_privacy_x5.html'));
      final result = (await MentionRepository().loadCandidates(selfUid: '1000').run()).toNullable()!;
      expect(result.friends, isEmpty);
      expect(result.friendsMessage, contains('隐私设置'));
      expect(result.others, ['Alice', 'Bob', 'Carol']);
    });

    test('nobody logged in: only the @ list is asked; both sources failing is a failure', () async {
      await registerNet(_RoutingAdapter());
      final result = (await MentionRepository().loadCandidates(selfUid: null).run()).toNullable()!;
      expect(result.friends, isEmpty);
      expect(result.others, ['Alice', 'Bob', 'Carol']);
      expect(adapter.friendRequests, isEmpty);

      adapter
        ..atStatus = 500
        ..friendsStatus = 500;
      expect((await MentionRepository().loadCandidates(selfUid: '1000').run()).isLeft(), isTrue);
    });

    test('another account or a guest never gets the @ list loaded for the previous uid', () async {
      await registerNet(_RoutingAdapter());
      final repo = MentionRepository();
      await repo.loadCandidates(selfUid: '1000').run();
      expect(adapter.atRequests, hasLength(1));

      final other = (await repo.loadCandidates(selfUid: '2000').run()).toNullable()!;
      expect(adapter.atRequests, hasLength(2), reason: 'the @ list is per account, ask again for the new uid');
      expect(adapter.friendRequests.last.queryParameters, containsPair('uid', '2000'));
      expect(other.others, ['Alice', 'Carol']);

      await repo.loadCandidates(selfUid: null).run();
      expect(adapter.atRequests, hasLength(3), reason: 'after logout the guest list is asked, not the old one');

      await repo.loadCandidates(selfUid: null).run();
      expect(adapter.atRequests, hasLength(3), reason: 'the guest result is cached like any other');
    });

    test('after a friends-only failure a later open for another uid refetches the @ list', () async {
      await registerNet(_RoutingAdapter(friendsStatus: 500));
      final repo = MentionRepository();
      await repo.loadCandidates(selfUid: '1000').run();
      expect(adapter.atRequests, hasLength(1));

      await repo.loadCandidates(selfUid: '1000').run();
      expect(adapter.atRequests, hasLength(1), reason: 'same uid: the @ list is reused, only the friends retry');
      expect(adapter.friendRequests, hasLength(2));

      await repo.loadCandidates(selfUid: '2000').run();
      expect(adapter.atRequests, hasLength(2), reason: 'the half-cached @ list belongs to 1000');
    });
  });

  group('UserMentionCubit filters locally', () {
    setUp(() => registerNet(_RoutingAdapter()));
    tearDown(unregisterNet);

    test('keyword narrows both lists without touching the network', () async {
      final cubit = UserMentionCubit(MentionRepository(), selfUid: '1000');
      addTearDown(cubit.close);
      await cubit.load();
      expect(cubit.state.recommendStatus, UserMentionStatus.success);
      expect(cubit.state.visibleFriends.map((e) => e.username), ['Bob']);
      expect(cubit.state.visibleOthers, ['Alice', 'Carol']);
      final requestCount = adapter.requests.length;

      cubit.setKeyword('bo');
      expect(cubit.state.visibleFriends.map((e) => e.username), ['Bob']);
      expect(cubit.state.visibleOthers, isEmpty);
      expect(cubit.state.hasExactMatch, isFalse);

      cubit.setKeyword('BOB ');
      expect(cubit.state.keyword, 'BOB');
      expect(cubit.state.hasExactMatch, isTrue);

      cubit.setKeyword('ar');
      expect(cubit.state.visibleFriends, isEmpty);
      expect(cubit.state.visibleOthers, ['Carol']);

      cubit.setKeyword('zz');
      expect(cubit.state.visibleFriends, isEmpty);
      expect(cubit.state.visibleOthers, isEmpty);

      cubit.setKeyword('');
      expect(cubit.state.visibleFriends.map((e) => e.username), ['Bob']);
      expect(cubit.state.visibleOthers, ['Alice', 'Carol']);
      expect(adapter.requests, hasLength(requestCount));
    });

    test('closing the cubit while the load is in flight does not emit on the closed cubit', () async {
      final gate = Completer<void>();
      adapter.gate = gate;
      final cubit = UserMentionCubit(MentionRepository(), selfUid: '1000');
      final loading = cubit.load();
      expect(cubit.state.recommendStatus, UserMentionStatus.loading);
      await cubit.close();
      gate.complete();
      await expectLater(loading, completes);
      expect(cubit.state.recommendStatus, UserMentionStatus.loading, reason: 'nothing emitted after close');
    });
  });

  group('MentionTrigger', () {
    late FocusNode node;

    Future<void> pumpFocus(WidgetTester tester) async {
      node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Focus(focusNode: node, autofocus: true, child: const SizedBox()),
        ),
      );
      await tester.pump();
      expect(node.hasFocus, isTrue);
    }

    /// Attach a trigger to [controller] that answers [answer] and records the offsets it was asked for.
    (MentionTrigger, List<int>) attach(BBCodeEditorController controller, {String? answer = 'Alice'}) {
      final asked = <int>[];
      final trigger = MentionTrigger(
        controller: controller,
        focusNode: node,
        pick: (offset) async {
          asked.add(offset);
          return answer;
        },
      )..attach();
      addTearDown(trigger.dispose);
      return (trigger, asked);
    }

    testWidgets('a typed @ after whitespace opens the picker once and becomes the mention chip', (tester) async {
      await pumpFocus(tester);
      final controller = buildBBCodeEditorController();
      addTearDown(controller.dispose);
      final (_, asked) = attach(controller);

      controller.insertPlainText('hi ');
      await tester.pump(const Duration(milliseconds: 300));
      expect(asked, isEmpty, reason: 'a multi character insert never fires');

      controller.insertPlainText('@');
      expect(asked, isEmpty, reason: 'debounced');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(asked, [3]);
      await tester.pump(const Duration(milliseconds: 300));
      expect(asked, [3], reason: 'fires once');

      final plain = controller.document.toPlainText();
      expect(plain, isNot(contains('@')));
      final ops = controller.document.toDelta().toList();
      expect(ops[0].data, 'hi ');
      expect(ops[1].data, {'bbcodeUserMention': '{"username":"Alice"}'});
      expect(controller.toForumBBCode(), 'hi [@]Alice[/@]');
      expect(toOfficialMentions(controller.toForumBBCode()), 'hi @\u2063Alice\u2063 ');
      expect(controller.selection, const TextSelection.collapsed(offset: 4));
    });

    testWidgets('no picker for a@b, for a multi character insert, or without focus', (tester) async {
      await pumpFocus(tester);
      final controller = buildBBCodeEditorController();
      addTearDown(controller.dispose);
      final (_, asked) = attach(controller);

      controller
        ..insertPlainText('a')
        ..insertPlainText('@');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(asked, isEmpty, reason: 'a@b is an address, not a mention');

      controller.insertPlainText(' @');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(asked, isEmpty, reason: 'pasted text is not typed');

      node.unfocus();
      await tester.pump();
      controller
        ..insertPlainText(' ')
        ..insertPlainText('@');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(asked, isEmpty, reason: 'the editor is not focused');
      expect(controller.toForumBBCode(), 'a@ @ @');
    });

    testWidgets('dismissing the picker keeps the @, and typing on within the debounce does not interrupt', (
      tester,
    ) async {
      await pumpFocus(tester);
      final controller = buildBBCodeEditorController();
      addTearDown(controller.dispose);
      final (_, asked) = attach(controller, answer: null);

      controller.insertPlainText('hi ');
      await tester.pump(const Duration(milliseconds: 300));
      controller.insertPlainText('@');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(asked, [3]);
      expect(controller.toForumBBCode(), 'hi @');

      controller.insertPlainText(' ');
      await tester.pump(const Duration(milliseconds: 300));
      controller.insertPlainText('@');
      await tester.pump(const Duration(milliseconds: 100));
      controller.insertPlainText('x');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(asked, [3], reason: 'the caret moved past the @ before the debounce ended');
      expect(controller.toForumBBCode(), 'hi @ @x');
    });

    testWidgets('still works after the document is replaced', (tester) async {
      await pumpFocus(tester);
      final controller = buildBBCodeEditorController();
      addTearDown(controller.dispose);
      final (_, asked) = attach(controller);

      controller
        ..setDocumentFromDelta(parseBBCodeTextToDelta('[b]yo[/b] '))
        ..moveCursorToEnd();
      await tester.pump(const Duration(milliseconds: 300));
      expect(asked, isEmpty);
      // The document ends with the line break the editor keeps; type before it.
      controller
        ..moveCursorToPosition(3)
        ..insertPlainText('@');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(asked, [3]);
      expect(controller.toForumBBCode(), '[b]yo[/b] [@]Alice[/@]');

      controller
        ..setDocumentFromDelta(Delta()..insert('\n'))
        ..insertPlainText('@');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(asked, [3, 0], reason: 'at the start of the text');
      expect(controller.toForumBBCode(), '[@]Alice[/@]');
    });

    testWidgets('a username with brackets becomes exactly one mention chip with the full name', (tester) async {
      await pumpFocus(tester);
      for (final name in ['[TSDM]Alice', 'a]b', 'x[y', '[b]Bob[/b]']) {
        final controller = buildBBCodeEditorController();
        addTearDown(controller.dispose);
        final (_, asked) = attach(controller, answer: name);

        controller.insertPlainText('hi ');
        await tester.pump(const Duration(milliseconds: 300));
        controller.insertPlainText('@');
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        expect(asked, [3], reason: name);

        final embeds = controller.document
            .toDelta()
            .toList()
            .where((op) => op.data is Map && (op.data! as Map).containsKey('bbcodeUserMention'))
            .toList();
        expect(embeds, hasLength(1), reason: name);
        expect(embeds.single.data, {'bbcodeUserMention': '{"username":"$name"}'}, reason: name);
        expect(controller.document.toPlainText(), isNot(contains('@')), reason: name);
        expect(controller.toForumBBCode(), 'hi [@]$name[/@]', reason: name);
        expect(toOfficialMentions(controller.toForumBBCode()), 'hi @\u2063$name\u2063 ', reason: name);
      }
    });
  });

  group('atplus plugin (web @ panel since 2026-09)', () {
    tearDown(() async => unregisterNet());

    test('parses its user lists, avatars made absolute; anything else is not an answer', () {
      final init = jsonDecode(_atplusInit);
      final friends = parseAtplusUsers(init, 'friends', base: baseUrl)!;
      expect(friends.map((e) => (e.uid, e.username, e.groupName)), [('1001', 'Bob', '梦幻')]);
      expect(friends.single.avatarUrl, '$baseUrl/data/avatar/000/00/10/01_avatar_small.jpg');
      expect(parseAtplusUsers(init, 'recent', base: baseUrl)!.single.username, 'Carol');
      expect(parseAtplusUsers(init, 'groups', base: baseUrl), isEmpty);
      expect(parseAtplusUsers(init, 'missing', base: baseUrl), isEmpty);
      expect(parseAtplusUsers(const {'ok': 0}, 'list', base: baseUrl), isNull);
      expect(parseAtplusUsers('not found', 'list', base: baseUrl), isNull);
      expect(parseAtplusUsers(null, 'list', base: baseUrl), isNull);
    });

    test('with the plugin: recent and friends come from it, the stock sources are not asked', () async {
      await registerNet(_RoutingAdapter(atplus: true));
      final repo = MentionRepository();
      final result = (await repo.loadCandidates(selfUid: '1000').run()).toNullable()!;
      expect(result.siteSearch, isTrue);
      expect(result.recent.map((e) => e.username), ['Carol']);
      expect(result.friends.map((e) => e.username), ['Bob']);
      expect(result.others, isEmpty);
      expect(adapter.atplusForms, [
        {'op': 'init'},
      ]);
      expect(adapter.friendRequests, isEmpty);
      expect(adapter.atRequests, isEmpty);

      final found = (await repo.searchUsers('dave').run()).toNullable()!;
      expect(found.map((e) => e.username), ['Dave', 'Bob']);
      expect(adapter.atplusForms.last, {'op': 'search', 'q': 'dave'});
    });

    test('a guest does not ask the plugin', () async {
      await registerNet(_RoutingAdapter(atplus: true));
      await MentionRepository().loadCandidates(selfUid: null).run();
      expect(adapter.atplusForms, isEmpty);
    });

    test('the cubit searches the site for the keyword, results not already shown', () async {
      await registerNet(_RoutingAdapter(atplus: true));
      final cubit = UserMentionCubit(MentionRepository(), selfUid: '1000');
      addTearDown(cubit.close);
      await cubit.load();
      cubit.setKeyword('dave');
      await pumpEventQueue();
      expect(cubit.state.searchStatus, UserMentionStatus.success);
      expect(
        cubit.state.visibleSearchResults.map((e) => e.username),
        ['Dave', 'Bob'],
        reason: 'the server matched Bob too; he is not listed under friends for this keyword, so he is shown here',
      );
      expect(cubit.state.hasExactMatch, isTrue, reason: 'Dave was found');

      cubit.setKeyword('bo');
      await pumpEventQueue();
      expect(cubit.state.visibleFriends.map((e) => e.username), ['Bob']);
      expect(cubit.state.visibleSearchResults, isEmpty);
      expect(adapter.atplusForms.map((e) => e['q']).whereType<String>(), ['dave', 'bo']);
    });
  });

  group('mention picker sheet', () {
    setUp(() async {
      await registerNet(_RoutingAdapter());
      getIt.registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
      );
    });
    tearDown(() async {
      await getIt.get<ImageCacheProvider>().dispose();
      await unregisterNet();
    });

    /// A page with a button that pushes the sheet as a route and keeps what it popped with.
    Future<String? Function()> pumpHost(WidgetTester tester, MentionRepository repo, {String? selfUid = '1000'}) async {
      String? picked;
      var popped = false;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  popped = false;
                  picked = await Navigator.of(context).push<String>(
                    MaterialPageRoute(
                      builder: (_) => Scaffold(
                        body: MentionPickerSheet(repository: repo, selfUid: selfUid),
                      ),
                    ),
                  );
                  popped = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      return () {
        expect(popped, isTrue, reason: 'the sheet route popped');
        return picked;
      };
    }

    testWidgets('with the atplus plugin: recent, friends, and a site search result that can be picked', (
      tester,
    ) async {
      adapter.atplus = true;
      final repo = MentionRepository();
      final picked = await pumpHost(tester, repo);
      await tester.tap(find.text('open'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      final tr = LocaleSettings.instance.currentTranslations.bbcodeEditor.userMention;
      expect(find.text(tr.recent), findsOneWidget);
      expect(find.text('Carol'), findsOneWidget);
      expect(find.text('Bob'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'dave');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(find.text(tr.siteSearch), findsOneWidget);
      await tester.tap(find.text('Dave'));
      await tester.pumpAndSettle();
      expect(picked(), 'Dave');
    });

    testWidgets('lists the friend under Friends, tapping it picks the name', (tester) async {
      final repo = MentionRepository();
      // Warm the cache outside the fake async zone so the sheet renders from it.
      await tester.runAsync(() => repo.loadCandidates(selfUid: '1000').run());
      final result = await pumpHost(tester, repo);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final tr = tester.element(find.byType(MentionPickerSheet)).t.bbcodeEditor.userMention;
      expect(find.text(tr.randomFriend), findsOneWidget);
      expect(find.text('Bob'), findsOneWidget);
      expect(find.text(tr.others), findsOneWidget);
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Carol'), findsOneWidget);
      expect(find.text(tr.useTyped(name: '')), findsNothing);
      final friendsHeader = tester.getTopLeft(find.text(tr.randomFriend));
      expect(tester.getTopLeft(find.text('Bob')).dy, greaterThan(friendsHeader.dy));
      expect(tester.getTopLeft(find.text(tr.others)).dy, greaterThan(tester.getTopLeft(find.text('Bob')).dy));

      await tester.tap(find.text('Bob'));
      await tester.pumpAndSettle();
      expect(result(), 'Bob');
    });

    testWidgets('a keyword nobody matches offers to mention it as typed', (tester) async {
      final repo = MentionRepository();
      await tester.runAsync(() => repo.loadCandidates(selfUid: '1000').run());
      final result = await pumpHost(tester, repo);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final tr = tester.element(find.byType(MentionPickerSheet)).t.bbcodeEditor.userMention;

      await tester.enterText(find.byType(TextField), 'zz');
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text(tr.noMatch), findsOneWidget);
      expect(find.text('Bob'), findsNothing);
      expect(find.text(tr.others), findsNothing);
      expect(find.text(tr.useTyped(name: 'zz')), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'bo');
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Bob'), findsOneWidget);
      expect(find.text(tr.useTyped(name: 'bo')), findsOneWidget, reason: 'no candidate is exactly "bo"');

      await tester.enterText(find.byType(TextField), 'zz');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text(tr.useTyped(name: 'zz')));
      await tester.pumpAndSettle();
      expect(result(), 'zz');
    });

    testWidgets('showMentionPicker works without a logged in user and lists the @ names', (tester) async {
      final repo = MentionRepository();
      await tester.runAsync(() => repo.loadCandidates(selfUid: null).run());
      String? picked;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async => picked = await showMentionPicker(context, repository: repo),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final tr = tester.element(find.byType(MentionPickerSheet)).t.bbcodeEditor.userMention;
      expect(find.text(tr.title), findsOneWidget);
      expect(find.text(tr.noFriends), findsOneWidget);
      expect(find.text('Bob'), findsOneWidget);
      expect(adapter.friendRequests, isEmpty);

      await tester.tap(find.text('Bob'));
      await tester.pumpAndSettle();
      expect(picked, 'Bob');
    });
  });
}
