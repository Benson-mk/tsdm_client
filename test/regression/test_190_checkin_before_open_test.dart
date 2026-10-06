/// Checkin before 1:00 was recorded as done (reported 2026-10-06): the app showed "checked in", never tried again and
/// the website had no checkin that day.
///
/// The forum takes checkins from 1:00 to 23:59. Before that the checkin page is titled
/// "您今天已经签到过了或者签到时间还未开始" (checked in today OR not open yet) and the app read "已经签到". The page's
/// service desk box says plainly whether the account checked in today; it decides now, and the ambiguous title alone
/// means "not open yet", which is not recorded, so the next attempt checks in.
library;

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/checkin/models/models.dart';
import 'package:tsdm_client/features/checkin/utils/do_checkin.dart';
import 'package:tsdm_client/features/checkin/utils/parse_checkin.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:universal_html/parsing.dart';

const _ambiguous = '您今天已经签到过了或者签到时间还未开始';

/// The checkin page as the forum renders it (2026-10-06, user and figures replaced). [title] is the page title the
/// page has instead of the checkin form, [desk] the status in the service desk box.
String _page({required String desk, String? title}) =>
    '''
<html><body><div id="um"><a href="home.php?mod=space&amp;uid=1000">user1</a></div>
<div id="ct_shell"><div class="mn">
${title == null ? '<form id="qiandao" method="post"><input type="hidden" name="formhash" value="XXXXXXXX" /></form>' : '<h1 class="mt">$title</h1>'}
<h1 class="mt">签到排行榜</h1>
</div>
<div class="um" id="qdmsgt">
<p><font color="#FF0000"><b>user1</b></font> , 您累计已签到: <b>1</b> 天</p>
<p>【<span class=gray>$desk</span>】</p>
<p>您上次签到时间:<font color="#ff00cc">2026-09-10 16:19</font> </p>
</div>
<p>本社区规定的签到时间是自1:00到23:59时止，请您自己把握好时间来签到，避免超过规定时间</p>
</div></body></html>''';

final class _Adapter implements HttpClientAdapter {
  _Adapter(this.responses);

  final List<String> responses;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (requests.length > responses.length) {
      fail('unexpected request: ${options.method} ${options.uri}');
    }
    return ResponseBody.fromString(
      responses[requests.length - 1],
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    getIt
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
  });

  tearDownAll(getIt.reset);

  Future<(CheckinResult, _Adapter)> checkin(List<String> responses) async {
    final adapter = _Adapter(responses);
    final net = NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter);
    return (await doCheckin(net, CheckinFeeling.happy, 'hi').run(), adapter);
  }

  group('service desk status', () {
    test('not checked in today', () {
      expect(parseCheckinDeskStatus(parseHtmlDocument(_page(title: _ambiguous, desk: '今天未签到'))), isFalse);
    });
    test('checked in today', () {
      expect(parseCheckinDeskStatus(parseHtmlDocument(_page(title: _ambiguous, desk: '今天已签到'))), isTrue);
    });
    test('a page without the box does not tell', () {
      expect(
        parseCheckinDeskStatus(parseHtmlDocument('<html><body><h1 class="mt">$_ambiguous</h1></body></html>')),
        isNull,
      );
    });
  });

  test('before 1:00: not open yet, not "already checked in", and nothing is posted', () async {
    final (result, adapter) = await checkin([_page(title: _ambiguous, desk: '今天未签到')]);
    expect(result, isA<CheckinResultEarlyInTime>());
    expect(adapter.requests, hasLength(1));
  });

  test('the same title on an account that did check in today is "already checked in"', () async {
    final (result, _) = await checkin([_page(title: _ambiguous, desk: '今天已签到')]);
    expect(result, isA<CheckinResultAlreadyChecked>());
  });

  test('the ambiguous title without the box is not taken for a checkin', () async {
    final (result, _) = await checkin([
      '<html><body><div id="um">user1</div><h1 class="mt">$_ambiguous</h1></body></html>',
    ]);
    expect(result, isA<CheckinResultEarlyInTime>());
  });

  test('an answer that only says "already checked in" still is', () async {
    final (result, _) = await checkin([
      '<html><body><div id="um">user1</div><h1 class="mt">您今天已经签到过了</h1></body></html>',
    ]);
    expect(result, isA<CheckinResultAlreadyChecked>());
  });

  test('in the open hours the form is posted as before', () async {
    const success =
        '<?xml version="1.0" encoding="utf-8"?>\n<root><![CDATA[<div class="c">恭喜你签到成功!获得随机奖励 天使币 10 .</div>]]></root>';
    final (result, adapter) = await checkin([_page(desk: '今天未签到'), success]);
    expect(result, isA<CheckinResultSuccess>());
    expect(adapter.requests.last.method, 'POST');
  });
}
