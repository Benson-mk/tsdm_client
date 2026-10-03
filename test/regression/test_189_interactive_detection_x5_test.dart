/// GitHub #165: ordinary posts got the "interactive content" button.
///
/// The forum adds its own markup to every message: `onmouseover="img_onmouseoverfunc(this)"` on each image, a
/// `replyreload` script at the start of a message. Each
/// made an ordinary post (a reply with a sticker, an event post in nested quotes) look interactive. They are the
/// forum's, not the author's, and no longer count. Authored handlers, styles and forms still do.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/thread/v1/utils/interactive_post_html.dart';

/// A reply as the forum renders it (2026-10-03, names replaced): two quotes, an appended part and a sticker.
const _stickerReply = '''
<table cellspacing="0" cellpadding="0"><tr><td class="t_f" id="postmessage_78122256">
<div class="quote"><blockquote><font size="2"><a href="https://www.tsdm39.com/forum.php?mod=redirect&amp;goto=findpost&amp;pid=78122193&amp;ptid=1266796" target="_blank"><font color="#999999">user1 发表于 2026-10-3 07:34</font></a></font><br />
quoted text</blockquote></div><br />
reply text<br />
<br />
<hr class="l" /><br />
<strong>user2 补充了以下内容 (2026-10-3 07:47)</strong><div class="quote"><blockquote><font size="2"><a href="https://www.tsdm39.com/forum.php?mod=redirect&amp;goto=findpost&amp;pid=78122254&amp;ptid=1266796" target="_blank"><font color="#999999">user3 发表于 2026-10-3 07:46</font></a></font><br />
quoted text</blockquote></div><br />
appended text<img id="aimg_wWYZh" onclick="zoom(this, this.src, 0, 0, 0)" class="zoom" file="https://example.com/sticker.jpg" onmouseover="img_onmouseoverfunc(this)" lazyloadthumb="1" border="0" alt="" /></td></tr></table>''';

/// The start of an event post (tid 1267377): the forum's reload script, a lazy image, four nested quotes.
const _quotedEvent = '''
<table cellspacing="0" cellpadding="0"><tr><td class="t_f" id="postmessage_78099287">
<script type="text/javascript">replyreload += ',' + 78099287;</script><i class="pstatus"> edited </i><br />
<div align="center"><img id="aimg_bVGIU" onclick="zoom(this, this.src, 0, 0, 0)" class="zoom" file="https://example.com/16th.jpg" onmouseover="img_onmouseoverfunc(this)" lazyloadthumb="1" border="0" alt="" /></div>
<blockquote><blockquote><blockquote><blockquote><font size="4"><strong>活动内容</strong></font><br />
<div class="spoiler"><div class="spoilerheader"><input type="button" class="spoilerbutton" value="活动格式" onClick="n = this.parentNode.parentNode.lastChild;if(n.style.display == 'none') {n.style.display = 'block';} else {n.style.display = 'none';} return false;"/> （點擊展開 / 收起）</div><div class="spoilerbody" style="display: none;">format</div></div>
</blockquote></blockquote></blockquote></blockquote></td></tr></table>''';

void main() {
  test('a reply with quotes, an appended part and a sticker is not interactive', () {
    expect(interactivePostHtml(_stickerReply, postId: '78122256'), isNull);
  });

  test('an event post in nested quotes with the forum reload script and a spoiler is not interactive', () {
    expect(interactivePostHtml(_quotedEvent, postId: '78099287'), isNull);
  });

  test('an authored handler next to the forum markup still counts', () {
    final html = _stickerReply.replaceFirst('appended text', '<span onclick="tfCheer()">cheer</span>');
    expect(interactivePostHtml(html, postId: '78122256'), contains('tfCheer'));
  });

  test('an authored script still counts, only the reload line is the forum one', () {
    final html = _quotedEvent.replaceFirst(
      "replyreload += ',' + 78099287;",
      "replyreload += ',' + 78099287; window.tfStart = 1;",
    );
    expect(interactivePostHtml(html, postId: '78099287'), isNotNull);
  });

  test('an authored button inside a spoiler header without the native class still counts', () {
    final html = _quotedEvent.replaceFirst('class="spoilerbutton" ', '');
    expect(interactivePostHtml(html, postId: '78099287'), isNotNull);
  });

  test('an authored button outside a spoiler header still counts', () {
    final html = _quotedEvent.replaceFirst(
      '<font size="4">',
      '<input type="button" value="go" onclick="go()" /><font size="4">',
    );
    expect(interactivePostHtml(html, postId: '78099287'), isNotNull);
  });
}
