/// GitHub #160: taking off the secondary title showed a loading error, yet the website had it taken off.
///
/// The app checks the result by reading the titles page again. Without any title worn, the "current" block holds a
/// line of text instead of a table, the parser fell back to the first table of the page, the owned titles, and took
/// its first row for the title worn. A block without a table is read as "no title worn" now.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/profile/models/secondary_title.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/parsing.dart';

String _row(int id, String name) => [
  '<tr><td>$id</td><td>$name</td><td></td><td><img src="https://example.com/$id.png" /></td><td>永久</td>',
  '<td><form action="plugin.php?id=tsdmtitle:tsdmtitle&action=settitle" method="post">',
  '<input type="hidden" name="formhash" value="0000" /><input type="hidden" name="settitleid" value="$id" />',
  '<button name="settitlesubmit" type="submit" value="true">使用</button></form></td></tr>',
].join();

String _table(List<String> rows) => [
  '<table class="dt"><thead><tr><th>ID</th><th>名称</th><th></th><th>图片</th><th>期限</th><th>操作</th></tr></thead>',
  '<tbody>${rows.join()}</tbody></table>',
].join();

String _block(String title, String content) =>
    '<div class="bm"><div class="bm_h cl"><h2>$title</h2></div><div class="bm_c">$content</div></div>';

/// The titles page as the forum renders it (2026-10-02), [current] is the content of the "current" block.
String _page(String current) => [
  '<html><body><div id="ct" class="ct2_a wp cl"><div class="mn">',
  _block('当前使用的称号', current),
  _block('当前拥有的称号', _table([_row(674, '称号A'), _row(330, '称号B')])),
  '</div></div></body></html>',
].join();

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  List<int> activated(String html) => SecondaryTitle.parseTitlesPage(
    parseHtmlDocument(html),
  ).where((e) => e.activated).map((e) => e.id).toList();

  test('a title worn is marked, the others are not', () {
    final html = _page(_table([_row(330, '称号B')]));
    expect(SecondaryTitle.parseTitlesPage(parseHtmlDocument(html)).map((e) => e.id), [674, 330]);
    expect(activated(html), [330]);
  });

  test('no title worn: none is marked, not the first owned one', () {
    expect(activated(_page('<p class="emp">您当前还没有装备称号哦...</p>')), isEmpty);
  });

  test('without the block titles the tables are still read in their order', () {
    final html =
        '<html><body>${_table([_row(330, '称号B')])}${_table([_row(674, '称号A'), _row(330, '称号B')])}</body></html>';
    expect(activated(html), [330]);
  });
}
