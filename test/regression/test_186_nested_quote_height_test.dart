/// GitHub #158: an event thread wrapped its whole text in four nested quotes and the app left a blank block below it,
/// taller than the text itself, crossed by the bars of the outer quotes.
///
/// Every quote ends with a line break so the text after it starts on a new line. When the quote is the last thing of
/// an outer quote, that break ended an empty line as tall as the line before it, the inner quote: every level doubled
/// the height. Line breaks at the end of a quote are dropped now, as the website does.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:tsdm_client/widgets/quoted_text.dart';
import 'package:universal_html/parsing.dart';

/// The shape of the event post: four quotes opened together, a collapsed format block, text, a hidden block for
/// members who did not reply yet, a line break and the four quotes closed together.
const _eventPost = '''
<div align="center">banner</div>
<blockquote><blockquote><blockquote><blockquote><font size="4"><strong>活动内容</strong></font><br />
line 1<br />
line 2<br />
<div class="spoiler"><div class="spoilerheader"><input type="button" value="活动格式" /></div><div class="spoilerbody" style="display: none;">format</div></div><br />
<font size="4"><strong>活动时间</strong></font><br />
2026.10.01-2026.10.15<br />
<br />
<div class="locked">user1，如果您要查看本帖隐藏内容请<a href="forum.php?mod=post&amp;action=reply&amp;fid=1&amp;tid=1">回复</a></div><br />
</blockquote></blockquote></blockquote></blockquote>''';

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  Future<List<double>> quoteHeights(WidgetTester tester, String html) async {
    tester.view.physicalSize = const Size(400, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final body = parseHtmlDocument('<html><body>$html</body></html>').body!;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: Builder(builder: (context) => munchElement(context, body))),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return find.byType(QuotedText).evaluate().map((e) => (e.renderObject! as RenderBox).size.height).toList();
  }

  testWidgets('an outer quote is only its padding taller than the quote inside', (tester) async {
    final heights = await quoteHeights(tester, '<blockquote><blockquote>a<br />b<br />c</blockquote></blockquote>');
    expect(heights, hasLength(2));
    expect(heights[0] - heights[1], lessThan(30), reason: 'was twice the inner quote');
  });

  testWidgets('the event post: four levels, no blank block below the text', (tester) async {
    final heights = await quoteHeights(tester, _eventPost);
    expect(heights, hasLength(4));
    for (var i = 0; i < 3; i++) {
      expect(heights[i] - heights[i + 1], lessThan(30), reason: 'level $i was twice level ${i + 1}');
    }
    expect(heights.first, lessThan(heights.last * 1.2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('text after a quote still starts on its own line below it', (tester) async {
    final quoteOnly = await quoteHeights(tester, '<blockquote>quoted</blockquote>');
    final root = find.byType(Text).first;
    final withoutAfter = tester.getSize(root).height;
    await quoteHeights(tester, '<blockquote>quoted</blockquote>after');
    final withAfter = tester.getSize(find.byType(Text).first).height;
    expect(withoutAfter, closeTo(quoteOnly.single, 4), reason: 'no blank line below a quote that ends the post');
    expect(withAfter - withoutAfter, greaterThan(10), reason: 'the text after it is a new line, not beside it');
  });
}
