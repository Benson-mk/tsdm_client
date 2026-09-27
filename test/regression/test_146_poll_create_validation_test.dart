import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/post/models/models.dart';
import 'package:tsdm_client/features/post/models/poll_create.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/parsing.dart';

import 'poll_fixtures.dart';

PollCreateForm _form({String html = '', String maxOptions = '100'}) => PollCreateForm.parse(
  parseHtmlDocument(
    html.isNotEmpty
        ? html
        : pollForm(plugin: pollPluginNeutral, maxOptionsScript: "var maxoptions = parseInt('$maxOptions');"),
  ),
  fid: '4',
  uid: 1000,
).form!;

PollDraft _draft({
  String subject = 'Synthetic poll',
  String message = '',
  List<String> options = const ['Alpha', 'Beta', ''],
  String maxChoices = '1',
  String expiry = '',
  bool visible = false,
  bool overt = false,
  PostEditThreadType? type,
  List<PostEditContentOption> extras = const [],
}) => PollDraft(
  subject: subject,
  message: message,
  options: options,
  maxChoices: maxChoices,
  expiry: expiry,
  visibleAfterVote: visible,
  publicVoters: overt,
  threadType: type,
  extraOptions: extras,
);

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  test('dstrlen counts ASCII as 1 and every other scalar, emoji included, as 2', () {
    expect(discuzStrLen('abc'), 3);
    expect(discuzStrLen('投票'), 4);
    expect(discuzStrLen('😀'), 2);
    expect(discuzStrLen('a投😀'), 5);
  });

  test('subject limit boundaries with CJK, emoji and escaped characters', () {
    final form = _form();
    PollValidation check(String subject) => validatePollDraft(_draft(subject: subject), form);
    expect(check('a' * 255).isValid, isTrue);
    expect(check('a' * 256).issues, contains(PollInputIssue.subjectTooLong));
    expect(check('投' * 127 + 'a').isValid, isTrue);
    expect(check('投' * 128).issues, contains(PollInputIssue.subjectTooLong));
    expect(check('😀' * 127 + 'a').isValid, isTrue);
    expect(check('😀' * 128).issues, contains(PollInputIssue.subjectTooLong));
    // Counted after the server's escaping: 51 × `&amp;` is 255, 52 would exceed it.
    expect(check('&' * 51).isValid, isTrue);
    expect(check('&' * 52).issues, contains(PollInputIssue.subjectTooLong));
    expect(check('   ').issues, contains(PollInputIssue.subjectEmpty));
  });

  test('body is optional', () {
    final result = validatePollDraft(_draft(), _form());
    expect(result.isValid, isTrue);
    expect(result.submission!.toPayload(_form())['message'], '');
  });

  test('choices: blanks removed, at least 2, dynamic maximum, line breaks rejected', () {
    final form = _form(maxOptions: '3');
    expect(validatePollDraft(_draft(options: ['Only', ' ', '']), form).issues, contains(PollInputIssue.tooFewOptions));
    expect(validatePollDraft(_draft(options: ['A', 'B', 'C']), form).isValid, isTrue);
    expect(
      validatePollDraft(_draft(options: ['A', 'B', 'C', 'D']), form).issues,
      contains(PollInputIssue.tooManyOptions),
    );
    final broken = validatePollDraft(_draft(options: ['A', 'B\nC']), form);
    expect(broken.optionIssues[1], PollInputIssue.optionLineBreak);
    expect(broken.isValid, isFalse);
    final trimmed = validatePollDraft(_draft(options: ['  A ', '', 'B']), form).submission!;
    expect(trimmed.options, ['A', 'B']);
  });

  test('choice storage guard counts server escaping, not raw characters', () {
    final form = _form();
    expect(pollOptionStorageLength('&'), 5);
    expect(pollOptionStorageLength('"<>'), 14);
    expect(validatePollDraft(_draft(options: ['a' * 80, 'B']), form).isValid, isTrue);
    expect(validatePollDraft(_draft(options: ['a' * 81, 'B']), form).optionIssues[0], PollInputIssue.optionTooLong);
    expect(validatePollDraft(_draft(options: ['投' * 80, 'B']), form).isValid, isTrue);
    expect(validatePollDraft(_draft(options: ['😀' * 80, 'B']), form).isValid, isTrue);
    // 16 ampersands are 80 stored characters; 17 would be silently truncated by the column.
    expect(validatePollDraft(_draft(options: ['&' * 16, 'B']), form).isValid, isTrue);
    expect(validatePollDraft(_draft(options: ['&' * 17, 'B']), form).optionIssues[0], PollInputIssue.optionTooLong);
    // The payload is raw text, never pre-escaped.
    final raw = validatePollDraft(_draft(options: ['A & "B"', '<C>']), form).submission!;
    expect(raw.toPayload(form)['polloptions'], 'A & "B"\n<C>');
  });

  test('max choices is 1..number of choices', () {
    final form = _form();
    PollValidation check(String value) => validatePollDraft(_draft(options: ['A', 'B', 'C'], maxChoices: value), form);
    expect(check('0').issues, contains(PollInputIssue.maxChoicesInvalid));
    expect(check('1').isValid, isTrue);
    expect(check('3').submission!.maxChoices, 3);
    expect(check('4').issues, contains(PollInputIssue.maxChoicesInvalid));
    expect(check('').issues, contains(PollInputIssue.maxChoicesInvalid));
    expect(check('1.5').issues, contains(PollInputIssue.maxChoicesInvalid));
  });

  test('expiry: empty, 0, 00 and padded zero are one canonical unlimited value', () {
    final form = _form();
    for (final text in ['', '0', '00', ' 0 ', '000']) {
      final submission = validatePollDraft(_draft(expiry: text), form).submission!;
      expect(submission.expiryDays, 0, reason: text);
      expect(submission.toPayload(form)['expiration'], '', reason: text);
    }
    final padded = validatePollDraft(_draft(expiry: ' 007 '), form).submission!;
    expect(padded.expiryDays, 7);
    expect(padded.toPayload(form)['expiration'], '7');
    for (final text in ['-1', '1.5', 'abc', '7 days']) {
      expect(validatePollDraft(_draft(expiry: text), form).issues, contains(PollInputIssue.expiryInvalid));
    }
  });

  test('thread type is optional for polls; a positive choice must be served', () {
    // Upstream model_thread skips `post_type_isnull` when `special` is set, even on boards requiring a type.
    final form = _form(html: pollForm(typeSelect: pollTypeSelect));
    final types = form.content.threadTypeList!;
    for (final type in [null, types[0]]) {
      final result = validatePollDraft(_draft(type: type), form);
      expect(result.isValid, isTrue, reason: '${type?.typeID}');
      expect(result.submission!.threadType, isNull);
      expect(result.submission!.toPayload(form)['typeid'], '0');
    }
    expect(validatePollDraft(_draft(type: types[1]), form).submission!.toPayload(form)['typeid'], '7');
    expect(
      validatePollDraft(
        _draft(
          type: const PostEditThreadType(name: 'Gone', typeID: '99'),
        ),
        form,
      ).issues,
      contains(PollInputIssue.threadTypeUnavailable),
    );
    // Without a served selector no typeid is posted.
    expect(validatePollDraft(_draft(), _form()).submission!.toPayload(_form()).containsKey('typeid'), isFalse);
  });

  test('payload is the confirmed poll with bulk choices, served flags and neutral plugin fields only', () {
    final form = _form();
    final submission = validatePollDraft(
      _draft(
        message: 'Synthetic body',
        options: ['Alpha', '', 'Beta', 'Gamma'],
        maxChoices: '2',
        expiry: '3',
        visible: true,
        extras: form.extraOptions,
      ),
      form,
    ).submission!;
    expect(submission.toPayload(form), {
      'fid': '4',
      'save': '',
      'formhash': 'synthetic-token',
      'posttime': '1700000000',
      'wysiwyg': '0',
      'special': '1',
      'polls': 'yes',
      'subject': 'Synthetic poll',
      'message': 'Synthetic body',
      'tpolloption': '2',
      'polloptions': 'Alpha\nBeta\nGamma',
      'maxchoices': '2',
      'expiration': '3',
      'pollplusviewcredit': '0',
      'pollpluslockday': '0',
      'visibilitypoll': '1',
      'usesig': '1',
    });
  });

  test('flags absent from the form are never posted and a chosen one is reported, not silently dropped', () {
    final form = _form(html: pollForm(flags: ''));
    expect(validatePollDraft(_draft(visible: true), form).issues, contains(PollInputIssue.flagUnavailable));
    expect(validatePollDraft(_draft(overt: true), form).issues, contains(PollInputIssue.flagUnavailable));
    final payload = validatePollDraft(_draft(), form).submission!.toPayload(form);
    expect(payload.containsKey('visibilitypoll'), isFalse);
    expect(payload.containsKey('overt'), isFalse);
    expect(payload.containsKey('pollplusviewcredit'), isFalse);
  });

  test('a checked bool option the form no longer offers is reported', () {
    const gone = PostEditContentOption(
      name: 'hiddenreplies',
      value: '1',
      disabled: false,
      checked: true,
      readableName: 'Gone option',
    );
    expect(validatePollDraft(_draft(extras: [gone]), _form()).issues, contains(PollInputIssue.extraOptionUnavailable));
  });
}
