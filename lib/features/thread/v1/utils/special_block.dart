import 'package:html/dom.dart';
import 'package:html/parser.dart';
import 'package:tsdm_client/shared/models/models.dart';

/// The content [bodyHtml] of the first floor [pid] without what the forum's template of the thread's [special] block
/// printed there, which the app shows as its own card instead (plugin 2.8.0, see `threadPageFromApi`).
///
/// On the web page the special template sits in the floor's `div.pcbs` beside everything else the floor carries
/// there (the content table `td.t_f#postmessage_PID`, the attachments, the tags, the latest moderation, other plugins'
/// header and footer, the fast reply of the first floor), so only the template's own top level elements are cut,
/// by type, as the forum's default templates (`viewthread_poll`, `_trade`, `_reward`, `_activity`, `_debate`) print
/// them:
///
/// * poll: the template's scripts and `form#poll`;
/// * goods: the counter line `div.trdc`, the goods list (`div.xs1.cl` around `div.trdb`), the empty counter
///   description `div#postmessage_PID` (kept when it has text) and the "no goods" `div.locked` of a thread without
///   goods;
/// * bounty: `div.rwd` is replaced by the content table inside it (the bounty line and the answer button go), the
///   accepted answer `div.rwdbst` goes; the attachments the template prints after it stay;
/// * activity: the template's scripts, the details `div.act`, the hidden forms `div#activityjoin` and
///   `div#activityjoincancel`, the applicant lists `div.ptm.xs1`;
/// * debate: the verdict `div#umpirepoint`, the end time and umpire lines `p.dtm`, the points `div.ds` and the
///   votes `div.dr`.
///
/// The rest is kept exactly as the forum printed it (the cut is made on the source, not re-serialized). When the
/// floor has no `div.pcbs`, or an element to cut has no end the parser can place, [bodyHtml] comes back unchanged:
/// the card then shows beside the forum's own block rather than losing any of the content.
String bodyHtmlWithoutSpecialBlock(String bodyHtml, ThreadSpecial special, {required String pid}) {
  if (bodyHtml.isEmpty) {
    return bodyHtml;
  }
  final fragment = parseFragment(bodyHtml, generateSpans: true);
  final pcbs = fragment.children.where((e) => e.localName == 'div' && e.classes.contains('pcbs')).firstOrNull;
  if (pcbs == null) {
    return bodyHtml;
  }

  // The parser reads `\r\n` as one `\n` (the forum's templates print `\r\n`): its offsets are mapped back.
  final offsets = _sourceOffsets(bodyHtml);
  (int, int)? rangeOf(Element e) {
    final start = e.sourceSpan?.start.offset;
    final startTagEnd = e.sourceSpan?.end.offset;
    if (start == null || startTagEnd == null || startTagEnd >= offsets.length) {
      return null;
    }
    final end = e.endSourceSpan?.end.offset;
    if (end != null) {
      return end < offsets.length && end >= start ? (offsets[start], offsets[end]) : null;
    }
    // The parser gives a raw text element (a script) no end span: its end tag is the first one after its text.
    if (!_rawTextElements.contains(e.localName)) {
      return null;
    }
    final close = RegExp(
      '</${e.localName}',
      caseSensitive: false,
    ).allMatches(bodyHtml, offsets[startTagEnd]).firstOrNull;
    final closeEnd = close == null ? -1 : bodyHtml.indexOf('>', close.end);
    return closeEnd < 0 ? null : (offsets[start], closeEnd + 1);
  }

  // (start, end, replacement) of each cut, in document order.
  final cuts = <(int, int, String)>[];
  for (final child in pcbs.children) {
    final range = rangeOf(child);
    switch (_cutOf(child, special, pid)) {
      case _Cut.keep:
        continue;
      case _Cut.remove:
        if (range == null) {
          return bodyHtml;
        }
        cuts.add((range.$1, range.$2, ''));
      case _Cut.unwrapMessage:
        final table = child.querySelectorAll('table').where((e) => e.querySelector('td.t_f') != null).firstOrNull;
        final tableRange = table == null ? null : rangeOf(table);
        if (range == null || tableRange == null) {
          return bodyHtml;
        }
        cuts.add((range.$1, range.$2, bodyHtml.substring(tableRange.$1, tableRange.$2)));
    }
  }
  if (cuts.isEmpty) {
    return bodyHtml;
  }
  final out = StringBuffer();
  var last = 0;
  for (final (start, end, replacement) in cuts) {
    if (start < last || end > bodyHtml.length || end < start) {
      return bodyHtml;
    }
    out
      ..write(bodyHtml.substring(last, start))
      ..write(replacement);
    last = end;
  }
  out.write(bodyHtml.substring(last));
  return out.toString();
}

enum _Cut { keep, remove, unwrapMessage }

/// The elements whose text the parser reads raw, ending at their own end tag.
const _rawTextElements = {'script', 'style', 'textarea', 'title', 'xmp', 'noscript', 'noembed', 'noframes', 'iframe'};

_Cut _cutOf(Element e, ThreadSpecial special, String pid) {
  final tag = e.localName;
  final classes = e.classes;
  return switch (special) {
    PollSpecial() when tag == 'script' || (tag == 'form' && e.id == 'poll') => _Cut.remove,
    TradeSpecial() when tag == 'div' && classes.contains('trdc') => _Cut.remove,
    TradeSpecial() when tag == 'div' && classes.contains('xs1') && e.querySelector('div.trdb') != null => _Cut.remove,
    TradeSpecial() when tag == 'div' && e.id == 'postmessage_$pid' && e.text.trim().isEmpty => _Cut.remove,
    TradeSpecial(:final goods) when tag == 'div' && classes.contains('locked') && goods.isEmpty => _Cut.remove,
    RewardSpecial() when tag == 'div' && classes.contains('rwd') => _Cut.unwrapMessage,
    RewardSpecial() when tag == 'div' && classes.contains('rwdbst') => _Cut.remove,
    ActivitySpecial() when tag == 'script' => _Cut.remove,
    ActivitySpecial() when tag == 'div' && classes.contains('act') => _Cut.remove,
    ActivitySpecial() when tag == 'div' && (e.id == 'activityjoin' || e.id == 'activityjoincancel') => _Cut.remove,
    ActivitySpecial() when tag == 'div' && classes.contains('ptm') && classes.contains('xs1') => _Cut.remove,
    DebateSpecial() when tag == 'div' && (e.id == 'umpirepoint' || classes.contains('ds') || classes.contains('dr')) =>
      _Cut.remove,
    DebateSpecial() when tag == 'p' && classes.contains('dtm') => _Cut.remove,
    _ => _Cut.keep,
  };
}

/// The offset in [source] of each character the html parser reads from it, and of its end: the parser reads a
/// `\r\n` as a single `\n` (its offsets count it once), every other character as it is.
List<int> _sourceOffsets(String source) {
  final offsets = <int>[];
  for (var i = 0; i < source.length; i++) {
    if (source.codeUnitAt(i) == 0x0A && i > 0 && source.codeUnitAt(i - 1) == 0x0D) {
      continue;
    }
    offsets.add(i);
  }
  return offsets..add(source.length);
}
