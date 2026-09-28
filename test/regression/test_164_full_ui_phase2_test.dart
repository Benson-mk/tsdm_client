import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/chat/models/models.dart';
import 'package:tsdm_client/features/chat/widgets/chat_frame.dart';
import 'package:tsdm_client/features/chat/widgets/chat_message_card.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// Full UI redesign, phase 2 (messages, chat, notifications, search, filters, navigation): which chat bubbles belong
/// to the current account, and the new shared pieces (page switcher, info pills, empty state inside a refreshable
/// scroll view, chat header) fit a narrow phone with a large font.
///
/// Synthetic data, no network.
ChatMessage _message({String? author, String? uid}) =>
    ChatMessage(author: author, authorUid: uid, authorAvatarUrl: null, message: 'hi', dateTime: null);

/// A 320 wide phone with the text scaled to [scale].
Future<void> _pumpNarrow(WidgetTester tester, Widget child, {double scale = 2}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 560);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery.withClampedTextScaling(
        minScaleFactor: scale,
        maxScaleFactor: scale,
        child: Scaffold(body: child),
      ),
    ),
  );
}

void main() {
  group('own chat messages', () {
    test('chat history: the uid decides, a same name with another uid is not mine', () {
      expect(
        isOwnChatMessage(
          _message(author: 'Alice', uid: '1000'),
          currentUid: 1000,
          currentUsername: 'Alice',
        ),
        isTrue,
      );
      expect(
        isOwnChatMessage(
          _message(author: 'Alice', uid: '2000'),
          currentUid: 1000,
          currentUsername: 'Alice',
        ),
        isFalse,
      );
      expect(
        isOwnChatMessage(
          _message(author: 'Bob', uid: '2000'),
          currentUid: 1000,
          currentUsername: 'Alice',
        ),
        isFalse,
      );
    });

    test('chat dialog: without uid the name decides', () {
      expect(isOwnChatMessage(_message(author: 'Alice'), currentUid: 1000, currentUsername: 'Alice'), isTrue);
      expect(isOwnChatMessage(_message(author: 'Bob'), currentUid: 1000, currentUsername: 'Alice'), isFalse);
    });

    test('unknown account or author: never attributed to the current account', () {
      expect(
        isOwnChatMessage(_message(author: 'Alice', uid: '1000'), currentUid: null, currentUsername: null),
        isFalse,
      );
      expect(isOwnChatMessage(_message(), currentUid: 1000, currentUsername: 'Alice'), isFalse);
    });
  });

  group('shared pieces on a narrow phone with a large font', () {
    testWidgets('page switcher: fits, shows current / total, disabled without callback', (tester) async {
      var next = 0;
      await _pumpNarrow(
        tester,
        Center(child: AppPager(current: 3, total: 12, onNext: () => next++)),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('3 / 12'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.chevron_right));
      expect(next, 1);
      final previous = tester.widget<IconButton>(
        find.ancestor(of: find.byIcon(Icons.chevron_left), matching: find.byType(IconButton)),
      );
      expect(previous.onPressed, isNull);
    });

    testWidgets('page switcher: unknown pages show dashes', (tester) async {
      await _pumpNarrow(tester, const Center(child: AppPager(current: null, total: null)), scale: 1);
      expect(find.text('- / -'), findsOneWidget);
    });

    testWidgets('info pills wrap and ellipsize long values', (tester) async {
      await _pumpNarrow(
        tester,
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              AppInfoPill(icon: Icons.person_outline, label: 'a very long user name ' * 6),
              AppInfoPill(icon: Icons.forum_outlined, label: 'a very long forum name ' * 6),
              const AppInfoPill(icon: Icons.access_time_outlined, label: '2026-09-27 12:00:00'),
            ],
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(AppInfoPill), findsNWidgets(3));
    });

    testWidgets('empty state inside a refreshable list keeps a scroll view and does not overflow', (tester) async {
      await _pumpNarrow(
        tester,
        AppScrollableStateView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: AppStateView(message: 'nothing here ' * 30, scrollable: false),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('chat header: long name and status pill fit one line', (tester) async {
      await _pumpNarrow(
        tester,
        ChatPeerHeader(text: 'Chat with ${'someone with a long name ' * 4}', status: 'Online', online: true),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Online'), findsOneWidget);
    });
  });
}
