import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/editor/utils/mention.dart';
import 'package:tsdm_client/features/notification/utils/personal_message_sent.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/parsing.dart';

/// Where a stored reply landed: the id of the new post and the page it is on (server default order), when the
/// server told them in the success hook.
typedef PostedReply = ({String? pid, int? page});

/// Repository of reply.
final class ReplyRepository with LoggerMixin {
  /// Constructor.
  const ReplyRepository();

  /// Regexp to grep pmid wrapped in chat message send response.
  ///
  /// {'pmid':'${PMID}'}.
  // static final _messagePmidRe = RegExp(r"'pmid':'(?<pmid>\d+)'");

  /// Regexp to grep error message in chat message send response.
  ///
  /// errorhandle_pmsend('${ERR}', {});
  static final _messageErrorRe = RegExp(r"\('(?<err>.+)', \{\}\);\}");

  /// `succeedhandle_<handlekey>('<url>', '<message>', {...})`.
  ///
  /// Emitted by Discuz! `showmessage()` only when the reply was stored (a forward url exists), for both the plain
  /// success message and the "needs moderation" one, so it is a more reliable marker than one language string.
  static final _succeedHandleRe = RegExp(r"succeedhandle_\w*\('((?:[^'\\]|\\.)*)',\s*'((?:[^'\\]|\\.)*)'");

  /// `errorhandle_<handlekey>('<message>', {...})` carries the rejection reason.
  static final _errorHandleRe = RegExp(r"errorhandle_\w*\('((?:[^'\\]|\\.)*)'");

  /// Whether the reply response says the reply was stored.
  static bool _isReplyStored(String data) =>
      _succeedHandleRe.hasMatch(data) || data.contains('回复发布成功') || data.contains('回复需要审核');

  /// The message inside the success hook, if any.
  static String? _storedMessage(String data) => _succeedHandleRe.firstMatch(data)?.group(2)?.replaceAll(r"\'", "'");

  /// Where a stored reply landed, from the forward url inside the success hook
  /// (`forum.php?mod=viewthread&tid=…&pid=<new post>&page=<page>…`). Parts the server did not tell are null.
  static PostedReply postedReplyOf(String data) => postedReplyOfUrl(_succeedHandleRe.firstMatch(data)?.group(1) ?? '');

  /// Where a stored reply landed, from the forward [url] the forum goes on to (the success hook's, or the `url` of
  /// the app API's result). Parts the url does not tell are null.
  static PostedReply postedReplyOfUrl(String url) => (
    pid: RegExp(r'[?&]pid=(\d+)').firstMatch(url)?.group(1),
    page: int.tryParse(RegExp(r'[?&]page=(\d+)').firstMatch(url)?.group(1) ?? ''),
  );

  /// The reply result of the forum's app API (plugin 2.6.0, [tsdmAppWriteResultOf]) in the answer [data], null when
  /// the forum answered itself.
  ///
  /// Stored when the forum called the success hook (`handle`, `post_reply_succeed` or the "needs moderation" one),
  /// went on to the thread (`redirect`, a form the forum did not take as AJAX) or printed the success page
  /// (`message` with `alert_right`), as [_isReplyStored] tells from the forum's own answer; anything else (the
  /// error hook, a refusal page, the login prompt, a page) is rejected with the forum's message, or the text of the
  /// page when the result carries no message.
  static ({bool stored, String? reason, String url})? _replyResultOf(Object? data) {
    final result = tsdmAppWriteResultOf(data);
    if (result == null) {
      return null;
    }
    final stored = switch (result.kind) {
      TsdmAppWriteKind.handle || TsdmAppWriteKind.redirect => result.succeeded,
      TsdmAppWriteKind.message =>
        result.succeeded &&
            (result.alert == 'right' || result.message.contains('回复发布成功') || result.message.contains('回复需要审核')),
      TsdmAppWriteKind.page => false,
    };
    final reason = result.message.isNotEmpty ? result.message : _serverMessage(result.html);
    return (stored: stored, reason: stored ? null : reason, url: result.url);
  }

  /// Human readable reason from a Discuz! inajax `showmessage()` response, if any.
  static String? _serverMessage(String data) {
    final fromHandle = _errorHandleRe.firstMatch(data)?.group(1);
    if (fromHandle != null && fromHandle.isNotEmpty) {
      return fromHandle.replaceAll(r"\'", "'");
    }
    String? htmlData;
    try {
      htmlData = parseXmlDocument(data).documentElement?.nodes.firstOrNull?.text;
    } on Object catch (_) {
      // Not the AJAX fragment: a whole page (the xml parser throws a state error on one, not an exception).
      htmlData = null;
    }
    final doc = parseHtmlDocument(htmlData ?? data);
    doc.querySelectorAll('script').forEach((e) => e.remove());
    final text = (doc.querySelector('div.alert_error') ?? doc.querySelector('div#messagetext'))?.innerText.trim();
    return (text == null || text.isEmpty) ? null : text;
  }

  /// Response body as text no matter how Dio decoded it.
  static String _bodyText(Object? data) => data is String ? data : (data?.toString() ?? '');

  /// Reply to a post.
  AsyncEither<PostedReply> replyToPost({
    required ReplyParameters replyParameters,
    required String replyAction,
    required String replyMessage,
  }) => AsyncEither(() async {
    final netClient = getIt.get<NetClientProvider>();
    final replyWindowUrl = withTsdmAppJsonWrite('${replyAction.prependHost()}$replyPostWindowSuffix');
    final respEither = await netClient.get(replyWindowUrl).run();
    if (respEither.isLeft()) {
      return left(respEither.unwrapErr());
    }

    final replyWindowResp = respEither.unwrap();
    if (replyWindowResp.statusCode != HttpStatus.ok) {
      return left(HttpRequestFailedException(replyWindowResp.statusCode));
    }

    // The response is an ajax xml document with the html form wrapped in CDATA.
    //
    // Expected hidden inputs in the form:
    //
    // * formhash
    // * handlekey
    // * noticeauthor
    // * noticetrimstr
    // * noticeauthormsg
    // * usesig
    // * reppid
    // * reppost
    //
    // Note that `replyuid` is NOT in the form on Discuz X5, it is only a query parameter in the reply action url.
    // The forum's app API (plugin 2.6.0) answers the window as a `page` result with the form in its document; the
    // forum refuses in the window (not logged in…) with the error hook, which has no form either.
    final windowResult = tsdmAppWriteResultOf(replyWindowResp.data);
    final rawData = windowResult?.html ?? _bodyText(replyWindowResp.data);
    String? htmlData;
    if (windowResult == null) {
      try {
        htmlData = parseXmlDocument(rawData).documentElement?.nodes.firstOrNull?.text;
      } on Object catch (_) {
        htmlData = null;
      }
    }
    final replyWindowDoc = windowResult?.document ?? parseHtmlDocument(htmlData ?? rawData);
    String? inputValue(String name) => replyWindowDoc.querySelector('input[name="$name"]')?.attributes['value'];
    final formHash = inputValue('formhash');
    final handleKey = inputValue('handlekey');
    final noticeAuthor = inputValue('noticeauthor');
    final noticeTrimStr = inputValue('noticetrimstr');
    final noticeAuthorMsg = inputValue('noticeauthormsg');
    final replyUid = inputValue('replyuid') ?? replyAction.tryParseAsUri()?.queryParameters['replyuid'];
    final repPid = inputValue('reppid');
    final repPost = inputValue('reppost');
    final useSig = inputValue('usesig');
    final subject = inputValue('subject');
    if (formHash == null || handleKey == null || repPid == null || repPost == null) {
      final errorText = windowResult?.message ?? replyWindowDoc.querySelector('div.alert_error')?.innerText.trim();
      error(
        'failed to fetch reply to post parameters: formHash=$formHash, '
        'handleKey=$handleKey, noticeAuthor=$noticeAuthor, error=$errorText',
      );
      error(
        'failed to fetch reply to post parameters: '
        'noticeAuthorMsg=$noticeAuthorMsg, replyuid=$replyUid, '
        'reppid=$repPid, reppost=$repPost',
      );
      return left(ReplyToPostFetchParameterFailedException());
    }

    final formData = <String, String>{
      'formhash': formHash,
      'handlekey': handleKey,
      'noticeauthor': ?noticeAuthor,
      'noticetrimstr': ?noticeTrimStr,
      'noticeauthormsg': ?noticeAuthorMsg,
      'replyuid': ?replyUid,
      'reppid': repPid,
      'reppost': repPost,
      'usesig': useSig ?? '1',
      // TODO: Build subject instead of const empty string.
      'subject': subject ?? '',
      // TODO: Support reply with rich text.
      'message': toOfficialMentions(replyMessage),
    };

    final respEither2 = await netClient
        .postForm(formatReplyPostUrl(replyParameters.fid, replyParameters.tid), data: formData)
        .run();

    if (respEither2.isLeft()) {
      return left(respEither2.unwrapErr());
    }

    final resp2 = respEither2.unwrap();
    if (_replyResultOf(resp2.data) case final result?) {
      if (!result.stored) {
        error('reply to post rejected by server: ${result.reason}');
        return left(ReplyToPostResultFailedException(result.reason));
      }
      info('reply to post stored (app api)');
      return right(postedReplyOfUrl(result.url));
    }
    final data2 = _bodyText(resp2.data);
    if (!_isReplyStored(data2)) {
      final reason = _serverMessage(data2);
      error('reply to post rejected by server: $reason');
      return left(ReplyToPostResultFailedException(reason));
    }
    info('reply to post stored: ${_storedMessage(data2)?.length ?? 0} chars');

    return right(postedReplyOf(data2));
  });

  /// Post reply to thread tid/fid.
  /// This will add a post in thread, as reply to that thread.
  ///
  /// # Exception
  ///
  /// * **HttpRequestFailedException** when http request failed.
  /// * **ReplyToThreadResultFailedException** when reply finished but no
  /// successful result found in response, carrying the server's reason.
  AsyncEither<PostedReply> replyToThread({required ReplyParameters replyParameters, required String replyMessage}) =>
      AsyncEither(() async {
        final formData = <String, String>{
          'message': toOfficialMentions(replyMessage),
          'usesig': '1',
          'formhash': replyParameters.formHash,
          'subject': replyParameters.subject,
        };
        // Only apply post time when not null.
        if (replyParameters.postTime != null) {
          formData['posttime'] = replyParameters.postTime.toString();
        }
        final respEither = await getIt
            .get<NetClientProvider>()
            .postForm(formatReplyThreadUrl(replyParameters.fid, replyParameters.tid), data: formData)
            .run();
        if (respEither.isLeft()) {
          return left(respEither.unwrapErr());
        }

        final resp = respEither.unwrap();
        if (resp.statusCode != HttpStatus.ok) {
          return left(HttpRequestFailedException(resp.statusCode));
        }
        if (_replyResultOf(resp.data) case final result?) {
          if (!result.stored) {
            error('reply to thread rejected by server: ${result.reason}');
            return left(ReplyToThreadResultFailedException(result.reason));
          }
          info('reply to thread stored (app api)');
          return right(postedReplyOfUrl(result.url));
        }
        final data = _bodyText(resp.data);
        if (!_isReplyStored(data)) {
          final reason = _serverMessage(data);
          error('reply to thread rejected by server: $reason');
          return left(ReplyToThreadResultFailedException(reason));
        }
        info('reply to thread stored: ${_storedMessage(data)?.length ?? 0} chars');
        return right(postedReplyOf(data));
      });

  /// Reply personalMessage in history page.
  AsyncVoidEither replyHistoryPersonalMessage({
    required String targetUrl,
    required String formHash,
    required String message,
  }) => _reportSent(() async {
    final formData = <String, String>{'message': toOfficialMentions(message), 'formhash': formHash};

    final e = await getIt.get<NetClientProvider>().postForm(targetUrl, data: formData).run();
    if (e.isLeft()) {
      return left(e.unwrapErr());
    }
    final resp = e.unwrap();
    if (resp.statusCode != HttpStatus.ok) {
      throw HttpRequestFailedException(resp.statusCode);
    }

    if (_messageResultOf(resp.data) case final result?) {
      return result;
    }
    final data = _bodyText(resp.data);

    if (data.contains('succeedhandle_pmsend')) {
      // Success.
      // return _messagePmidRe.firstMatch(data)?.namedGroup('pmid');
      return rightVoid();
    }
    if (data.contains('errorhandle_pmsend')) {
      final errorMessage = _messageErrorRe.firstMatch(data)?.namedGroup('err');
      return left(ReplyPersonalMessageFailedException(errorMessage ?? 'unknown error'));
    }
    return rightVoid();
  });

  /// Reply a personal message, use as we are chatting though the chat dialog
  /// when we in browser, this means in chat page, not chat history page.
  ///
  /// # Exception
  ///
  /// * **HttpRequestFailedException** when http request failed.
  /// * **ReplyPersonalMessageFailedException** when reply failed.
  ///
  /// # Return
  ///
  /// Return the pmid if send message succeed which is used to show the new
  /// generated message.
  AsyncVoidEither replyPersonalMessage(String touid, Map<String, String> formData) => _reportSent(() async {
    final e = await getIt.get<NetClientProvider>().postForm(formatSendMessageUrl(touid), data: formData).run();
    if (e.isLeft()) {
      return left(e.unwrapErr());
    }

    final resp = e.unwrap();

    if (resp.statusCode != HttpStatus.ok) {
      throw HttpRequestFailedException(resp.statusCode);
    }

    if (_messageResultOf(resp.data) case final result?) {
      return result;
    }
    final data = _bodyText(resp.data);

    if (data.contains('succeedhandle_pmsend')) {
      // Success.
      // return _messagePmidRe.firstMatch(data)?.namedGroup('pmid');
      return rightVoid();
    }
    if (data.contains('errorhandle_showmsg_$touid')) {
      final errorMessage = _messageErrorRe.firstMatch(data)?.namedGroup('err');
      return left(ReplyPersonalMessageFailedException(errorMessage ?? 'unknown error'));
    }

    return rightVoid();
  });

  /// The outcome of a sent private message told by the forum's app API (plugin 2.6.0, [tsdmAppWriteResultOf]) in
  /// the answer [data], null when the forum answered itself: sent when the forum called the success hook
  /// (`succeedhandle_pmsend`, `handle` with `do_success`), failed with the forum's message on the error hook or a
  /// refusal page. As with the forum's own answer, an answer that is neither (a page) counts as sent.
  static Either<AppException, void>? _messageResultOf(Object? data) {
    final result = tsdmAppWriteResultOf(data);
    if (result == null) {
      return null;
    }
    if (result.kind == TsdmAppWriteKind.page || result.succeeded) {
      return rightVoid();
    }
    return left(ReplyPersonalMessageFailedException(result.message.isEmpty ? 'unknown error' : result.message));
  }

  /// Run the private message [send] and tell [PersonalMessageSent] when the forum accepted it: the conversation list
  /// of the account that sent is refreshed for it (GitHub #193).
  ///
  /// The account is the one of the global cookie the request carries, read before sending: the refresh must not run
  /// for an account switched to meanwhile.
  static AsyncVoidEither _reportSent(Future<Either<AppException, void>> Function() send) => AsyncVoidEither(() async {
    final sender = getIt.isRegistered<CookieProvider>() ? getIt.get<CookieProvider>().userLoginInfo.uid : null;
    final result = await send();
    if (result.isRight()) {
      PersonalMessageSent.notify(sender);
    }
    return result;
  });
}
