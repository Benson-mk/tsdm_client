import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/activities/view/activities_page.dart';
import 'package:tsdm_client/features/profile/bloc/my_titles_cubit.dart';
import 'package:tsdm_client/features/profile/view/my_titles_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/parsing.dart';

final class _EmptyTitles implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream, Future<void>? cancel) async =>
      ResponseBody.fromString(
        '<html><body></body></html>',
        200,
        headers: {
          Headers.contentTypeHeader: ['text/html; charset=utf-8'],
        },
      );

  @override
  void close({bool force = false}) {}
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  for (final titles in [false, true]) {
    testWidgets('${titles ? 'titles' : 'activities'} content stays within landscape safe area', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(960, 440);
      tester.view.padding = const FakeViewPadding(left: 44, right: 36, bottom: 24);
      addTearDown(tester.view.reset);
      if (titles) {
        final dio = Dio()..httpClientAdapter = _EmptyTitles();
        final client = NetClientProvider.buildNoCookie(dio: dio, cookie: CookieProvider.buildEmpty());
        // This is a layout test: use an in-memory response without cookie storage or platform transports.
        dio.interceptors.clear();
        getIt.registerSingleton<NetClientProvider>(
          client,
        );
        addTearDown(getIt.reset);
      }
      await tester.runAsync(() async {
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(
              home: titles
                  ? const MyTitlesPage()
                  : ActivitiesPage(
                      loadDocument: () async => parseHtmlDocument('<html></html>'),
                    ),
            ),
          ),
        );
        if (titles) {
          final cubit = tester.element(find.byType(Scaffold)).read<MyTitlesCubit>();
          if (cubit.state.status == MyTitlesStatus.loadingTitles) {
            await cubit.stream.firstWhere((state) => state.status != MyTitlesStatus.loadingTitles);
          }
        }
      });
      await tester.pumpAndSettle();
      final content = titles ? find.byType(SingleChildScrollView) : find.byType(ListView);
      final bounds = tester.getRect(content.first);
      expect(bounds.left, greaterThanOrEqualTo(44));
      expect(bounds.right, lessThanOrEqualTo(924));
      expect(bounds.bottom, lessThanOrEqualTo(416));
      expect(tester.takeException(), isNull);
    });
  }
}
