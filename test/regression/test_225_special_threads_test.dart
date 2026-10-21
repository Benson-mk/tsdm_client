/// The forum's app API, plugin 2.8.0: the thread page answer (`schema: 15`, add-only over 14) gives the special block
/// of the first floor (poll, goods, bounty, activity, debate) as a top-level `special`, with the forum's own forms for
/// what the account may do there, and each floor's side in a debate (`stand`, `stand_votes`) and the accepted answer
/// of a bounty (`best`).
///
/// The app shows the block as its own card instead of the forum's html of it ([ThreadSpecial], [SpecialThreadCard]):
/// the html the template printed is cut out of the first floor ([bodyHtmlWithoutSpecialBlock]) only when `special` is
/// there; the actions post the forum's forms ([SpecialRequest], [SpecialThreadRepository], the poll through
/// [PollRepository]) and read the plugin 2.6.0 result ([specialActionOutcomeOf]); a done action reloads the thread
/// page. Without `special` (an older plugin, another page, a hidden or forged first floor) nothing changes.
///
/// The fixtures `special_v15_*.json` are the plugin's 2.8.0 contract samples (Discuz X5 test forum, 2026-10-21: every
/// type and state seen by the author, a member, a moderator, the umpire and a guest, and the results of a real poll
/// vote, activity application and cancel, best answer and debate vote; `…_refused_action.json` is the forum's refusal
/// of a second best answer from the plugin's acceptance run) with the test forum's host, name and form hash scrubbed.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/poll/cubit/poll_cubit.dart';
import 'package:tsdm_client/features/poll/models/forum_poll.dart';
import 'package:tsdm_client/features/poll/repository/poll_repository.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/special_thread/repository/special_thread_repository.dart';
import 'package:tsdm_client/features/special_thread/widgets/special_form_dialog.dart';
import 'package:tsdm_client/features/special_thread/widgets/special_thread_card.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/features/thread/v1/utils/special_block.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/widgets/card/poll_card.dart';
import 'package:tsdm_client/widgets/card/post_card/post_card.dart';
import 'package:tsdm_client/widgets/munched_html.dart';

const _dir = 'test/data/tsdmapp';

/// The fixture `special_v15_[name].json`.
Map<String, dynamic> _json(String name) =>
    jsonDecode(File('$_dir/special_v15_$name.json').readAsStringSync()) as Map<String, dynamic>;

/// Every thread page fixture.
final List<String> _pages =
    Directory(_dir)
        .listSync()
        .map((e) => e.uri.pathSegments.last)
        .where((e) => e.startsWith('special_v15_') && !e.endsWith('_action.json'))
        .map((e) => e.substring('special_v15_'.length, e.length - '.json'.length))
        .toList()
      ..sort();

ThreadPageInfo _page(String name) => threadPageFromApi(_json(name), 1);

T _special<T extends ThreadSpecial>(String name) => _page(name).special! as T;

/// The first floor of the answer [json], as the answer gives it.
Map<String, dynamic> _firstFloor(Map<String, dynamic> json) =>
    (json['posts'] as List).cast<Map<String, dynamic>>().firstWhere((p) => p['first'] == 1);

/// The thread id of the fixture [name].
int _tid(String name) => (_json(name)['thread'] as Map<String, dynamic>)['tid'] as int;

final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// The forum answering every request with [body] (JSON when it is an object), recording the requests.
final class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.body);

  final Object body;
  final requests = <RequestOptions>[];
  final bodies = <String?>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    bodies.add(requestStream == null ? null : utf8.decode(await requestStream.expand((e) => e).toList()));
    final json = body is Map;
    return ResponseBody.fromString(
      json ? jsonEncode(body) : '$body',
      200,
      headers: {
        Headers.contentTypeHeader: [if (json) 'application/json; charset=utf-8' else 'text/xml; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A transport sending nothing: records the requests and answers the given answer.
final class _FakeSpecialRepository {
  _FakeSpecialRepository(Object? answer) {
    repository = SpecialThreadRepository(
      send: (request) async {
        sent.add(request);
        return answer;
      },
    );
  }

  late final SpecialThreadRepository repository;
  final sent = <SpecialRequest>[];
}

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  group('A. the special block of every fixture', () {
    test('every page fixture is a schema 15 thread page; its special block matches its name and type', () {
      expect(_pages, hasLength(greaterThanOrEqualTo(40)));
      for (final name in _pages) {
        final json = _json(name);
        expect(json['schema'], 15, reason: name);
        final page = threadPageFromApi(json, 1);
        final raw = json['special'];
        if (raw == null) {
          expect(page.special, isNull, reason: name);
          expect(page.postList.where((e) => e.special != null), isEmpty, reason: name);
          continue;
        }
        final type = (raw as Map<String, dynamic>)['type'];
        expect(name.split('_').first, type, reason: name);
        expect(
          switch (page.special) {
            PollSpecial() => 'poll',
            TradeSpecial() => 'trade',
            RewardSpecial() => 'reward',
            ActivitySpecial() => 'activity',
            DebateSpecial() => 'debate',
            null => null,
          },
          type,
          reason: name,
        );
        // On the page and on its first floor, with the answer's account and form hash.
        final first = page.postList.where((e) => e.special != null).toList();
        expect(first, hasLength(1), reason: name);
        expect(first.single.postID, '${_firstFloor(json)['pid']}', reason: name);
        expect(identical(first.single.special, page.special), isTrue, reason: name);
        expect(page.special!.formHash, 'f1f2f3f4', reason: name);
        expect(page.special!.viewerUid, json['uid'] == 0 ? isNull : json['uid'], reason: name);
      }
    });

    test('no special block: a page without the first floor, a banned or forged first floor', () {
      for (final name in ['debate_no_first_floor', 'poll_banned_first_low2', 'poll_spoofed_first']) {
        expect(_page(name).special, isNull, reason: name);
      }
      // The moderator sees the single-banned first floor, and its poll.
      expect(_page('poll_banned_first_mod').special, isA<PollSpecial>());
    });

    test('older answers and odd values: no block, no field breaks', () {
      // An answer of plugin 2.7.0 (schema 14) has no `special`, nor the floors' fields.
      final old = jsonDecode(File('$_dir/thread_v14_plain.json').readAsStringSync()) as Map<String, dynamic>;
      final page = threadPageFromApi(old, 1);
      expect(page.special, isNull);
      expect(page.postList.every((e) => e.special == null && e.stand == null && !e.best && e.standVotes == 0), isTrue);
      expect(page.postList.every((e) => e.bestAnswerRequest == null), isTrue);

      // Unknown type, not an object.
      for (final value in [
        {'type': 'rush'},
        {'type': 127},
        'poll',
        42,
        <Object?>[],
        null,
      ]) {
        expect(ThreadSpecial.fromApi(value, formHash: 'f1f2f3f4', viewerUid: 1), isNull, reason: '$value');
        final json = _json('poll_single_before')..['special'] = value;
        final page = threadPageFromApi(json, 1);
        expect(page.special, isNull);
        expect(page.postList.first.data, _firstFloor(json)['body_html'], reason: 'the floor stays as it was');
      }

      // Every type with nothing but its type: empty, 0 and null, no action.
      final poll = ThreadSpecial.fromApi({'type': 'poll'})! as PollSpecial;
      expect(poll.choices, isEmpty);
      expect((poll.form, poll.voteUrl, poll.expiration, poll.viewerUid), (null, null, null, null));
      expect(forumPollFromSpecial(poll, loggedIn: true).availability, PollAvailability.closed);
      final trade = ThreadSpecial.fromApi({'type': 'trade'})! as TradeSpecial;
      expect(trade.goods, isEmpty);
      expect((trade.count, trade.creditUnit, trade.manageUrl), (null, null, null));
      final reward = ThreadSpecial.fromApi({'type': 'reward'})! as RewardSpecial;
      expect((reward.price, reward.bestPost, reward.setBest, reward.bestAnswerRequest(1)), (0, null, null, null));
      final activity = ThreadSpecial.fromApi({'type': 'activity'})! as ActivitySpecial;
      expect(
        (activity.appliedCount, activity.remaining, activity.apply, activity.applyRequest({})),
        (null, null, null, null),
      );
      expect(activity.cancelRequest(''), isNull);
      final debate = ThreadSpecial.fromApi({'type': 'debate'})! as DebateSpecial;
      expect((debate.affirmDebaters, debate.result, debate.voteRequest(1), debate.endTime), (null, null, null, null));

      // Numbers as text, wrong types, lists of junk.
      final odd =
          ThreadSpecial.fromApi({
                'type': 'poll',
                'multiple': '1',
                'maxchoices': '2',
                'voters': 'many',
                'expiration': 'soon',
                'choices': [
                  'x',
                  {'id': 0, 'text': 'no id'},
                  {'id': '7', 'no': 1, 'text': 'seven', 'votes': '3', 'percent': 'x'},
                ],
                'form': {'action': 5},
              })!
              as PollSpecial;
      expect((odd.multiple, odd.maxChoices, odd.voters, odd.expiration, odd.form), (true, 2, 0, null, null));
      expect(odd.choices.single.id, 7);
      expect((odd.choices.single.votes, odd.choices.single.percent), (null, null), reason: 'hidden unless numbers');
    });
  });

  group('B. each type and state', () {
    test('poll: single choice with its results, a link choice, the form', () {
      final poll = _special<PollSpecial>('poll_single_before');
      expect((poll.multiple, poll.maxChoices, poll.canVote, poll.why, poll.voted), (false, 1, true, '', false));
      expect(poll.choices.map((e) => (e.no, e.text, e.votes, e.percent)), [
        (1, '選項甲 222088', 1, 100.0),
        (2, '選項乙', 0, 0.0),
        (3, '連結選項', 0, 0.0),
      ]);
      expect(poll.choices.last.html, contains('<a href="https://example.com/"'));
      final tid = _tid('poll_single_before');
      expect(
        poll.voteUrl,
        'https://www.tsdm39.com/forum.php?mod=misc&action=votepoll&fid=2&tid=$tid&pollsubmit=yes&quickforward=yes&inajax=1',
      );
      final card = forumPollFromSpecial(poll, loggedIn: true);
      expect(card.availability, PollAvailability.available);
      expect(card.maxChoices, 1);
      expect(card.options.map((e) => (e.id, e.label, e.result)), [
        ('260', '1. 選項甲 222088', '100.00% (1)'),
        ('261', '2. 選項乙', '0.00% (0)'),
        ('262', '3. 連結選項', '0.00% (0)'),
      ]);
      expect(
        card.summary,
        '${t.specialThread.poll.single}${t.specialThread.poll.separator}'
        '${t.specialThread.poll.voters(count: 1)}',
      );
      expect(card.formHash, 'f1f2f3f4');
      expect(card.accepts({'261'}), isTrue);
      expect(card.accepts({'260', '261'}), isFalse);
    });

    test('poll: results after a vote are null, not 0; the voted, closed, guest, image and moderator states', () {
      final hidden = _special<PollSpecial>('poll_multi_hidden');
      expect(
        (hidden.multiple, hidden.maxChoices, hidden.resultsVisible, hidden.afterResult, hidden.overt),
        (
          true,
          2,
          false,
          true,
          true,
        ),
      );
      expect(hidden.choices.every((e) => e.votes == null && e.percent == null), isTrue);
      final card = forumPollFromSpecial(hidden, loggedIn: true);
      expect(card.options.every((e) => e.result == null), isTrue);
      expect(card.maxChoices, 2);
      expect(card.summary, contains(t.specialThread.poll.afterResult));
      expect(card.notice, t.specialThread.poll.overt);
      expect(card.deadline, startsWith(t.specialThread.poll.deadline(time: '').trim()));

      final voted = _special<PollSpecial>('poll_multi_voted');
      expect((voted.voted, voted.canVote, voted.why, voted.form), (true, false, 'voted', null));
      expect(voted.choices.every((e) => e.votes != null), isTrue, reason: 'the voter sees the results');
      expect(forumPollFromSpecial(voted, loggedIn: true).availability, PollAvailability.voted);
      expect(
        forumPollFromSpecial(_special('poll_single_after_vote'), loggedIn: true).availability,
        PollAvailability.voted,
      );

      final expired = _special<PollSpecial>('poll_expired');
      expect((expired.expired, expired.why, expired.form), (true, 'closed', null));
      final closed = forumPollFromSpecial(expired, loggedIn: true);
      expect(closed.availability, PollAvailability.closed);
      expect(closed.deadline, t.specialThread.poll.ended);

      final guest = _special<PollSpecial>('poll_single_guest');
      expect((guest.viewerUid, guest.canVote, guest.why), (null, false, 'nopermission'));
      expect(forumPollFromSpecial(guest, loggedIn: false).availability, PollAvailability.loginRequired);
      expect(forumPollFromSpecial(guest, loggedIn: true).availability, PollAvailability.denied);

      final image = _special<PollSpecial>('poll_image');
      expect(image.image, isTrue);
      expect(
        image.choices.map((e) => e.image?.small),
        everyElement(startsWith('https://www.tsdm39.com/data/attachment/')),
      );
      expect(forumPollFromSpecial(image, loggedIn: true).options.map((e) => e.image), everyElement(isNotNull));

      final mod = _special<PollSpecial>('poll_multi_mod');
      expect(mod.resultsVisible, isTrue, reason: 'a moderator sees the results before voting');
      expect(mod.choices.every((e) => e.votes != null), isTrue);
    });

    test('goods: the list in the page order, a deleted goods, the credit unit, managing for the author only', () {
      final author = _special<TradeSpecial>('trade_author');
      expect(author.count, 3);
      expect((author.creditUnit?.id, author.creditUnit?.title), (2, '天使币'));
      expect(author.canManage, isTrue);
      expect(
        author.manageUrl,
        'https://www.tsdm39.com/forum.php?mod=misc&action=tradeorder&tid=${_tid('trade_author')}',
      );
      expect(author.canAdd, isFalse);
      expect(author.goods, hasLength(3));
      final [first, removed, third] = author.goods;
      expect((first.subject, first.sticky, first.quality, first.timeout), ('商品一 222088', true, 1, false));
      expect((first.remain?.days, first.remain?.hours), (3, 5));
      expect((first.price, first.credit, first.costPrice, first.costCredit), (10, 5, 20.5, 8));
      expect(first.thumb, startsWith('https://www.tsdm39.com/data/attachment/'));
      expect(
        first.url,
        'https://www.tsdm39.com/forum.php?mod=viewthread&do=tradeinfo&tid=${_tid('trade_author')}&pid=${first.pid}',
      );
      expect((removed.removed, removed.subject, removed.url, removed.thumb), (true, '', null, null));
      expect((third.quality, third.timeout, third.remain, third.price, third.credit), (2, true, null, 0, 3));

      final guest = _special<TradeSpecial>('trade_guest');
      expect((guest.canManage, guest.manageUrl, guest.goods.length), (false, null, 3));
      expect(_special<TradeSpecial>('trade_mod').canManage, isFalse, reason: 'the moderators have no allowedittrade');
      expect(_special<TradeSpecial>('trade_authorid_filter').goods, isEmpty);
    });

    test('bounty: open with the floors the author may accept, resolved with its answer, the hidden excerpts', () {
      final open = _special<RewardSpecial>('reward_open_author');
      expect(
        (open.price, open.resolved, open.credit?.title, open.canAnswer, open.canSetBest),
        (2, false, '天使币', true, true),
      );
      expect(open.setBest?.pids, [5801, 5802]);
      expect(open.bestPost, isNull);
      expect(_special<RewardSpecial>('reward_open_member').canSetBest, isFalse);
      expect(_special<RewardSpecial>('reward_open_guest').setBest, isNull);

      final resolved = _special<RewardSpecial>('reward_resolved');
      expect((resolved.resolved, resolved.canSetBest, resolved.price), (true, false, 5));
      final best = resolved.bestPost!;
      expect((best.pid, best.authorId, best.author, best.anonymous), (5807, 31, 'ag_low', false));
      expect(best.excerpt, 'BEST_TEXT_222088 最佳答案的內文');
      expect(
        best.url,
        'https://www.tsdm39.com/forum.php?mod=redirect&goto=findpost&ptid=${_tid('reward_resolved')}&pid=5807',
      );

      for (final (name, reason) in [
        ('reward_resolved_hiddenreply_locked', 'locked'),
        ('reward_resolved_hide_excerpt', 'hide'),
        ('reward_best_password', 'password'),
        ('reward_best_banned', 'banned'),
      ]) {
        final best = _special<RewardSpecial>(name).bestPost!;
        expect((best.excerpt, best.excerptReason), (null, reason), reason: name);
      }
      expect(_special<RewardSpecial>('reward_resolved_hiddenreply_author').bestPost!.excerpt, isNotNull);
      expect(_special<RewardSpecial>('reward_best_banned_mod').bestPost!.excerpt, isNotNull);

      final anonymous = _special<RewardSpecial>('reward_best_anonymous').bestPost!;
      expect((anonymous.authorId, anonymous.author, anonymous.avatar, anonymous.anonymous), (0, '', null, true));
      expect(_special<RewardSpecial>('reward_best_anonymous_mod').bestPost!.anonymous, isFalse);
    });

    test('activity: details, the application form, the account application, the applicants', () {
      final member = _special<ActivitySpecial>('activity_open_member');
      expect(
        (member.activityClass, member.place, member.gender, member.cost, member.number),
        (
          '測試活動',
          'PLACE_222088',
          0,
          10,
          5,
        ),
      );
      expect(member.startFrom, isNotNull);
      expect(member.startTo!.isAfter(member.startFrom!), isTrue);
      expect(member.expiration, isNotNull);
      expect((member.appliedCount, member.verifiedCount, member.pendingCount, member.remaining), (3, 1, 2, 4));
      expect((member.applied, member.verified, member.canApply, member.applyMode), (false, null, true, 'join'));
      expect(member.apply!.inputs.map((e) => (e.name, e.type, e.required)), [
        ('payment', 'radio', true),
        ('payvalue', 'text', false),
        ('qq', 'text', true),
        ('bloodtype', 'select', true),
        ('衣服尺寸', 'text', false),
        ('message', 'textarea', false),
      ]);
      expect(member.apply!.inputs.first.choices.map((e) => e.value), ['0', '1']);
      expect(member.applyNeedsWeb, isFalse);
      expect(member.applyList.single.username, 'ag_mod');
      expect(member.applyList.single.payment, 10);
      expect(member.pending.map((e) => (e.message, e.payment)), everyElement(('', -1)), reason: 'not the author');
      expect((member.canManage, member.manageUrl, member.canCancel), (false, null, false));

      final author = _special<ActivitySpecial>('activity_author_sees_pending');
      expect(author.canManage, isTrue);
      expect(author.manageUrl, startsWith('https://www.tsdm39.com/forum.php?mod=misc&action=activityapplylist&tid='));
      expect(author.pending.where((e) => e.message.isNotEmpty), isNotEmpty, reason: 'the author reads the messages');

      final applied = _special<ActivitySpecial>('activity_applied');
      expect((applied.applied, applied.verified, applied.canApply, applied.canCancel), (true, 0, false, true));
      expect(applied.cancel!.inputs.single.name, 'message');
      expect(_special<ActivitySpecial>('activity_verified').verified, 1);
      final complete = _special<ActivitySpecial>('activity_complete_data');
      expect((complete.verified, complete.applyMode, complete.canApply), (2, 'complete', true));
      expect(complete.apply!.inputs.last.value, startsWith('COMPLETE_MSG'), reason: 'the account own values prefilled');

      final closed = _special<ActivitySpecial>('activity_closed');
      expect((closed.closed, closed.canApply, closed.number, closed.remaining), (true, false, 0, null));
      final notEnough = _special<ActivitySpecial>('activity_credit_not_enough');
      expect((notEnough.credit?.amount, notEnough.credit?.enough, notEnough.canApply), (65535, false, false));
      expect(notEnough.credit?.credit.title, '威望');
      final enough = _special<ActivitySpecial>('activity_credit_no_lowerlimit');
      expect((enough.credit?.enough, enough.canApply), (true, true));
      final guest = _special<ActivitySpecial>('activity_open_guest');
      expect((guest.viewerUid, guest.canApply, guest.apply, guest.credit), (null, false, null, null));
    });

    test('debate: both sides, the verdict, the account vote, the umpire', () {
      final open = _special<DebateSpecial>('debate_open_member');
      expect((open.affirmPoint, open.negaPoint), ('正方觀點 AFF_222088', '反方觀點 NEG_222088'));
      expect((open.affirmVotes, open.negaVotes, open.affirmDebaters, open.negaDebaters), (1, 0, 1, 1));
      expect(open.affirmAvatars.single.username, 'ag_low');
      expect(open.negaAvatars.single.avatar, 'https://www.tsdm39.com/data/avatar/noavatar.svg');
      expect((open.ended, open.umpire, open.result, open.voted, open.canVote), (false, 'ag_mod', null, 0, true));
      expect(open.endTime, isNotNull);
      expect((open.canUmpire, open.umpireUrl), (false, null));

      final result = _special<DebateSpecial>('debate_ended_result');
      expect((result.ended, result.canVote, result.vote), (true, false, null));
      expect(
        (result.result?.winner, result.result?.umpirePoint, result.result?.bestDebater),
        (
          1,
          '正方勝 UMPIRE_222088',
          'ag_low',
        ),
      );

      final umpire = _special<DebateSpecial>('debate_umpire_voted');
      expect((umpire.voted, umpire.canVote, umpire.canUmpire), (1, false, true));
      expect(umpire.umpireUrl, startsWith('https://www.tsdm39.com/forum.php?mod=misc&action=debateumpire&tid='));
      expect(_special<DebateSpecial>('debate_voted').voted, 1);
      expect(_special<DebateSpecial>('debate_open_guest').canVote, isFalse);

      final noEnd = _special<DebateSpecial>('debate_no_endtime');
      expect((noEnd.endTime, noEnd.umpire, noEnd.canVote), (null, '', true));
    });
  });

  group('C. the floors', () {
    test('a debate floor takes a side with its supporters; the first floor and other threads none', () {
      for (final name in ['debate_open_member', 'debate_open_guest', 'debate_voted']) {
        final posts = _page(name).postList;
        expect(posts.map((e) => (e.stand, e.standVotes)), [(null, 0), (1, 2), (2, 0), (0, 0)], reason: name);
      }
      // The page without the first floor (only one author) still has the side of the floor.
      expect(_page('debate_no_first_floor').postList.single.stand, 1);
      for (final name in _pages.where((e) => !e.startsWith('debate'))) {
        expect(_page(name).postList.every((e) => e.stand == null && e.standVotes == 0), isTrue, reason: name);
      }
    });

    test('the accepted answer of a bounty is marked; the floors the author may accept carry the request', () {
      expect(_page('reward_resolved').postList.map((e) => e.best), [false, true, false]);
      expect(_page('reward_open_author').postList.map((e) => e.best), everyElement(isFalse));
      for (final name in _pages.where((e) => !e.startsWith('reward'))) {
        expect(_page(name).postList.every((e) => !e.best), isTrue, reason: name);
      }

      final open = _page('reward_open_author').postList;
      expect(open.map((e) => e.bestAnswerRequest != null), [false, true, true]);
      for (final name in ['reward_open_member', 'reward_open_guest', 'reward_resolved']) {
        expect(_page(name).postList.every((e) => e.bestAnswerRequest == null), isTrue, reason: name);
      }
    });
  });

  group('D. the forum html of the block is cut out of the first floor only when the block is given', () {
    /// The marks of each template's own html.
    const marks = {
      'poll': ['id="poll"', 'pollanswers'],
      'trade': ['class="trdb"', 'class="trdc'],
      'reward': ['class="rwdbst"', 'class="rsld', 'class="rusld', 'name="answer"'],
      'activity': ['class="act pbm', 'id="activityjoin', 'applylist_', 'function checkform'],
      'debate': ['id="umpirepoint"', 'class="ds"', 'class="dr"', 'class="dtm'],
    };

    test('every fixture: the block html goes, the content, comment and rate places stay, other floors untouched', () {
      for (final name in _pages) {
        final json = _json(name);
        final page = threadPageFromApi(json, 1);
        final raws = (json['posts'] as List).cast<Map<String, dynamic>>();
        for (final (i, post) in page.postList.indexed) {
          final raw = raws[i];
          if (post.special == null) {
            expect(post.data, raw['body_html'], reason: '$name floor ${post.postID} kept as it was');
            continue;
          }
          final type = name.split('_').first;
          final body = raw['body_html'] as String;
          expect(marks[type]!.any(body.contains), isTrue, reason: '$name: the forum printed its block');
          for (final mark in marks[type]!) {
            expect(post.data, isNot(contains(mark)), reason: '$name: $mark cut');
          }
          final pid = post.postID;
          expect(post.data, contains('id="postmessage_$pid">'), reason: '$name: the content stays');
          expect(post.data, contains('<div id="comment_$pid" class="cm">'), reason: name);
          expect(post.data, contains('<div id="post_rate_div_$pid"></div>'), reason: name);
          expect(post.data, contains('<div class="pcbs">'), reason: name);
          // The content table itself is the forum's, byte for byte.
          final table = RegExp(
            '<table cellspacing="0" cellpadding="0"><tr><td class="t_f" id="postmessage_$pid">'
            r'[\s\S]*?</td></tr></table>',
          );
          expect(table.firstMatch(post.data)?.group(0), table.firstMatch(body)?.group(0), reason: name);
          expect(post.data.length, lessThan(body.length), reason: name);
        }
      }
    });

    test('the same floor without the block keeps the forum html (an older plugin, the block not given)', () {
      final json = _json('activity_open_member');
      final body = _firstFloor(json)['body_html'] as String;
      json.remove('special');
      expect(threadPageFromApi(json, 1).postList.single.data, body);
    });

    test('only the template html: attachments, tags, plugin blocks and the counter text stay', () {
      final reward = _special<RewardSpecial>('reward_resolved');
      final body = [
        '\n<div class="pcbs">HEADER<div class="rwd cl"><div class="rsld z"><cite>5</cite></div>',
        '<div class="rwdn"><table cellspacing="0" cellpadding="0"><tr><td class="t_f" id="postmessage_9">TEXT</td>',
        '</tr></table><p class="pns mtw"><button name="answer">x</button></p></div></div>',
        '<div class="pattl">ATTACH</div><div class="rwdbst">BEST</div><div class="ptg mbm mtn">TAGS</div>',
        'FOOTER</div>\n<div id="comment_9" class="cm"></div>',
      ].join();
      expect(
        bodyHtmlWithoutSpecialBlock(body, reward, pid: '9'),
        [
          '\n<div class="pcbs">HEADER<table cellspacing="0" cellpadding="0"><tr><td class="t_f" id="postmessage_9">',
          'TEXT</td></tr></table><div class="pattl">ATTACH</div><div class="ptg mbm mtn">TAGS</div>FOOTER</div>\n',
          '<div id="comment_9" class="cm"></div>',
        ].join(),
      );

      final trade = _special<TradeSpecial>('trade_author');
      final counter = [
        '<div class="pcbs"><table><tr><td class="t_f" id="postmessage_9">INTRO</td></tr></table>',
        '<div class="trdc xs1"><em>3</em></div><div class="xs1 cl"><div class="trdb">G</div></div>',
        '<div id="postmessage_9">COUNTER</div><div class="locked">LOCK</div></div>',
      ].join();
      expect(
        bodyHtmlWithoutSpecialBlock(counter, trade, pid: '9'),
        [
          '<div class="pcbs"><table><tr><td class="t_f" id="postmessage_9">INTRO</td></tr></table>',
          '<div id="postmessage_9">COUNTER</div><div class="locked">LOCK</div></div>',
        ].join(),
        reason: 'a counter text with words and a lock of a thread with goods stay',
      );
      // No `div.pcbs`: nothing to cut.
      expect(bodyHtmlWithoutSpecialBlock('<div class="t_fsz">x</div>', trade, pid: '9'), '<div class="t_fsz">x</div>');
    });
  });

  group('E. the requests', () {
    test('bounty: the form of the page posted for an eligible floor only', () {
      final page = _page('reward_open_author');
      final tid = _tid('reward_open_author');
      final request = page.postList[1].bestAnswerRequest!;
      expect(request.method, SpecialRequestMethod.post);
      expect(
        request.url,
        'https://www.tsdm39.com/forum.php?mod=misc&action=bestanswer&tid=$tid&pid=5801&from=&bestanswersubmit=yes',
      );
      expect(request.fields, {
        'formhash': 'f1f2f3f4',
        'optgroup': '',
        'operation': '',
        'listextra': 'page%3D1',
        'page': '1',
      });
      expect(request.viewerUid, 35);
      final reward = page.special! as RewardSpecial;
      expect(reward.bestAnswerRequest(5800), isNull, reason: 'the first floor');
      expect(reward.bestAnswerRequest(9999), isNull, reason: 'not on the page');
      expect(page.postList[2].bestAnswerRequest!.url, contains('&pid=5802&'));
    });

    test('activity: the application as the page ajaxposts it, the cancel as it posts it', () {
      final activity = _special<ActivitySpecial>('activity_open_member');
      final tid = _tid('activity_open_member');
      final apply = activity.applyRequest({
        'payment': '0',
        'payvalue': '',
        'qq': '654321',
        'bloodtype': 'B',
        '衣服尺寸': 'M',
        'message': 'hello',
        'formhash': 'evil',
        'other': 'ignored',
      })!;
      expect(apply.method, SpecialRequestMethod.post);
      expect(
        apply.url,
        'https://www.tsdm39.com/forum.php?mod=misc&action=activityapplies&fid=2&tid=$tid&pid=5824&inajax=1',
      );
      expect(apply.fields, {
        'formhash': 'f1f2f3f4',
        'handlekey': 'activityapplies',
        'activitysubmit': 'true',
        'payment': '0',
        'payvalue': '',
        'qq': '654321',
        'bloodtype': 'B',
        '衣服尺寸': 'M',
        'message': 'hello',
      });
      // A field left out is the prefilled value.
      expect(activity.applyRequest({})!.fields['payment'], '0');

      final cancel = _special<ActivitySpecial>('activity_applied').cancelRequest('有事')!;
      expect(cancel.url, 'https://www.tsdm39.com/forum.php?mod=misc&action=activityapplies&fid=2&tid=$tid&pid=5824');
      expect(cancel.fields, {'formhash': 'f1f2f3f4', 'activitycancel': 'true', 'message': '有事'});
      expect(activity.cancelRequest('x'), isNull, reason: 'did not apply');
      expect(_special<ActivitySpecial>('activity_applied').applyRequest({}), isNull, reason: 'applied already');
      expect(_special<ActivitySpecial>('activity_open_guest').applyRequest({}), isNull);
    });

    test('activity: check boxes as indexed fields; a field the app cannot draw sends the application to the web', () {
      final json = _json('activity_open_member');
      final apply = (json['special'] as Map<String, dynamic>)['apply'] as Map<String, dynamic>;
      (apply['inputs'] as List).add({
        'name': 'hobby',
        'title': '愛好',
        'type': 'checkbox',
        'required': 0,
        'value': 'a\nb',
        'choices': [
          {'value': 'a', 'label': 'A'},
          {'value': 'b', 'label': 'B'},
        ],
        'html': '',
      });
      final withBoxes = threadPageFromApi(json, 1).special! as ActivitySpecial;
      final fields = withBoxes.applyRequest({
        'hobby': ['a', 'b'],
      })!.fields;
      expect((fields['hobby[0]'], fields['hobby[1]'], fields.containsKey('hobby')), ('a', 'b', false));

      (apply['inputs'] as List).add({
        'name': 'birthday',
        'title': '生日',
        'type': 'birthday',
        'required': 1,
        'value': '',
      });
      final birthday = threadPageFromApi(json, 1).special! as ActivitySpecial;
      expect(birthday.applyNeedsWeb, isTrue);
      expect(birthday.applyRequest({}), isNull);
    });

    test('debate: the vote is a GET of the side, as the page ajaxmenu, without a form hash', () {
      final debate = _special<DebateSpecial>('debate_open_member');
      final tid = _tid('debate_open_member');
      final vote = debate.voteRequest(1)!;
      expect(vote.method, SpecialRequestMethod.get);
      expect(vote.url, 'https://www.tsdm39.com/forum.php?mod=misc&action=debatevote&tid=$tid&stand=1&inajax=1');
      expect(vote.fields, isEmpty);
      expect(debate.voteRequest(2)!.url, contains('&stand=2&'));
      expect(debate.voteRequest(0), isNull);
      expect(debate.voteRequest(3), isNull);
      expect(_special<DebateSpecial>('debate_voted').voteRequest(1), isNull, reason: 'voted already');
    });

    test('an action url of another host, page or action is never sent', () {
      Map<String, dynamic> reward(String template) => {
        'type': 'reward',
        'can_set_best': 1,
        'set_best': {
          'action_template': template,
          'method': 'POST',
          'fields': <String, dynamic>{},
          'pids': [5],
        },
      };
      for (final template in [
        'https://evil.example/forum.php?mod=misc&action=bestanswer&pid={pid}',
        'forum.php?mod=misc&action=delete&pid={pid}',
        'home.php?mod=misc&action=bestanswer&pid={pid}',
        'javascript:alert(1)//forum.php?mod=misc&action=bestanswer&pid={pid}',
        'https://user@www.tsdm39.com/forum.php?mod=misc&action=bestanswer&pid={pid}',
        'forum.php?mod=misc&action=bestanswer&pid=6',
      ]) {
        final special = ThreadSpecial.fromApi(reward(template), formHash: 'f1f2f3f4', viewerUid: 1)! as RewardSpecial;
        expect(special.bestAnswerRequest(5), isNull, reason: template);
      }
      final ok =
          ThreadSpecial.fromApi(
                reward('http://tsdm39.com/forum.php?mod=misc&action=bestanswer&pid={pid}'),
                formHash: 'f1f2f3f4',
                viewerUid: 1,
              )!
              as RewardSpecial;
      expect(ok.bestAnswerRequest(5)!.url, 'https://www.tsdm39.com/forum.php?mod=misc&action=bestanswer&pid=5');
      final noHash = ThreadSpecial.fromApi(reward('forum.php?mod=misc&action=bestanswer&pid={pid}'))! as RewardSpecial;
      expect(noHash.bestAnswerRequest(5), isNull, reason: 'no form hash');
    });

    test('the transport: a POST with the result parameter and the fields, a GET with it and the AJAX header', () async {
      getIt.registerSingleton<NetErrorSaver>(NetErrorSaver());
      addTearDown(getIt.reset);
      final adapter = _RecordingAdapter(_json('reward_bestanswer_action'));
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(dio.close);
      final repository = SpecialThreadRepository.network(
        NetClientProvider.buildNoCookie(dio: dio, cookie: CookieProvider.buildEmpty()),
      );
      final best = _page('reward_open_author').postList[1].bestAnswerRequest!;
      expect(await repository.submit(best), isA<SpecialActionDone>());
      expect(adapter.requests.single.method, 'POST');
      // The client adds its own desktop parameter after ours.
      expect(adapter.requests.single.uri.toString(), startsWith('${best.url}&tsdmapp=json'));
      expect(Uri.splitQueryString(adapter.bodies.single!), best.fields);

      final vote = _special<DebateSpecial>('debate_open_member').voteRequest(1)!;
      await repository.submit(vote);
      final get = adapter.requests.last;
      expect(get.method, 'GET');
      expect(get.uri.toString(), startsWith('${vote.url}&tsdmapp=json'));
      expect(get.headers['X-Requested-With'], 'XMLHttpRequest');
    });

    test('the poll: the same form, posted to the action of the block with inajax=1', () async {
      final poll = forumPollFromSpecial(_special('poll_single_before'), loggedIn: true);
      final sent = <(String, Map<String, String>)>[];
      final repo = PollRepository(
        getPage: (_) async => _json('poll_single_after_vote'),
        postForm: (url, body) async {
          sent.add((url, body));
          return _json('poll_vote_action');
        },
      );
      final result = await repo.vote(poll, {'261'});
      expect(sent.single.$1, poll.action);
      expect(sent.single.$1, endsWith('&pollsubmit=yes&quickforward=yes&inajax=1'));
      expect(sent.single.$2, {'formhash': 'f1f2f3f4', 'pollsubmit': 'true', 'pollanswers[0]': '261'});
      expect(
        (result?.kind, result?.succeeded, result?.messageKey),
        (TsdmAppWriteKind.redirect, true, 'thread_poll_succeed'),
      );
    });
  });

  group('F. the results', () {
    test('the forum results of the real actions are done, with their message', () {
      for (final (name, message) in [
        ('poll_vote_action', ''),
        ('activity_apply_action', '活动申请成功'),
        ('activity_cancel_action', '活动报名取消成功'),
        ('reward_bestanswer_action', '最佳答案设置成功'),
        ('debate_vote_action', '投票成功'),
      ]) {
        final outcome = specialActionOutcomeOf(_json(name));
        expect(outcome, isA<SpecialActionDone>(), reason: name);
        expect((outcome as SpecialActionDone).message, message, reason: name);
      }
    });

    test('a refusal says the forum words; the login prompt the app own; anything else tells nothing', () {
      final refused = specialActionOutcomeOf(_json('reward_bestanswer_refused_action'));
      expect(refused, isA<SpecialActionRefused>());
      expect((refused as SpecialActionRefused).message, '抱歉，您不能设置最佳答案');
      final login = specialActionOutcomeOf({
        ..._json('reward_bestanswer_refused_action'),
        'message': '',
        'login': 1,
        'alert': 'info',
      });
      expect((login as SpecialActionRefused).message, t.general.needLogin);
      final silent = specialActionOutcomeOf({..._json('reward_bestanswer_refused_action'), 'message': ''});
      expect((silent as SpecialActionRefused).message, t.specialThread.refused);
      // The forum's own answers (an older plugin), a page, nothing.
      expect(
        specialActionOutcomeOf(File('$_dir/write_v13_rate_ok.orig.txt').readAsStringSync()),
        isA<SpecialActionUnknown>(),
      );
      expect(specialActionOutcomeOf({..._json('poll_vote_action'), 'kind': 'page'}), isA<SpecialActionUnknown>());
      expect(specialActionOutcomeOf(null), isA<SpecialActionUnknown>());
    });

    test('a failed request tells nothing', () async {
      final repository = SpecialThreadRepository(send: (_) async => throw const HttpException('offline'));
      expect(
        await repository.submit(_special<DebateSpecial>('debate_open_member').voteRequest(1)!),
        isA<SpecialActionUnknown>(),
      );
    });

    group('the poll card', () {
      tearDown(PollCubit.forgetVotesSent);

      PollRepository repo({required Object? vote, List<String>? gets}) => PollRepository(
        getPage: (url) async {
          gets?.add(url);
          return _json('poll_single_after_vote');
        },
        postForm: (_, _) async => vote,
      );

      test('shows the block of the page; a vote the forum took reloads the thread page, no GET', () async {
        final gets = <String>[];
        var reloads = 0;
        final cubit = PollCubit(
          url: 'poll',
          currentUid: () => 35,
          repository: () => repo(vote: _json('poll_vote_action'), gets: gets),
          onVoted: () => reloads++,
        );
        addTearDown(cubit.close);
        expect(cubit.adoptSpecial(_special('poll_single_before')), isTrue);
        expect(cubit.state.poll!.availability, PollAvailability.available);
        cubit.select('261', selected: true);
        await cubit.submit();
        expect(reloads, 1);
        expect(gets, isEmpty);
        expect(cubit.awaitsReload, isTrue);
        expect(cubit.state.busy, isTrue, reason: 'waits for the page');
        // The page read before the vote shows the poll open: not shown again, the card asks.
        expect(cubit.adoptSpecial(_special('poll_single_before')), isFalse);
        expect(cubit.adoptSpecial(_special('poll_single_after_vote')), isTrue);
      });

      test('a refused vote shows the forum message and reads the poll again', () async {
        final gets = <String>[];
        var reloads = 0;
        final refused = {
          ..._json('poll_vote_action'),
          'ok': 0,
          'kind': 'message',
          'message': '该投票已经关闭或者过期',
          'message_key': 'poll_not_found',
          'alert': 'error',
        };
        final cubit = PollCubit(
          url: 'poll',
          currentUid: () => 35,
          repository: () => repo(vote: refused, gets: gets),
          onVoted: () => reloads++,
        );
        addTearDown(cubit.close);
        cubit
          ..adoptSpecial(_special('poll_single_before'))
          ..select('261', selected: true);
        await cubit.submit();
        expect(reloads, 0);
        expect(gets, ['poll']);
        expect(cubit.state.refusal, '该投票已经关闭或者过期');
        expect(cubit.state.submissionUnconfirmed, isFalse);
        expect(cubit.state.poll!.availability, PollAvailability.voted, reason: 'the poll as the forum has it');
        // Refused: the card shows the open poll again when the page says so.
        expect(cubit.adoptSpecial(_special('poll_single_before')), isTrue);
      });

      test('the poll of a structured answer: the block, or the account changed', () async {
        final poll = await repo(vote: null).fetch('poll', 35);
        expect(poll.availability, PollAvailability.voted);
        expect(poll.options.first.result, isNotNull);
        expect(() => repo(vote: null).fetch('poll', 70), throwsFormatException);
        // Before 2.8.0 the structured answer has no block: the first floor's form (it had no page to read the poll from:
        // the lean answer carries no document, and the card asked to log in).
        final before = jsonDecode(File('$_dir/thread_v3_poll.json').readAsStringSync()) as Map<String, dynamic>;
        final fromForm = await PollRepository(
          getPage: (_) async => before,
          postForm: (_, _) async => null,
        ).fetch('p', 35);
        expect(fromForm.availability, PollAvailability.available);
        expect(fromForm.options, hasLength(greaterThanOrEqualTo(2)));
        // Another account's page is not adopted.
        final cubit = PollCubit(url: 'poll', currentUid: () => 70, repository: () => repo(vote: null));
        addTearDown(cubit.close);
        expect(cubit.adoptSpecial(_special('poll_single_before')), isFalse);
        expect(cubit.adoptSpecial(_special('poll_multi_mod')), isTrue);
      });
    });
  });

  group('G. the cards', () {
    late AppDatabase db;
    late SettingsRepository settings;
    late SettingsBloc bloc;

    setUp(() async {
      await LocaleSettings.setLocale(AppLocale.zhTw);
      db = AppDatabase(NativeDatabase.memory());
      final storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
        );
      await settings.init();
      bloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    });
    tearDown(() async {
      await bloc.close();
      await getIt.reset();
      await settings.dispose();
      await db.close();
      await LocaleSettings.setLocale(AppLocale.en);
    });

    Future<void> pump(WidgetTester tester, Widget child, {SpecialThreadRepository? repository}) async {
      Widget app = MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );
      if (repository != null) {
        app = RepositoryProvider<SpecialThreadRepository>.value(value: repository, child: app);
      }
      await tester.pumpWidget(
        BlocProvider<SettingsBloc>.value(
          value: bloc,
          child: TranslationProvider(child: app),
        ),
      );
      await tester.pump();
    }

    Future<void> confirm(WidgetTester tester) async {
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.general.ok));
      await tester.pumpAndSettle();
    }

    testWidgets('bounty: price, resolved, the answer, a hidden excerpt; accepting an answer on its floor', (
      tester,
    ) async {
      await pump(tester, SpecialThreadCard(_special('reward_resolved'), pid: '5806'));
      final tr = t.specialThread.reward;
      expect(find.text(tr.title), findsOneWidget);
      expect(find.text(tr.resolved), findsOneWidget);
      expect(find.text(tr.price(price: 5, credit: '天使币')), findsOneWidget);
      expect(find.text('BEST_TEXT_222088 最佳答案的內文'), findsOneWidget);
      expect(find.text(tr.jumpToFloor), findsOneWidget);

      await pump(tester, SpecialThreadCard(_special('reward_resolved_hiddenreply_locked'), pid: '5809'));
      expect(find.text(tr.hiddenContent), findsOneWidget);
      expect(find.text(tr.hiddenLocked), findsOneWidget);
      await pump(tester, SpecialThreadCard(_special('reward_best_anonymous'), pid: '5821'));
      expect(find.text(tr.anonymous), findsOneWidget);
      await pump(tester, SpecialThreadCard(_special('reward_open_author'), pid: '5800'));
      expect(find.text(tr.unresolved), findsOneWidget);
      expect(find.text(tr.setBestHint), findsOneWidget);

      // The author accepts the answer of floor 2: asked first, the form sent, the page reloaded.
      final fake = _FakeSpecialRepository(_json('reward_bestanswer_action'));
      var reloads = 0;
      final request = _page('reward_open_author').postList[1].bestAnswerRequest!;
      await pump(tester, SpecialBestAnswerButton(request, onReload: () => reloads++), repository: fake.repository);
      await tester.tap(find.text(tr.setBest));
      await confirm(tester);
      expect(fake.sent, [request]);
      expect(reloads, 1);

      // Refused: the forum's words, no reload.
      final refusing = _FakeSpecialRepository(_json('reward_bestanswer_refused_action'));
      await pump(tester, SpecialBestAnswerButton(request, onReload: () => reloads++), repository: refusing.repository);
      await tester.tap(find.text(tr.setBest));
      await confirm(tester);
      expect(refusing.sent, hasLength(1));
      expect(reloads, 1);
    });

    testWidgets('activity: details, the applicants, applying with the forum form, cancelling', (tester) async {
      final tr = t.specialThread.activity;
      final fake = _FakeSpecialRepository(_json('activity_apply_action'));
      var reloads = 0;
      final activity = _special<ActivitySpecial>('activity_open_member');
      await pump(
        tester,
        SpecialThreadCard(activity, pid: '5824', onReload: () => reloads++),
        repository: fake.repository,
      );
      expect(find.text(tr.title), findsOneWidget);
      expect(find.text('PLACE_222088'), findsOneWidget);
      expect(find.text(tr.costValue(cost: 10)), findsOneWidget);
      expect(find.text(tr.appliedValue(count: 3, verified: 1, pending: 2)), findsOneWidget);
      expect(find.text(tr.accepted(count: 1)), findsOneWidget);
      expect(find.text('ag_mod'), findsOneWidget);
      expect(find.text(tr.waiting(count: 2)), findsOneWidget);
      expect(find.text(tr.manage), findsNothing);

      await tester.tap(find.text(tr.join));
      await tester.pumpAndSettle();
      expect(find.byType(SpecialFormDialog), findsOneWidget);
      final submit = find.widgetWithText(FilledButton, t.specialThread.submit);
      expect(tester.widget<FilledButton>(submit).onPressed, isNull, reason: 'QQ is required');
      await tester.enterText(find.widgetWithText(TextField, 'QQ *'), '654321');
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(fake.sent.single.fields['qq'], '654321');
      expect(fake.sent.single.fields['bloodtype'], '其它', reason: "the account's own value");
      expect(fake.sent.single.url, endsWith('&inajax=1'));
      expect(reloads, 1);

      // The applicant cancels.
      final cancelling = _FakeSpecialRepository(_json('activity_cancel_action'));
      await pump(
        tester,
        SpecialThreadCard(_special('activity_applied'), pid: '5824', onReload: () => reloads++),
        repository: cancelling.repository,
      );
      expect(find.text(tr.statusWaiting), findsOneWidget);
      await tester.tap(find.text(tr.cancel).first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '有事');
      await tester.tap(find.widgetWithText(FilledButton, tr.cancel));
      await tester.pumpAndSettle();
      expect(cancelling.sent.single.fields, {'formhash': 'f1f2f3f4', 'activitycancel': 'true', 'message': '有事'});
      expect(reloads, 2);

      // The author manages on the web page; closed and not enough credit say so; no action without a thread page.
      await pump(tester, SpecialThreadCard(_special('activity_author_sees_pending'), pid: '5824', onReload: () {}));
      expect(find.text(tr.manage), findsOneWidget);
      await pump(tester, SpecialThreadCard(_special('activity_closed'), pid: '5825', onReload: () {}));
      expect(find.text(tr.closed), findsOneWidget);
      expect(find.text(tr.join), findsNothing);
      await pump(tester, SpecialThreadCard(_special('activity_credit_not_enough'), pid: '5826', onReload: () {}));
      expect(find.text(tr.creditNotEnough(credit: '威望')), findsOneWidget);
      await pump(tester, SpecialThreadCard(activity, pid: '5824'));
      expect(find.text(tr.join), findsNothing);
    });

    testWidgets('debate: both sides, the verdict, voting asks first, a refusal stays in the card', (tester) async {
      final tr = t.specialThread.debate;
      await pump(tester, SpecialThreadCard(_special('debate_ended_result'), pid: '5831', onReload: () {}));
      expect(find.text(tr.winnerAffirm), findsOneWidget);
      expect(find.textContaining('正方勝 UMPIRE_222088'), findsOneWidget);
      expect(find.text('正方觀點 AFF_222088'), findsOneWidget);
      expect(find.text(tr.voteFor(side: tr.affirm)), findsNothing, reason: 'ended');

      final refusing = _FakeSpecialRepository({
        ..._json('debate_vote_action'),
        'ok': 0,
        'message': '您已经投过票了',
        'message_key': 'debate_poll_voted',
        'alert': 'error',
      });
      var reloads = 0;
      await pump(
        tester,
        SpecialThreadCard(_special('debate_open_member'), pid: '5827', onReload: () => reloads++),
        repository: refusing.repository,
      );
      expect(find.text(tr.votes(count: 1)), findsOneWidget);
      expect(find.textContaining(tr.umpire(name: 'ag_mod')), findsOneWidget, reason: 'beside the end time');
      await tester.tap(find.text(tr.voteFor(side: tr.nega)));
      await confirm(tester);
      expect(refusing.sent.single.url, contains('&stand=2&inajax=1'));
      expect(find.text('您已经投过票了'), findsOneWidget);
      expect(reloads, 0);

      final done = _FakeSpecialRepository(_json('debate_vote_action'));
      await pump(
        tester,
        SpecialThreadCard(_special('debate_open_member'), pid: '5827', onReload: () => reloads++),
        repository: done.repository,
      );
      await tester.tap(find.text(tr.voteFor(side: tr.affirm)));
      await confirm(tester);
      expect(done.sent.single.method, SpecialRequestMethod.get);
      expect(reloads, 1);

      await pump(tester, SpecialThreadCard(_special('debate_umpire_voted'), pid: '5827', onReload: () {}));
      expect(find.text(tr.umpireAction), findsOneWidget);
      expect(find.text(tr.voteFor(side: tr.affirm)), findsNothing, reason: 'voted already');
    });

    testWidgets('goods: the list, a deleted goods, managing for the author', (tester) async {
      final tr = t.specialThread.trade;
      // Without the pictures: the card would ask the (offline) forum for them.
      TradeSpecial withoutPictures(String name) {
        final json = _json(name);
        for (final goods in ((json['special'] as Map<String, dynamic>)['goods'] as List).cast<Map<String, dynamic>>()) {
          goods
            ..['thumb'] = ''
            ..['image'] = '';
        }
        return threadPageFromApi(json, 1).special! as TradeSpecial;
      }

      await pump(tester, SpecialThreadCard(withoutPictures('trade_author'), pid: '5795'));
      expect(find.text(tr.count(count: 3)), findsOneWidget);
      expect(find.text('商品一 222088'), findsOneWidget);
      expect(find.text(tr.removed), findsOneWidget);
      expect(find.textContaining(tr.remain(days: 3, hours: 5)), findsOneWidget);
      expect(find.textContaining(tr.ended), findsOneWidget);
      expect(find.text('${tr.price(price: '10')} + ${tr.credit(credit: 5, unit: '天使币')}'), findsOneWidget);
      expect(find.text(tr.manage), findsOneWidget);
      await pump(tester, SpecialThreadCard(withoutPictures('trade_guest'), pid: '5795'));
      expect(find.text(tr.manage), findsNothing);
      await pump(tester, SpecialThreadCard(_special('trade_authorid_filter'), pid: '5795'));
      expect(find.text(tr.noGoods), findsOneWidget);
    });

    testWidgets('poll: the poll card fed by the block, as for a page form', (tester) async {
      final cubit = PollCubit(
        url: 'poll',
        currentUid: () => 35,
        repository: () => PollRepository(
          getPage: (_) async => _json('poll_multi_hidden'),
          postForm: (_, _) async => null,
        ),
      );
      addTearDown(cubit.close);
      await pump(tester, PollCard('5789', controller: cubit));
      await tester.pumpAndSettle();
      expect(find.text(t.pollCard.title), findsOneWidget);
      expect(find.byType(CheckboxListTile), findsNWidgets(3));
      expect(find.textContaining('%'), findsNothing, reason: 'results after a vote');
      expect(find.text(t.specialThread.poll.overt), findsOneWidget);
    });

    testWidgets('the floor: the card in place of the forum html, the badges of a debate and a bounty', (tester) async {
      final debate = _page('debate_open_member').postList;
      await pump(tester, Column(children: [for (final p in debate) PostCard(_bare(p))]));
      expect(find.byType(SpecialThreadCard), findsOneWidget);
      final htmls = tester.widgetList<MunchedHtml>(find.byType(MunchedHtml)).map((e) => e.html).toList();
      expect(htmls.first, debate.first.data);
      expect(htmls.first, isNot(contains('class="ds"')));
      final tr = t.specialThread.debate;
      expect(find.text('${tr.affirm} · ${tr.standVotes(count: 2)}'), findsOneWidget);
      expect(find.text('${tr.nega} · ${tr.standVotes(count: 0)}'), findsOneWidget);
      expect(find.text(tr.neutral), findsOneWidget);
      // No thread page above: no vote.
      expect(find.text(tr.voteFor(side: tr.affirm)), findsNothing);

      await pump(tester, Column(children: [for (final p in _page('reward_resolved').postList) PostCard(_bare(p))]));
      expect(
        find.descendant(of: find.byType(SpecialFloorBadges), matching: find.text(t.specialThread.reward.badge)),
        findsOneWidget,
      );
      // Without a thread page the best answer cannot be set (nothing to reload).
      await pump(tester, Column(children: [for (final p in _page('reward_open_author').postList) PostCard(_bare(p))]));
      expect(find.text(t.specialThread.reward.setBest), findsNothing);
    });
  });

  test('the app expects plugin 2.8.0', () {
    expect(expectedTsdmAppVersion, '2.8.0');
  });
}

/// [post] without the images of its author (nothing to load in a widget test).
Post _bare(Post post) => post.copyWith(
  author: User(name: post.author.name, uid: post.author.uid, url: post.author.url),
  userBriefProfile: null,
  postMedals: null,
  badge: null,
  secondBadge: null,
  signature: null,
  pokemon: null,
  checkin: null,
);
