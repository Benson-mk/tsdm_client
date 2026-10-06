/// The forum's app API, stage 3: private messages, favorites, search, medal center, titles, achievements, title
/// shop, homepage and profile in JSON mode (`tsdmapp=json`, plugin 1.3.0).
///
/// The app parses the page rebuilt from the JSON blocks with its existing parsers; everything must come out exactly
/// as from the web page. Pairs from the test forum (account ag_low, 2026-10-06; site name and host replaced). The
/// production pages, which the test forum's template does not match everywhere, were compared outside the repository
/// the same way (see the spec).
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_mappable/dart_mappable.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/achievements/models/achievement_page_data.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/homepage/bloc/homepage_bloc.dart';
import 'package:tsdm_client/features/medal_center/models/medal_catalog.dart';
import 'package:tsdm_client/features/profile/models/secondary_title.dart';
import 'package:tsdm_client/features/profile/utils/parse_profile.dart';
import 'package:tsdm_client/features/red_packet/repository/daily_rewards_repository.dart';
import 'package:tsdm_client/features/red_packet/utils/parse_red_packet.dart';
import 'package:tsdm_client/features/search/models/models.dart';
import 'package:tsdm_client/features/title_shop/models/title_shop.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

const _dir = 'test/data/tsdmapp/s3_';
uh.Document web(String n) => parseHtmlDocument(File('$_dir$n.html').readAsStringSync());
uh.Document api(String n) => tsdmAppPageDocument(File('$_dir$n.json').readAsStringSync());
String apiHtml(String n) => tsdmAppPageHtml(File('$_dir$n.json').readAsStringSync());

final class _ColorMapper extends SimpleMapper<Color> {
  const _ColorMapper();
  @override
  Color decode(Object value) => Color(value as int);
  @override
  Object? encode(Color self) => self.toARGB32();
}

/// Anything to a comparable value: mappable models through their map, the rest through toString.
Object? v(Object? o) {
  try {
    final s = jsonEncode(
      o,
      toEncodable: (x) {
        try {
          return (x as dynamic).toMap();
        } on Object {
          return x.toString();
        }
      },
    );
    return jsonDecode(s);
  } on Object {
    return o.toString();
  }
}

String medal(MedalCatalog c) => [
  c.categories.map((e) => '${e.name}|${e.url}').join(';'),
  c.medals
      .map(
        (m) => [
          m.id,
          m.name,
          m.imageUrl,
          m.method,
          m.description,
          m.details.join('/'),
          m.accountStatus,
          m.actions.map((a) => '${a.type}|${a.url}|${a.formData}|${a.confirmText}|${a.disabledReason}').join(','),
        ].join('#'),
      )
      .join('\n'),
  c.page,
  c.previousUrl,
  c.nextUrl,
  c.supported,
  c.message,
  c.searchForm?.url,
  c.searchForm?.formHash,
].join('\n');

String shop(TitleShopCatalog c) => [
  c.heading,
  c.intro.join('/'),
  c.page,
  c.previousUrl,
  c.nextUrl,
  c.balance,
  c.supported,
  c.message,
  c.items
      .map(
        (i) => [
          i.id,
          i.name,
          i.price,
          i.imageUrl,
          i.status,
          i.statusText,
          i.form?.formHash,
          i.form?.returnPath,
          i.form?.buyId,
          i.form?.confirmText,
        ].join('#'),
      )
      .join('\n'),
].join('\n');

String achi(AchievementPageData d) => [d.recognized, d.empty, d.content, d.message].join('\n');

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    MapperContainer.globals.use(const _ColorMapper());
  });

  void same(String what, Object? a, Object? b) {
    final ea = jsonEncode(v(a));
    final eb = jsonEncode(v(b));
    expect(ea, eb, reason: what);
  }

  test('search', () {
    same('search', SearchResult.fromDocument(api('search')), SearchResult.fromDocument(web('search')));
    same('searchid', SearchResult.parseSearchId(api('search')), SearchResult.parseSearchId(web('search')));
  });
  test(
    'medal center',
    () => same(
      'medal',
      medal(parseMedalCatalog(parseHtmlDocument(apiHtml('medal')))),
      medal(parseMedalCatalog(web('medal'))),
    ),
  );
  test('titles', () {
    same('titles', SecondaryTitle.parseTitlesPage(api('title')), SecondaryTitle.parseTitlesPage(web('title')));
    same(
      'formhash',
      api('title').querySelector('input[name="formhash"]')?.attributes['value'],
      web('title').querySelector('input[name="formhash"]')?.attributes['value'],
    );
  });
  test(
    'title shop',
    () => same('shop', shop(parseTitleShop(parseHtmlDocument(apiHtml('shop')))), shop(parseTitleShop(web('shop')))),
  );
  test(
    'achievements',
    () => same(
      'achi',
      achi(parseAchievementPage(parseHtmlDocument(apiHtml('achi')))),
      achi(parseAchievementPage(web('achi'))),
    ),
  );
  test('homepage', () {
    same(
      'home state',
      HomepageBloc.parseStateForTest(api('index'), 'ag_low'),
      HomepageBloc.parseStateForTest(web('index'), 'ag_low'),
    );
    same(
      'pinned',
      HomepageBloc.parsePinnedThreadGroups(api('index')),
      HomepageBloc.parsePinnedThreadGroups(web('index')),
    );
    same('logged', parseLoggedUserFromDocument(api('index')), parseLoggedUserFromDocument(web('index')));
    same('visit', dailyVisitUri(api('index')), dailyVisitUri(web('index')));
    same('packet', parseDailyRedPacketConfig(api('index')), parseDailyRedPacketConfig(web('index')));
    same('formhash', parseFormHash(api('index')), parseFormHash(web('index')));
  });
  test('profile', () async {
    final a = await buildProfile(api('profile')).run();
    final w = await buildProfile(web('profile')).run();
    same('profile', a.toNullable(), w.toNullable());
    same('avatar', parseProfileAvatarUrl(api('profile')), parseProfileAvatarUrl(web('profile')));
    same('2nd title', parseProfileSecondaryTitleUrl(api('profile')), parseProfileSecondaryTitleUrl(web('profile')));
  });
}
