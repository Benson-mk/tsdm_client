import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/forum/utils/forum_page_parser.dart';
import 'package:tsdm_client/features/post/models/models.dart';
import 'package:tsdm_client/features/post/models/poll_create.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/parsing.dart';

import 'poll_fixtures.dart';

PollFormParse _parse(String html, {String fid = '4', int uid = 1000}) =>
    PollCreateForm.parse(parseHtmlDocument(html), fid: fid, uid: uid);

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  test('non-web links in the forum navigation do not interrupt poll discovery', () {
    for (final target in ['javascript:;', 'mailto:example@example.com', 'data:text/plain,hello', 'https:']) {
      final links = '<a href="$target">Other navigation</a>';
      expect(hasPollCreationLink(parseHtmlDocument(links + forumWithPollLink()), '4'), isTrue);
      expect(hasPollCreationLink(parseHtmlDocument(links), '4'), isFalse);
    }
  });

  group('poll creation form', () {
    test('observed X5 form is understood with its dynamic limit and served defaults', () {
      final result = _parse(pollForm(typeSelect: pollTypeSelect, plugin: pollPluginNeutral));
      expect(result.kind, PollFormParseKind.ready);
      final form = result.form!;
      expect(form.maxOptions, 100);
      expect(form.initialMaxChoices, 1);
      expect(form.initialExpiration, '');
      expect(form.subjectLimit, 255);
      expect(form.visibility?.name, 'visibilitypoll');
      expect(form.visibility?.initiallyChecked, isFalse);
      expect(form.overt?.name, 'overt');
      expect(form.neutralPluginFields, {'pollplusviewcredit': '0', 'pollpluslockday': '0'});
      expect(form.passthroughFields, {'fid': '4', 'save': ''});
      expect(form.actionUrl, endsWith('/forum.php?mod=post&action=newthread&fid=4&extra=&topicsubmit=yes'));
      expect(form.content.threadTypeList?.map((e) => e.typeID), ['0', '7']);
      expect(form.extraOptions.map((e) => e.name), ['usesig']);
      expect(form.forumName, 'Synthetic forum');
    });

    test('maxoptions is parsed, never assumed', () {
      expect(_parse(pollForm(maxOptionsScript: "var maxoptions = parseInt('5');")).form!.maxOptions, 5);
      expect(_parse(pollForm(maxOptionsScript: '')).kind, PollFormParseKind.unsupported);
      expect(_parse(pollForm(maxOptionsScript: "var maxoptions = parseInt('1');")).kind, PollFormParseKind.unsupported);
      expect(
        _parse(pollForm(maxOptionsScript: "var maxoptions = parseInt('5'); var maxoptions = parseInt('9');")).kind,
        PollFormParseKind.unsupported,
      );
    });

    test('only the real maxoptions declaration counts, surrounding source is scanned not executed', () {
      const realistic = r'''
var maxoptions = parseInt('20');
var curoptions = 0;
var re = /['"\/]+/g; // quote characters inside a regex literal: maxoptions = 3
function addpolloption() {
  if(curoptions < maxoptions) { curoptions++; }
  var help = 'maxoptions = parseInt(\'99\');';
  return curoptions / 2;
}
/* var maxoptions = parseInt('50'); */''';
      expect(maxOptionsDeclarations(realistic), [20]);
      expect(_parse(pollForm(maxOptionsScript: realistic)).form!.maxOptions, 20);
      // Any other write to maxoptions, or a script that cannot be scanned, is not understood.
      expect(maxOptionsDeclarations("var maxoptions = parseInt('20'); maxoptions = 3;"), isNull);
      expect(maxOptionsDeclarations("var maxoptions = parseInt('20'); maxoptions += 1;"), isNull);
      expect(maxOptionsDeclarations('var maxoptions = 20;'), isNull);
      expect(maxOptionsDeclarations("var maxoptions = parseInt('20'); /* unterminated"), isNull);
      expect(
        _parse(pollForm(maxOptionsScript: "var maxoptions = parseInt('20'); maxoptions = 3;")).kind,
        PollFormParseKind.unsupported,
      );
      // Comparisons are reads, not declarations.
      expect(maxOptionsDeclarations("var maxoptions = parseInt('20'); if (maxoptions == 3 || maxoptions >= 2) {}"), [
        20,
      ]);
    });

    test('unknown required, disabled or read-only essential controls fall back; optional extras do not', () {
      expect(
        _parse(pollForm(extra: '<select name="pluginrule" required><option value="1">1</option></select>')).kind,
        PollFormParseKind.unsupported,
      );
      expect(
        _parse(pollForm(extra: '<input name="adddynamic" type="checkbox" value="1">')).kind,
        PollFormParseKind.ready,
      );
      expect(_parse(pollForm(extra: '<input type="hidden" name="mygroupid" value="">')).kind, PollFormParseKind.ready);
      for (final html in [
        pollForm().replaceFirst(
          '<input type="text" name="maxchoices"',
          '<input type="text" disabled name="maxchoices"',
        ),
        pollForm().replaceFirst(
          '<input type="text" name="expiration"',
          '<input type="text" readonly name="expiration"',
        ),
        pollForm()
            .replaceFirst('<div class="exfm cl">', '<fieldset disabled><div class="exfm cl">')
            .replaceFirst(
              '<div class="area">',
              '</fieldset><div class="area">',
            ),
        pollForm(
          extra: '<fieldset disabled><label><input type="checkbox" name="hiddenreplies" value="1">x</label></fieldset>',
        ),
        pollForm(typeSelect: pollTypeSelect.replaceFirst('<select name="typeid"', '<select disabled name="typeid"')),
      ]) {
        expect(_parse(html).kind, PollFormParseKind.unsupported);
      }
      // The live neutral plugin fields remain usable.
      expect(_parse(pollForm(plugin: pollPluginNeutral)).kind, PollFormParseKind.ready);
    });

    test('absent plugin fields stay absent, non-neutral or unknown plugin rules fall back', () {
      expect(_parse(pollForm()).form!.neutralPluginFields, isEmpty);
      expect(
        _parse(pollForm(plugin: '<input type="text" name="pollplusviewcredit" value="10">')).kind,
        PollFormParseKind.unsupported,
      );
      expect(
        _parse(pollForm(plugin: '<input type="text" name="pollplusrule" value="0">')).kind,
        PollFormParseKind.unsupported,
      );
      expect(
        _parse(pollForm(plugin: '<select name="pollpluslockday"><option value="0">0</option></select>')).kind,
        PollFormParseKind.unsupported,
      );
    });

    test('flags keep the served direction and absent flags are not offered', () {
      final checked = _parse(
        pollForm(flags: '<label><input type="checkbox" name="overt" value="1" checked="checked">Public</label>'),
      ).form!;
      expect(checked.visibility, isNull);
      expect(checked.overt?.initiallyChecked, isTrue);
      expect(
        _parse(pollForm(flags: '<input type="checkbox" name="visibilitypoll" value="2">')).kind,
        PollFormParseKind.unsupported,
      );
    });

    test('foreign action, other forum, other special, challenge or missing bulk entry fall back', () {
      expect(
        _parse(
          pollForm(action: 'https://example.com/forum.php?mod=post&amp;action=newthread&amp;fid=4&amp;topicsubmit=yes'),
        ).kind,
        PollFormParseKind.unsupported,
      );
      expect(_parse(pollForm(), fid: '5').kind, PollFormParseKind.unsupported);
      expect(_parse(pollForm(special: '4')).kind, PollFormParseKind.unsupported);
      expect(_parse(pollForm(bulk: false)).kind, PollFormParseKind.unsupported);
      expect(_parse(pollForm(extra: '<input name="seccodeverify" value="">')).kind, PollFormParseKind.unsupported);
      expect(
        _parse(pollForm(extra: '<input name="cronpublish" checked value="1">')).kind,
        PollFormParseKind.unsupported,
      );
      expect(_parse(pollForm(extra: '<input name="pollimage[]" value="99">')).kind, PollFormParseKind.unsupported);
    });

    test('no permission message is plain text; unknown pages fall back', () {
      final denied = _parse(pollMessage('Synthetic: no permission to post polls', cls: 'alert_error'));
      expect(denied.kind, PollFormParseKind.denied);
      expect(denied.message, 'Synthetic: no permission to post polls');
      expect(_parse(pollPage('<div>nothing</div>')).kind, PollFormParseKind.unsupported);
    });

    test('generic editor guards still reject the special form', () {
      final document = parseHtmlDocument(pollForm());
      expect(PostEditContent.supportsDocument(document), isFalse);
      expect(PostEditContent.fromDocument(document, requireThreadInfo: false), isNull);
    });
  });

  group('forum poll entry', () {
    test('only the page own same-forum special=1 link is an offer, bound to the served account', () {
      expect(parseForumPage(parseHtmlDocument(forumWithPollLink()), '4').pollOfferUid, 1000);
      expect(hasPollCreationLink(parseHtmlDocument(forumWithPollLink()), '5'), isFalse);
      expect(hasPollCreationLink(parseHtmlDocument(forumWithPollLink(where: 'none')), '4'), isFalse);
      expect(hasPollCreationLink(parseHtmlDocument(forumWithPollLink(where: 'rules')), '4'), isFalse);
      expect(hasPollCreationLink(parseHtmlDocument(forumWithPollLink(where: 'thread')), '4'), isFalse);
      expect(parseForumPage(parseHtmlDocument(forumWithPollLink(uid: 0)), '4').pollOfferUid, isNull);
    });
  });
}
