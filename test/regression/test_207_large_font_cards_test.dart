/// With a large system font the cards in a post (spoilers, quotes, code blocks, hidden content, red packets, reviews,
/// bounties, music, tables...) were scaled twice, and tables in a post never wrapped.
///
/// A paragraph lays a widget inside its text (a `WidgetSpan`) out at its width divided by the text scale and paints it
/// scaled up by the text scale (flutter/flutter#126962). The text in the card read the same text scale again: at 1.3
/// it was 1.69 times as large, the cards were crowded and broke lines badly. PR #189 only fixed the newcomer report
/// card.
///
/// A table in a post sat in a horizontal scroll view with every column as wide as its longest cell: a long cell never
/// wrapped and ran off the screen, the reader had to scroll sideways line by line.
library;

// HTML fixtures are split into lines at tag boundaries.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/poll/cubit/poll_cubit.dart';
import 'package:tsdm_client/features/poll/repository/poll_repository.dart';
import 'package:tsdm_client/features/red_packet/widgets/red_packet_card.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:tsdm_client/utils/html/netease_card.dart';
import 'package:tsdm_client/utils/html/newcomer_report_card.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image_provider.dart';
import 'package:tsdm_client/widgets/card/bounty_answer_card.dart';
import 'package:tsdm_client/widgets/card/bounty_card.dart';
import 'package:tsdm_client/widgets/card/code_card.dart';
import 'package:tsdm_client/widgets/card/lock_card/locked_card.dart';
import 'package:tsdm_client/widgets/card/poll_card.dart';
import 'package:tsdm_client/widgets/card/review_card.dart';
import 'package:tsdm_client/widgets/card/spoiler_card.dart';
import 'package:tsdm_client/widgets/network_indicator_image.dart';
import 'package:tsdm_client/widgets/quoted_text.dart';
import 'package:universal_html/parsing.dart';

const _avatarUrl = 'https://example.com/uc_server/avatar.png';

/// Every card the post renderer builds, with fake content.
final _cards = <_Card>[
  _Card(
    'spoiler',
    '<div class="spoiler"><div class="spoilerheader"><input type="button" class="spoilerbutton" value="展开看看" /> '
        '（點擊展開 / 收起）</div><div class="spoilerbody" style="display: none;"><table><td>折叠里的内容，展开后才看得到'
        '</td></table></div></div>',
    () => find.byType(SpoilerCard),
    open: _expandSpoiler,
  ),
  _Card(
    'details',
    '<details><summary>摘要标题</summary><div>详情里的内容</div></details>',
    () => find.byType(SpoilerCard),
    open: _expandSpoiler,
  ),
  _Card('quote', '<blockquote>引用别人说过的一段话</blockquote>', () => find.byType(QuotedText)),
  _Card(
    'code block',
    '<div class="blockcode"><div id="code_1"><ol><li>print("hello");</li><li>return 0;</li></ol></div></div>',
    () => find.byType(CodeCard),
  ),
  _Card('inline code', '行内 <code>inline_code()</code> 代码', () => find.byType(Card)),
  _Card(
    'hidden content',
    '<div class="locked">如果您要查看本帖隐藏内容请<a href="forum.php?mod=post&amp;action=reply&amp;fid=1&amp;tid=1">'
        '回复</a></div>',
    () => find.byType(LockedCard),
  ),
  _Card(
    'review',
    '<div class="cm"><div class="pstl"><div class="psta"><a><img src="$_avatarUrl"></a></div>'
        '<div class="psti"><a class="xi2">reviewer</a>&nbsp;&nbsp;点评的内容 <span class="xg1">发表于 2020-1-1</span></div>'
        '</div></div>',
    () => find.byType(ReviewCard),
  ),
  _Card(
    'red packet',
    '<div class="hb-entry" data-tid="1" onclick="hongbaoOpen(this)"><div class="icon"></div><div> '
        '<div class="t1">恭喜发财，大吉大利</div><div class="t2">拼手气红包 · 剩 10/10 份 · 点击领取</div></div></div>',
    () => find.byType(RedPacketCard),
  ),
  _Card('bounty', '<div class="rusld z"><cite>20</cite></div>', () => find.byType(BountyCard)),
  _Card('resolved bounty', '<div class="rsld z"><cite>20</cite></div>', () => find.byType(BountyCard)),
  _Card(
    'bounty best answer',
    '<div class="rwdbst"><h3 class="psth">最佳答案</h3><div class="pstl"><div class="psta"><img src="$_avatarUrl"></div>'
        '<div class="psti"><p class="xi2"><a href="home.php?mod=space&amp;uid=1" class="xw1">answerer</a>'
        '<a href="javascript:;">查看完整内容</a></p><div class="mtn">这是最佳答案的内容</div></div></div></div>',
    () => find.byType(BountyAnswerCard),
  ),
  _Card(
    'moderation notice',
    '<div>正文末尾<div class="modact">本主题由 管理团队 于 3 小时前 添加图章 置顶</div>后续内容</div>',
    () => find.ancestor(of: find.byIcon(Icons.manage_history_outlined), matching: find.byType(Container)).first,
  ),
  _Card(
    'centered text',
    '<div align="center">居中的一行文字</div>',
    () => find.byWidgetPredicate((w) => w is Text && w.textAlign == TextAlign.center),
  ),
  _Card(
    'table',
    '<table><tr><th>名称</th><td>值</td></tr><tr><th>说明</th><td>表格里比较长的一段说明文字，在窄的屏幕上要换行</td></tr></table>',
    () => find.byType(Table),
  ),
  _Card(
    'music',
    '<iframe src="https://music.163.com/outchain/player?type=2&amp;id=12345&amp;auto=0&amp;height=66"></iframe>',
    () => find.byType(NeteaseCard),
  ),
  _Card(
    'newcomer report',
    '<div class="rcd-card"><div class="rcd-h">报到详细信息</div><table>'
        '<tr><th>昵称</th><td class="rcd-v">Alice</td></tr><tr><th>兴趣爱好</th><td class="rcd-v">看书</td></tr>'
        '</table></div>',
    () => find.byType(NewcomerReportCard),
  ),
];

final class _Card {
  _Card(this.name, this.html, this.finder, {this.open});

  final String name;
  final String html;
  final Finder Function() finder;

  /// Brings the content of the card on screen, e.g. expands a spoiler.
  final Future<void> Function(WidgetTester tester)? open;
}

Future<void> _expandSpoiler(WidgetTester tester) async {
  await tester.tap(find.byType(OutlinedButton));
  await tester.pumpAndSettle();
}

/// Answers the music page with a song.
final class _MusicPageAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    '<html><body><em class="f-ff2">Song</em><p class="des s-fc4"><span title="Singer">Singer</span></p></body></html>',
    200,
    headers: {
      Headers.contentTypeHeader: ['text/html; charset=utf-8'],
    },
  );

  @override
  void close({bool force = false}) {}
}

/// How large the glyphs of [paragraph] end up on the screen relative to its font size: the scale of everything it is
/// painted through times its own text scale.
double _effectiveScale(RenderParagraph paragraph) {
  final left = paragraph.localToGlobal(Offset.zero);
  final right = paragraph.localToGlobal(Offset(paragraph.size.width, 0));
  return (right - left).distance / paragraph.size.width * paragraph.textScaler.scale(14) / 14;
}

/// Every piece of text on the screen with something in it. Icons are not text, they never follow the text scale.
List<RenderParagraph> _paragraphs(WidgetTester tester) {
  final icons = tester
      .renderObjectList<RenderParagraph>(find.descendant(of: find.byType(Icon), matching: find.byType(RichText)))
      .toSet();
  return tester
      .renderObjectList<RenderParagraph>(find.byType(RichText))
      .where((e) => !icons.contains(e) && e.size.width > 0.5 && e.text.toPlainText().trim().isNotEmpty)
      .toList();
}

Rect _globalRect(RenderBox box) =>
    Rect.fromPoints(box.localToGlobal(Offset.zero), box.localToGlobal(box.size.bottomRight(Offset.zero)));

/// Puts an image of [width] x [height] for [provider] in the image cache, the test does not load it from the network.
Future<void> _seed(WidgetTester tester, ImageProvider provider, {int width = 40, int height = 40}) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = Colors.blue);
  final picture = recorder.endRecording();
  final image = await tester.runAsync(() => picture.toImage(width, height));
  picture.dispose();
  final key = await provider.obtainKey(ImageConfiguration.empty);
  PaintingBinding.instance.imageCache.putIfAbsent(
    key,
    () => OneFrameImageStreamCompleter(Future.value(ImageInfo(image: image!))),
  );
}

/// An image in the post on a screen of [screenWidth]: decoded at the width of the screen.
Future<void> _seedPostImage(WidgetTester tester, String url, double screenWidth, {int width = 40, int height = 40}) =>
    _seed(
      tester,
      ResizeImage.resizeIfNeeded(screenWidth.toInt(), null, CachedImageProvider(url)),
      width: width,
      height: height,
    );

Future<void> _seedAvatars(WidgetTester tester) async {
  for (final name in ['reviewer', 'answerer']) {
    await _seed(
      tester,
      CachedImageProvider(_avatarUrl, fallbackImageUrl: noAvatarUrl, usage: ImageUsageInfoUserAvatar(name)),
    );
  }
}

/// The horizontal scroll positions of the tables on the screen.
List<ScrollPosition> _horizontalScrolls(WidgetTester tester) => tester
    .stateList<ScrollableState>(find.ancestor(of: find.byType(Table), matching: find.byType(Scrollable)))
    .map((e) => e.position)
    .where((e) => e.axis == Axis.horizontal)
    .toList();

/// Whether the text of [paragraph] is laid out on one line: as wide as it is unwrapped.
bool _oneLine(RenderParagraph paragraph) =>
    paragraph.getMaxIntrinsicWidth(double.infinity) <= paragraph.size.width + 0.01;

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  late ImageCacheProvider cache;
  setUp(() {
    cache = ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio(), cookie: CookieProvider.buildEmpty()));
    getIt
      ..registerSingleton<ImageCacheProvider>(cache)
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.buildNoCookie(
          dio: Dio()..httpClientAdapter = _MusicPageAdapter(),
          cookie: CookieProvider.buildEmpty(),
        ),
        instanceName: ServiceKeys.noCookie,
      );
  });
  tearDown(() async {
    await cache.dispose();
    await getIt.reset();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  Future<void> pumpWidget(WidgetTester tester, Widget child, {required double width, required double textScale}) async {
    tester.view.physicalSize = Size(width, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(padding: const EdgeInsets.symmetric(horizontal: 16), child: child),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pump(WidgetTester tester, String html, {double width = 360, double textScale = 1}) async {
    final body = parseHtmlDocument('<html><body>$html</body></html>').body!;
    await pumpWidget(
      tester,
      Builder(builder: (context) => munchElement(context, body)),
      width: width,
      textScale: textScale,
    );
  }

  for (final card in _cards) {
    group(card.name, () {
      testWidgets('is scaled once at text scale 1.3, like the text of the post', (tester) async {
        await _seedAvatars(tester);
        await pump(tester, card.html, textScale: 1.3);
        await card.open?.call(tester);
        expect(card.finder(), findsWidgets);
        final paragraphs = _paragraphs(tester);
        expect(paragraphs.length, greaterThan(1));
        for (final paragraph in paragraphs) {
          expect(_effectiveScale(paragraph), closeTo(1.3, 0.01), reason: paragraph.text.toPlainText());
        }
        expect(tester.takeException(), isNull);
      });

      for (final scale in const [1.3, 2.0]) {
        testWidgets('fits a 320 px screen at text scale $scale', (tester) async {
          await _seedAvatars(tester);
          await pump(tester, card.html, width: 320, textScale: scale);
          await card.open?.call(tester);
          expect(tester.takeException(), isNull, reason: 'nothing overflows');
          final rect = tester.getRect(card.finder().first);
          // The post is laid out in 320 - 2 * 16; inline widgets may sit a fraction of a pixel off its edges.
          expect(rect.left, greaterThan(15));
          expect(rect.right, lessThan(320 - 15));
          for (final paragraph in _paragraphs(tester)) {
            final text = _globalRect(paragraph);
            expect(text.left, greaterThan(15), reason: paragraph.text.toPlainText());
            expect(text.right, lessThan(320 - 15), reason: paragraph.text.toPlainText());
          }
        });
      }
    });
  }

  group('buttons in a scaled card still work', () {
    testWidgets('the spoiler opens and closes', (tester) async {
      await pump(tester, _cards.first.html, textScale: 1.3);
      expect(find.textContaining('折叠里的内容', findRichText: true), findsNothing);
      await tester.tap(find.byType(OutlinedButton));
      await tester.pumpAndSettle();
      expect(find.textContaining('折叠里的内容', findRichText: true), findsOneWidget);
      await tester.tap(find.byType(OutlinedButton));
      await tester.pumpAndSettle();
      expect(find.textContaining('折叠里的内容', findRichText: true), findsNothing);
    });

    testWidgets('the code block copies its code', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await pump(tester, _cards.firstWhere((e) => e.name == 'code block').html, textScale: 2);
      await tester.tap(find.byIcon(Icons.copy_outlined));
      await tester.pumpAndSettle();
      expect(copied, 'print("hello");\nreturn 0;');
    });
  });

  testWidgets('the hidden content card under a floor is scaled once too', (tester) async {
    // A floor shows the hidden content of the forum's own markup (not in the post text) with the same card; the word to
    // reply is a widget inside its text.
    final locked = Locked.fromLockDivNode(
      parseHtmlDocument(_cards.firstWhere((e) => e.name == 'hidden content').html).querySelector('div.locked')!,
    );
    await pumpWidget(tester, LockedCard(locked), width: 360, textScale: 1.3);
    final paragraphs = _paragraphs(tester);
    expect(paragraphs.map((e) => e.text.toPlainText()), contains('Reply'));
    for (final paragraph in paragraphs) {
      expect(_effectiveScale(paragraph), closeTo(1.3, 0.01), reason: paragraph.text.toPlainText());
    }
  });

  testWidgets('the poll card under the first floor is scaled once', (tester) async {
    // Not inside the post text: it is laid out in the floor like the text of the post and needs nothing.
    await LocaleSettings.setLocale(AppLocale.en);
    final html = File('test/data/poll_multiple_x5.html').readAsStringSync();
    final repo = PollRepository(getPage: (_) async => html, postForm: (_, _) async => '');
    final cubit = PollCubit(url: 'poll', currentUid: () => 1000, repository: () => repo);
    addTearDown(cubit.close);
    await pumpWidget(tester, PollCard('1', controller: cubit), width: 360, textScale: 1.3);
    final paragraphs = _paragraphs(tester);
    expect(paragraphs.length, greaterThan(3));
    for (final paragraph in paragraphs) {
      expect(_effectiveScale(paragraph), closeTo(1.3, 0.01), reason: paragraph.text.toPlainText());
    }
    await tester.pumpWidget(const SizedBox());
  });

  group('tables', () {
    const longText =
        '这是表格里一段很长的说明文字，在手机的屏幕上一行放不下，以前整个表格只能左右滑动，现在要在屏幕里面自动换行，'
        '读的人不用再一行一行地左右滑动来看完。';
    const longTable =
        '<table><tr><th>名称</th><td>说明</td></tr>'
        '<tr><td>第一项</td><td>$longText</td></tr>'
        '<tr><td>第二项</td><td>短的说明</td></tr></table>';

    for (final scale in const [1.0, 1.3]) {
      testWidgets('a long cell of a two column table wraps inside a 360 px screen at text scale $scale', (
        tester,
      ) async {
        await pump(tester, longTable, textScale: scale);
        expect(tester.takeException(), isNull);
        final scrolls = _horizontalScrolls(tester);
        expect(scrolls, everyElement(predicate<ScrollPosition>((e) => e.maxScrollExtent == 0)), reason: 'no scrolling');
        final table = tester.getRect(find.byType(Table));
        expect(table.right, lessThan(360 - 15));

        final long = tester.renderObject<RenderParagraph>(
          find.descendant(of: find.textContaining('很长的说明文字'), matching: find.byType(RichText)),
        );
        final lineHeight = long.getFullHeightForCaret(const TextPosition(offset: 0));
        expect(long.size.height, greaterThan(lineHeight * 2), reason: 'wrapped onto several lines');
        expect(_globalRect(long).right, lessThanOrEqualTo(table.right + 0.01));
        // The short cells keep their line, the long column takes the room.
        for (final text in ['名称', '第一项', '第二项', '短的说明']) {
          final paragraph = tester.renderObject<RenderParagraph>(
            find.descendant(of: find.text(text), matching: find.byType(RichText)),
          );
          expect(_oneLine(paragraph), isTrue, reason: text);
        }
        expect(_globalRect(long).width, greaterThan(table.width / 2));
      });
    }

    testWidgets('a table that fits keeps its own width', (tester) async {
      await pump(tester, '<table><tr><td>甲</td><td>乙</td></tr><tr><td>丙</td><td>丁</td></tr></table>');
      expect(tester.getRect(find.byType(Table)).width, lessThan(100), reason: 'not stretched to the screen');
      expect(_horizontalScrolls(tester), everyElement(predicate<ScrollPosition>((e) => e.maxScrollExtent == 0)));
    });

    testWidgets('a table with ten columns still scrolls sideways', (tester) async {
      final row = [for (var i = 1; i <= 10; i++) '<td>第$i列的内容</td>'].join();
      await pump(tester, '<table><tr>$row</tr><tr>$row</tr></table>', textScale: 1.3);
      expect(tester.takeException(), isNull);
      final scroll = _horizontalScrolls(tester).single;
      expect(scroll.maxScrollExtent, greaterThan(0));
      // Every cell keeps its text on one line instead of being squeezed.
      for (final paragraph in tester.renderObjectList<RenderParagraph>(
        find.descendant(of: find.byType(Table), matching: find.byType(RichText)),
      )) {
        expect(_oneLine(paragraph), isTrue, reason: paragraph.text.toPlainText());
      }
      // And it can be dragged through the scaled card.
      await tester.dragFrom(tester.getTopLeft(find.byType(Table)) + const Offset(40, 10), const Offset(-200, 0));
      await tester.pumpAndSettle();
      expect(scroll.pixels, greaterThan(0));
    });

    testWidgets('a table that has to scroll still wraps a long cell about at the width of the screen', (tester) async {
      // A word that cannot break is wider than a 320 px screen at text scale 2 leaves for the table.
      await pump(
        tester,
        '<table><tr><th>名称</th><td>$longText</td><td>unbreakable</td></tr>'
        '<tr><td>甲</td><td>乙</td><td>丙</td></tr></table>',
        width: 320,
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
      expect(_horizontalScrolls(tester).single.maxScrollExtent, greaterThan(0));
      final long = find.descendant(of: find.textContaining('很长的说明文字'), matching: find.byType(RichText));
      expect(_globalRect(tester.renderObject<RenderParagraph>(long)).width, lessThanOrEqualTo(320 - 2 * 16));
      for (final text in ['名称', 'unbreakable']) {
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: find.text(text), matching: find.byType(RichText)),
        );
        expect(_oneLine(paragraph), isTrue, reason: text);
      }
    });

    testWidgets('a table of images and text still shows the images', (tester) async {
      const small = 'https://example.com/data/attachment/forum/small.png';
      await _seedPostImage(tester, small, 360, width: 48, height: 32);
      await pump(
        tester,
        '<table><tr><td><img src="$small"></td><td>$longText</td></tr><tr><td>图片</td><td>文字</td></tr></table>',
        textScale: 1.3,
      );
      expect(tester.takeException(), isNull);
      final image = tester.getRect(find.byType(NetworkIndicatorImage));
      // The image keeps its size, scaled with the text of the post.
      expect(image.width, closeTo(48 * 1.3, 0.5));
      expect(image.height, closeTo(32 * 1.3, 0.5));
      expect(tester.getRect(find.byType(Table)).right, lessThan(360 - 15));
      expect(_horizontalScrolls(tester).single.maxScrollExtent, 0);
    });

    testWidgets('a wide image beside a long text is narrowed to a thumbnail, the text wraps', (tester) async {
      const wide = 'https://example.com/data/attachment/forum/wide.png';
      await _seedPostImage(tester, wide, 360, width: 300, height: 100);
      await pump(
        tester,
        '<table><tr><td><img src="$wide"></td><td>$longText</td></tr><tr><td>封面</td><td>简介</td></tr></table>',
      );
      expect(tester.takeException(), isNull);
      expect(_horizontalScrolls(tester).single.maxScrollExtent, 0);
      final image = tester.getRect(find.byType(NetworkIndicatorImage));
      expect(image.width, inInclusiveRange(120, 300 - 1));
      expect(image.height, closeTo(image.width / 3, 0.5), reason: 'keeps its aspect ratio');
      final long = find.descendant(of: find.textContaining('很长的说明文字'), matching: find.byType(RichText));
      expect(_globalRect(tester.renderObject<RenderParagraph>(long)).right, lessThan(360 - 15));
    });

    testWidgets('a table of wide images scrolls instead of shrinking them to nothing', (tester) async {
      final urls = [for (var i = 1; i <= 3; i++) 'https://example.com/data/attachment/forum/wide$i.png'];
      for (final url in urls) {
        await _seedPostImage(tester, url, 360, width: 300, height: 100);
      }
      final images = urls.map((e) => '<td><img src="$e"></td>').join();
      await pump(tester, '<table><tr>$images</tr><tr><td>左</td><td>中</td><td>右</td></tr></table>');
      expect(tester.takeException(), isNull);
      expect(find.byType(NetworkIndicatorImage), findsNWidgets(3));
      for (final image in tester.widgetList<NetworkIndicatorImage>(find.byType(NetworkIndicatorImage))) {
        expect(tester.getRect(find.byWidget(image)).width, closeTo(300, 0.5), reason: image.src);
      }
      expect(_horizontalScrolls(tester).single.maxScrollExtent, greaterThan(0));
    });

    testWidgets('a table inside a table fits too', (tester) async {
      await pump(
        tester,
        '<table><tr><td>外层</td><td><table><tr><td>内层</td><td>$longText</td></tr><tr><td>甲</td><td>乙</td></tr>'
        '</table></td></tr><tr><td>外层二</td><td>外层的值</td></tr></table>',
        textScale: 1.3,
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(Table), findsNWidgets(2));
      final long = find.descendant(of: find.textContaining('很长的说明文字'), matching: find.byType(RichText));
      expect(_globalRect(tester.renderObject<RenderParagraph>(long)).right, lessThan(360 - 15));
      for (final paragraph in _paragraphs(tester)) {
        expect(_effectiveScale(paragraph), closeTo(1.3, 0.01), reason: paragraph.text.toPlainText());
      }
    });

    testWidgets('a table with a single row is only what it wraps', (tester) async {
      await pump(tester, '<table><tr><td>只是包着的文字</td></tr></table>');
      expect(find.byType(Table), findsNothing);
      expect(find.textContaining('只是包着的文字', findRichText: true), findsOneWidget);
    });
  });
}
