import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/profile/utils/parse_profile.dart';
import 'package:tsdm_client/features/profile/widgets/secondary_title_badge.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// Where the secondary title images shown in the app come from.
///
/// * Thread floors: the author column of the floor itself (`div.tsdmtitle-badges`), public X5 sample of test #011.
/// * Profile pages: the same block inside the profile content only; the X5 profile sample has none, the markup on a
///   profile page is not established by any sample yet.
String _data(String name) => File('test/data/$name').readAsStringSync();

const _threadTitle = 'https://img.tsdm39.com/img01/title/无职转生.gif';

uh.Element _floor(uh.Document doc) => doc.querySelector('div#post_77983102')!;

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('thread floor', () {
    test('the secondary title comes from the author column of the floor', () {
      final doc = parseHtmlDocument(_data('locked_purchase_x5.html'));
      final post = Post.fromPostNode(_floor(doc), 1);
      expect(post, isNotNull);
      expect(post!.secondBadge, _threadTitle);
    });

    test('a floor whose author uses no title has none, whatever the other floors show', () {
      final doc = parseHtmlDocument(_data('locked_purchase_x5.html'));
      final withTitle = _floor(doc);
      final withoutTitle = withTitle.clone(true) as uh.Element;
      withoutTitle.querySelectorAll('div.tsdmtitle-badges').forEach((e) => e.remove());
      withTitle.parent!.append(withoutTitle);

      expect(Post.fromPostNode(withTitle, 1)?.secondBadge, _threadTitle);
      expect(Post.fromPostNode(withoutTitle, 1)?.secondBadge, isNull);
    });
  });

  group('profile page', () {
    test('the X5 profile sample renders no title block: nothing is shown', () {
      expect(parseProfileSecondaryTitleUrl(parseHtmlDocument(_data('profile_self_x5.html'))), isNull);
    });

    test('the title block inside the profile content belongs to the owner', () {
      final doc = parseHtmlDocument('''
<html><body>
<div id="hd"><div id="um"><p><strong class="vwmy"><a href="home.php?mod=space&amp;uid=1000">Alice</a></strong></p></div></div>
<div id="wp"><div id="ct"><div class="bm_c u_profile">
<h2 class="mbn">Bob<span class="xw0">(UID: 1001)</span></h2>
<div class="tsdmtitle-badges"><div class="tsdmtitle-title"><img src="data/title/owner.gif" alt="Owner title" /></div></div>
</div></div></div>
</body></html>''');
      expect(parseProfileSecondaryTitleUrl(doc), 'https://www.tsdm39.com/data/title/owner.gif');
    });

    test('a title block in the page header (the viewing account) is not the owner', () {
      final doc = parseHtmlDocument('''
<html><body>
<div id="hd"><div id="um"><div class="tsdmtitle-badges"><div class="tsdmtitle-title"><img src="https://example.invalid/viewer.gif" /></div></div></div></div>
<div id="wp"><div id="ct"><div class="bm_c u_profile"><h2 class="mbn">Bob</h2></div></div></div>
</body></html>''');
      expect(parseProfileSecondaryTitleUrl(doc), isNull);
    });
  });

  test('the badge box keeps the natural 184x100 ratio', () {
    expect(SecondaryTitleBadge.heightFor(184), 100);
    expect(SecondaryTitleBadge.heightFor(92), 50);
  });
}
