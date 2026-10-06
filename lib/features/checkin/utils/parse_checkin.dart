import 'package:collection/collection.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

final _formHashRe = RegExp(r'formhash" value="(?<FormHash>\w+)"');

/// Parse the form hash in checkin page [document].
///
/// The checkin form is `form#qiandao` (plugin dsu_paulsign) with a hidden `formhash` input, fallback to any formhash
/// input in page and finally the regexp on raw html.
///
/// Marked as public for testing.
String? parseCheckinFormHash(uh.Document document) {
  return document.querySelector('form#qiandao input[name="formhash"]')?.attributes['value'] ??
      document.querySelector('input[name="formhash"]')?.attributes['value'] ??
      _formHashRe.firstMatch(document.documentElement?.innerHtml ?? '')?.namedGroup('FormHash');
}

/// Parse the checkin status text in checkin page [document] if the page tells user the checkin is not available
/// (already checked in today, or not in checkin time).
///
/// ```html
/// <div id="ct_shell"><div class="mn">
/// <h1 class="mt">您今天已经签到过了或者签到时间还未开始</h1>
/// ```
///
/// Marked as public for testing.
String? parseCheckinPageMessage(uh.Document document) =>
    document.querySelectorAll('h1.mt').map((e) => e.innerText.trim()).firstWhereOrNull((e) => e.isNotEmpty);

/// Whether the checkin page [document] says the account checked in today, null if the page does not tell.
///
/// The "service desk" box beside the ranking states it plainly, unlike the page title, which is the same for "already
/// checked in" and "checkin is not open yet" (before 1:00):
///
/// ```html
/// <div class="um" id="qdmsgt">
///   <p>【<span class=gray>今天未签到</span>】</p>
///   <p>您上次签到时间:<font color="#ff00cc">2026-09-10 16:19</font></p>
/// ```
///
/// Marked as public for testing.
bool? parseCheckinDeskStatus(uh.Document document) {
  final text = document.querySelector('div#qdmsgt')?.innerText ?? '';
  if (text.contains('今天已签到')) {
    return true;
  }
  if (text.contains('今天未签到')) {
    return false;
  }
  return null;
}

/// Parse the message text in the checkin ajax response [data].
///
/// The response is an xml document wrapping html:
///
/// ```xml
/// <?xml version="1.0" encoding="utf-8"?>
/// <root><![CDATA[
/// <div class="c">MESSAGE</div>
/// <script ...>...</script>
/// ]]></root>
/// ```
///
/// Fallback to the line heuristic (first line containing `</div>`) if not parsed.
///
/// Marked as public for testing.
String? parseCheckinResponseMessage(String data) {
  String? fromXml;
  try {
    final xmlDoc = parseXmlDocument(data);
    final htmlData = xmlDoc.documentElement?.nodes.firstOrNull?.text;
    if (htmlData != null) {
      final htmlDoc = parseHtmlDocument(htmlData);
      fromXml =
          htmlDoc.querySelector('div.c')?.innerText.trim() ??
          htmlDoc.querySelector('div#messagetext')?.innerText.trim() ??
          htmlDoc.querySelector('div.alert_error, div.alert_right, div.alert_info')?.innerText.trim();
      if (fromXml == null || fromXml.isEmpty) {
        // Bare message followed by a script, e.g. "您需要先登录才能继续本操作<script>…</script>" when the session expired.
        htmlDoc.querySelectorAll('script').forEach((e) => e.remove());
        fromXml = htmlDoc.body?.innerText.trim();
      }
    }
  } on Exception catch (_) {
    // Not xml, use fallback below.
  }
  if (fromXml != null && fromXml.isNotEmpty) {
    return fromXml;
  }
  return data.split('\n').firstWhereOrNull((e) => e.contains('</div>'))?.replaceFirst('</div>', '').trim();
}
