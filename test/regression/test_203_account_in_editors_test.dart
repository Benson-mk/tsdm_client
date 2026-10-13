import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/multi_user/cubit/current_account_cubit.dart';
import 'package:tsdm_client/features/multi_user/widgets/current_account_avatar.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/widgets/reply_bar/bloc/reply_bloc.dart';
import 'package:tsdm_client/widgets/reply_bar/models/reply_types.dart';
import 'package:tsdm_client/widgets/reply_bar/reply_bar.dart';
import 'package:tsdm_client/widgets/reply_bar/repository/reply_repository.dart';

/// GitHub #184: with several saved accounts the reply bar, its editor and the post editors name the account a post
/// goes out as, and follow account switches.

const _alice = UserLoginInfo(username: 'Alice', uid: 1000);
const _bob = UserLoginInfo(username: 'Bob', uid: 1001);
const _longName = UserLoginInfo(username: 'AVeryLongUsernameThatDoesNotFitOnAPhone', uid: 1002);

const _parameters = ReplyParameters(fid: '2', tid: '3', postTime: null, formHash: 'XXXXXXXX', subject: 'subject');

/// Avatars are not downloaded in tests.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// The account cubit of the app, fed by test streams.
final class _Accounts {
  _Accounts(this.current, int count) {
    cubit = CurrentAccountCubit(
      currentUser: () => current,
      authStatus: authStatus.stream,
      accounts: accounts.stream,
    );
    setCount(count);
  }

  UserLoginInfo current;
  final authStatus = StreamController<AuthStatus>();
  final accounts = StreamController<List<UserLoginInfo>>();
  late final CurrentAccountCubit cubit;

  void setCount(int count) => accounts.add([_alice, _bob, _longName].take(count).toList());

  /// Switch to [user] the way the app does: the repository changes its user, then reports the auth status.
  void switchTo(UserLoginInfo user) {
    current = user;
    authStatus.add(AuthStatusAuthed(user));
  }

  Future<void> dispose() async {
    await cubit.close();
    await authStatus.close();
    await accounts.close();
  }
}

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
      );
    await settings.init();
  });
  tearDown(() async {
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  /// A phone sized window.
  void usePhone(WidgetTester tester) {
    tester.view
      ..physicalSize = const Size(360, 720)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// A thread page with a reply bar, logged in as [user] with [count] saved accounts.
  Future<(ReplyBarController, _Accounts)> pumpReplyBar(WidgetTester tester, UserLoginInfo user, int count) async {
    final controller = ReplyBarController();
    final auth = AuthenticationRepository(user: user);
    final accounts = _Accounts(user, count);
    final bloc = ReplyBloc(replyRepository: const ReplyRepository())
      ..add(const ReplyParametersUpdated(_parameters))
      // Open for replies, as a loaded thread tells its bar.
      ..add(const ReplyThreadClosed(closed: false));
    addTearDown(() async {
      await bloc.close();
      await accounts.dispose();
      await auth.dispose();
    });
    await tester.pumpWidget(
      RepositoryProvider<AuthenticationRepository>.value(
        value: auth,
        child: BlocProvider<CurrentAccountCubit>.value(
          value: accounts.cubit,
          child: BlocProvider<ReplyBloc>.value(
            value: bloc,
            child: TranslationProvider(
              child: MaterialApp(
                home: Scaffold(
                  resizeToAvoidBottomInset: false,
                  body: const Center(child: Text('thread page')),
                  bottomNavigationBar: ReplyBar(controller: controller, replyType: ReplyTypes.thread),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('thread page'), findsOneWidget);
    return (controller, accounts);
  }

  Future<void> openEditor(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('reply-bar-field')));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.unfold_less), findsOneWidget, reason: 'the expanded editor is showing');
  }

  String replyAs(String name) => t.currentAccount.replyAs(username: name);

  group('reply bar', () {
    testWidgets('with two accounts the empty box names the account', (tester) async {
      await pumpReplyBar(tester, _alice, 2);
      expect(find.text(replyAs('Alice')), findsOneWidget);
      expect(find.text(t.threadPage.sendReplyHint), findsNothing);
    });

    testWidgets('with one account the box keeps the old hint and the editor shows no account', (tester) async {
      await pumpReplyBar(tester, _alice, 1);
      expect(find.text(t.threadPage.sendReplyHint), findsOneWidget);
      expect(find.text(replyAs('Alice')), findsNothing);

      await openEditor(tester);
      expect(find.byKey(const ValueKey('reply-bar-account')), findsNothing);
    });

    testWidgets('an account switch renames the box and the open editor', (tester) async {
      final (_, accounts) = await pumpReplyBar(tester, _alice, 2);
      expect(find.text(replyAs('Alice')), findsOneWidget);

      accounts.switchTo(_bob);
      await tester.pumpAndSettle();
      expect(find.text(replyAs('Bob')), findsOneWidget);
      expect(find.text(replyAs('Alice')), findsNothing);

      await openEditor(tester);
      final label = find.byKey(const ValueKey('reply-bar-account'));
      expect(label, findsOneWidget);
      expect(find.descendant(of: label, matching: find.text('Bob')), findsOneWidget);
      expect(tester.widget<Tooltip>(label).message, replyAs('Bob'));

      accounts.switchTo(_alice);
      await tester.pumpAndSettle();
      expect(find.descendant(of: label, matching: find.text('Alice')), findsOneWidget);
      expect(find.descendant(of: label, matching: find.text('Bob')), findsNothing);
    });

    testWidgets('a second saved account brings the name in, removing it takes it away', (tester) async {
      final (_, accounts) = await pumpReplyBar(tester, _alice, 1);
      expect(find.text(t.threadPage.sendReplyHint), findsOneWidget);

      accounts.setCount(2);
      await tester.pumpAndSettle();
      expect(find.text(replyAs('Alice')), findsOneWidget);

      accounts.setCount(1);
      await tester.pumpAndSettle();
      expect(find.text(t.threadPage.sendReplyHint), findsOneWidget);
    });

    testWidgets('a long name fits the editor buttons on a phone', (tester) async {
      usePhone(tester);
      await pumpReplyBar(tester, _longName, 3);
      await openEditor(tester);

      final label = find.byKey(const ValueKey('reply-bar-account'));
      expect(label, findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'no overflow in the button row');
      expect(tester.getSize(label).width, greaterThan(60), reason: 'the name keeps the free room of the row');
      // The send button stays on screen.
      final send = tester.getRect(find.byIcon(Icons.send));
      expect(send.right, lessThanOrEqualTo(360));
    });
  });

  group('post editor app bar', () {
    /// An app bar like the thread editor's: a title, three actions and the account line.
    Future<_Accounts> pumpAppBar(WidgetTester tester, UserLoginInfo user, int count) async {
      final accounts = _Accounts(user, count);
      addTearDown(accounts.dispose);
      await tester.pumpWidget(
        BlocProvider<CurrentAccountCubit>.value(
          value: accounts.cubit,
          child: TranslationProvider(
            child: MaterialApp(
              home: Builder(
                builder: (context) => Scaffold(
                  appBar: AppBar(
                    leading: const BackButton(),
                    title: const Text('Post new thread'),
                    bottom: postingAsBarOf(context),
                    actions: [
                      IconButton(onPressed: () {}, icon: const Icon(Icons.poll_outlined)),
                      IconButton(onPressed: () {}, icon: const Icon(Icons.save_outlined)),
                      IconButton(onPressed: () {}, icon: const Icon(Icons.send)),
                    ],
                  ),
                  body: const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return accounts;
    }

    String postingAs(String name) => t.currentAccount.postingAs(username: name);

    testWidgets('with two accounts the line names the account, the title keeps its room', (tester) async {
      usePhone(tester);
      await pumpAppBar(tester, _alice, 2);
      expect(find.byKey(const ValueKey('posting-as-bar')), findsOneWidget);
      expect(find.text(postingAs('Alice')), findsOneWidget);
      expect(tester.getSize(find.text('Post new thread')).width, greaterThan(100));
      expect(tester.takeException(), isNull);
    });

    testWidgets('with one account there is no line', (tester) async {
      await pumpAppBar(tester, _alice, 1);
      expect(find.byKey(const ValueKey('posting-as-bar')), findsNothing);
      expect(find.text(postingAs('Alice')), findsNothing);
    });

    testWidgets('an account switch renames the line', (tester) async {
      final accounts = await pumpAppBar(tester, _alice, 2);
      accounts.switchTo(_bob);
      await tester.pumpAndSettle();
      expect(find.text(postingAs('Bob')), findsOneWidget);
      expect(find.text(postingAs('Alice')), findsNothing);
    });

    testWidgets('a long name is cut on a phone', (tester) async {
      usePhone(tester);
      await pumpAppBar(tester, _longName, 3);
      expect(find.byKey(const ValueKey('posting-as-bar')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
