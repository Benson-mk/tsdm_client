/// Full UI redesign, phase 5: settings dialogs, confirmations, backup dialogs and the settings groups on a 320 wide
/// phone with 2x text; the choices and results of the dialogs are unchanged.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/need_login/view/need_login_page.dart';
import 'package:tsdm_client/features/settings/widgets/auto_clear_image_cache_duration_dialog.dart';
import 'package:tsdm_client/features/settings/widgets/auto_sync_notice_dialog.dart';
import 'package:tsdm_client/features/settings/widgets/backup_secrets_dialogs.dart';
import 'package:tsdm_client/features/settings/widgets/font_scale_dialog.dart';
import 'package:tsdm_client/features/settings/widgets/language_dialog.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/section_list_tile.dart';
import 'package:tsdm_client/widgets/section_switch_list_tile.dart';

/// Hosts [home] in a go_router app (the settings dialogs close with `context.pop`) at [size] and text [scale].
Future<void> _pump(WidgetTester tester, Widget home, {Size size = const Size(320, 640), double scale = 2}) async {
  await LocaleSettings.setLocale(AppLocale.en);
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = GoRouter(
    routes: [GoRoute(path: '/', builder: (_, _) => home)],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp.router(
        routerConfig: router,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// A page with one button opening a dialog through [open].
Widget _opener(Future<void> Function(BuildContext context) open) => Scaffold(
  body: Builder(
    builder: (context) => Center(
      child: ElevatedButton(onPressed: () => open(context), child: const Text('open')),
    ),
  ),
);

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  testWidgets('a destructive question fits 320 wide at 2x, keeps Cancel then Ok as text buttons and answers true', (
    tester,
  ) async {
    bool? answer;
    await _pump(
      tester,
      _opener(
        (context) async => answer = await showQuestionDialog(
          context: context,
          title: 'Remove this account from the device with a rather long title',
          message: 'Synthetic confirmation message that wraps on a narrow phone.',
          dangerous: true,
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.warning_amber_outlined), findsOneWidget, reason: 'destructive title tile');
    final buttons = tester.widgetList<TextButton>(find.byType(TextButton)).toList();
    expect(buttons, hasLength(2));
    await tester.tap(find.byType(TextButton).last);
    await tester.pumpAndSettle();
    expect(answer, isTrue);
  });

  testWidgets('a long question title keeps its whole text and both answers reachable with the keyboard up', (
    tester,
  ) async {
    const title = 'Remove this account from the device with a rather long title';
    bool? answer = true;
    await _pump(
      tester,
      _opener(
        (context) async => answer = await showQuestionDialog(
          context: context,
          title: title,
          message: 'Synthetic confirmation message that wraps on a narrow phone.',
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 200);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // The title is not cut: the same text is still there, it scrolls in its own area.
    expect(find.text(title), findsOneWidget);
    final buttons = find.byType(TextButton);
    expect(buttons, findsNWidgets(2));
    for (final button in buttons.evaluate()) {
      final rect = tester.getRect(find.byWidget(button.widget));
      expect(rect.bottom, lessThanOrEqualTo(640 - 200), reason: 'answers stay above the keyboard');
    }
    await tester.tap(buttons.first);
    await tester.pumpAndSettle();
    expect(answer, isFalse);
  });

  testWidgets('the export backup dialog keeps both password fields usable at 320 wide, 2x text and the keyboard up', (
    tester,
  ) async {
    Object? result = 'unset';
    await _pump(tester, _opener((context) async => result = await showExportBackupDialog(context)));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // The security text of the settings row is repeated in the dialog, nothing about the backup is dropped.
    expect(find.text(t.settingsPage.advancedSection.exportBackup.includeAccountsDetail), findsOneWidget);
    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(TextFormField), findsNWidgets(2));
    await tester.enterText(find.byType(TextFormField).at(0), 'correct horse');
    await tester.enterText(find.byType(TextFormField).at(1), 'correct horse');
    await tester.ensureVisible(find.byType(FilledButton).last);
    await tester.tap(find.byType(FilledButton).last);
    await tester.pumpAndSettle();
    expect((result! as ExportBackupChoice).password, 'correct horse');
  });

  testWidgets('the unlock dialog shows the wrong password error at 320 wide and 2x text', (tester) async {
    await _pump(tester, _opener((context) async => showUnlockBackupDialog(context, wrongPassword: true)));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text(t.settingsPage.advancedSection.importData.unlock.wrongPassword), findsOneWidget);
    expect(find.text(t.settingsPage.advancedSection.importData.unlock.tip), findsOneWidget);
  });

  testWidgets('an auto sync duration that is not one of the choices opens on the 10 minutes default', (tester) async {
    Object? result;
    await _pump(
      tester,
      _opener(
        (context) async =>
            result = await showDialog<int>(context: context, builder: (_) => const AutoSyncNoticeDialog(7)),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // The fallback used to be the value 600 used as an index, out of range.
    expect(tester.takeException(), isNull);
    await tester.tap(find.widgetWithText(FilledButton, t.general.ok));
    await tester.pumpAndSettle();
    expect(result, 600);
  });

  testWidgets('an image cache duration that is not one of the choices opens on the 7 days default', (tester) async {
    Object? result;
    await _pump(
      tester,
      _opener(
        (context) async => result = await showDialog<int>(
          context: context,
          builder: (_) => const AutoClearImageCacheDurationDialog(5),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.widgetWithText(FilledButton, t.general.ok));
    await tester.pumpAndSettle();
    expect(result, 3600 * 24 * 7);
  });

  testWidgets('the text scale dialog fits at 2x and returns the unchanged scale', (tester) async {
    Object? result;
    await _pump(
      tester,
      _opener(
        (context) async =>
            result = await showDialog<double>(context: context, builder: (_) => const TextScaleDialog(1.1)),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.widgetWithText(FilledButton, t.general.ok));
    await tester.pumpAndSettle();
    expect(result, 1.1);
  });

  testWidgets('the language dialog returns the tapped locale', (tester) async {
    Object? result;
    await _pump(
      tester,
      _opener(
        (context) async =>
            result = await showDialog<(AppLocale?, bool)>(context: context, builder: (_) => const LanguageDialog('en')),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('繁體中文'));
    await tester.tap(find.text('繁體中文'));
    await tester.pumpAndSettle();
    expect(result, (AppLocale.zhTw, false));
  });

  testWidgets('a settings group with rows and a footer notice lays out at 320 wide and 2x text', (tester) async {
    var value = false;
    await _pump(
      tester,
      Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => ListView(
            padding: const EdgeInsets.all(12),
            children: [
              AppTileGroup(
                title: 'Synthetic section with a long title',
                icon: Icons.tune_outlined,
                footer: const AppNoticeBanner(message: 'Synthetic limitation notice that wraps over several lines.'),
                children: [
                  const SectionListTile(
                    leading: Icon(Icons.info_outline),
                    title: Text('Row title'),
                    subtitle: Text('Row detail that is long enough to wrap'),
                  ),
                  SectionSwitchListTile(
                    title: const Text('Switch row'),
                    value: value,
                    onChanged: (v) => setState(() => value = v),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(value, isTrue);
  });

  testWidgets('the need login state shows one login action at 320 wide and 2x text', (tester) async {
    await _pump(tester, NeedLoginPage(backUri: Uri.parse('/'), showAppBar: true));
    expect(tester.takeException(), isNull);
    expect(find.text(t.general.needLoginToSeeThisPage), findsOneWidget);
    // FilledButton.icon builds a FilledButton subclass: match by predicate, not by exact type.
    final login = find.ancestor(
      of: find.text(t.loginPage.login),
      matching: find.byWidgetPredicate((w) => w is FilledButton),
    );
    expect(login, findsOneWidget);
  });
}
