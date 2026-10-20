import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/red_packet/models/models.dart';
import 'package:tsdm_client/features/red_packet/utils/parse_red_packet.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;

/// Find only the forum's own checknewpm script, never execute arbitrary page JavaScript.
///
/// Discuz uses this request for both its unread-PM check and the `daylogin` credit rule (#111).
Uri? dailyVisitUri(uh.Document document) {
  for (final script in document.querySelectorAll('script[src]')) {
    final uri = dailyVisitUriOfSource(script.attributes['src'] ?? '');
    if (uri != null) {
      return uri;
    }
  }
  return null;
}

/// The forum's own checknewpm request named by [source] (the `src` of a script of the page, or the `checknewpm` of
/// an answer of the forum's app API, plugin 2.3.0, which names it since the script is in no lean answer's
/// `document`), resolved against the forum; null for anything else: another host, another page, a parameter the
/// forum's script never carries. Only that request is ever made, with the cookies of the account.
Uri? dailyVisitUriOfSource(String source) {
  final base = Uri.parse(baseUrl);
  final parsed = Uri.tryParse(source.trim());
  if (parsed == null || source.trim().isEmpty) return null;
  final uri = base.resolveUri(parsed);
  final params = uri.queryParametersAll;
  if (uri.scheme != base.scheme ||
      uri.origin != base.origin ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      uri.path != '/home.php') {
    return null;
  }
  if (params.values.any((v) => v.length != 1) ||
      params.keys.any((k) => !{'mod', 'ac', 'op', 'rand'}.contains(k)) ||
      uri.queryParameters['mod'] != 'spacecp' ||
      uri.queryParameters['ac'] != 'pm' ||
      uri.queryParameters['op'] != 'checknewpm') {
    return null;
  }
  return uri;
}

/// Foreground homepage rewards, scoped to the identity that fetched the page.
///
/// The server decides eligibility and amounts. A restart checks its fresh page again; it never invents credits
/// or persists a failed claim as success. Local state only deduplicates concurrent/rapid requests in this session.
final class DailyRewardsRepository with LoggerMixin {
  /// [now] is used for short retry throttles, not to decide the forum's reward day.
  DailyRewardsRepository({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final _pending = <int, Future<bool>>{};
  final _visitAttempts = <int, DateTime>{};
  final _packetAttempts = <int, (String, DateTime)>{};
  final _claimedDays = <int, String>{};

  bool _recent(DateTime? previous) =>
      previous != null && _now().difference(previous).abs() < const Duration(minutes: 1);

  /// Return whether the homepage should be fetched once more to update balances/claim availability.
  ///
  /// [processFields] with what the web page [document] carries: the account it was served to, the forum's
  /// `checknewpm` script ([dailyVisitUri]), today's red packet and the form hash.
  Future<bool> process({
    required uh.Document document,
    required int? uid,
    required bool Function() isCurrent,
    required bool Function() autoClaimEnabled,
    required Future<bool> Function(Uri) visit,
    required Future<DailyRedPacketResult?> Function(String formHash) claim,
  }) => processFields(
    servedUid: parseLoggedUidFromDocument(document),
    visitUri: dailyVisitUri(document),
    packet: parseDailyRedPacketConfig(document),
    formHash: parseFormHash(document),
    uid: uid,
    isCurrent: isCurrent,
    autoClaimEnabled: autoClaimEnabled,
    visit: visit,
    claim: claim,
  );

  /// [process] for the fields of a homepage however it was answered: served to [servedUid] (null for a guest),
  /// with the forum's `checknewpm` request [visitUri] (the script of the web page, the `checknewpm` of an answer
  /// of the forum's app API since plugin 2.3.0; null when the page names none), today's red packet [packet] (null
  /// when none or claimed) and the form hash [formHash] to claim it with.
  Future<bool> processFields({
    required int? servedUid,
    required Uri? visitUri,
    required DailyRedPacketConfig? packet,
    required String? formHash,
    required int? uid,
    required bool Function() isCurrent,
    required bool Function() autoClaimEnabled,
    required Future<bool> Function(Uri) visit,
    required Future<DailyRedPacketResult?> Function(String formHash) claim,
  }) async {
    if (uid == null || uid <= 0 || !isCurrent() || servedUid != uid) return false;
    if (_pending[uid] case final pending?) return pending;
    final pending = _process(
      visitUri: visitUri,
      packet: packet,
      formHash: formHash,
      uid: uid,
      isCurrent: isCurrent,
      autoClaimEnabled: autoClaimEnabled,
      visit: visit,
      claim: claim,
    );
    _pending[uid] = pending;
    try {
      return await pending;
    } finally {
      _pending.removeWhere((key, _) => key == uid);
    }
  }

  Future<bool> _process({
    required Uri? visitUri,
    required DailyRedPacketConfig? packet,
    required String? formHash,
    required int uid,
    required bool Function() isCurrent,
    required bool Function() autoClaimEnabled,
    required Future<bool> Function(Uri) visit,
    required Future<DailyRedPacketResult?> Function(String formHash) claim,
  }) async {
    var refresh = false;
    if (visitUri != null && !_recent(_visitAttempts[uid]) && isCurrent()) {
      _visitAttempts[uid] = _now();
      try {
        refresh = await visit(visitUri);
      } on Object {
        warning('daily visit check failed; keep the homepage available');
      }
    }

    final previous = _packetAttempts[uid];
    if (packet != null &&
        RegExp(r'^\d{8}$').hasMatch(packet.dateFlag) &&
        formHash != null &&
        _claimedDays[uid] != packet.dateFlag &&
        !(previous?.$1 == packet.dateFlag && _recent(previous?.$2)) &&
        isCurrent() &&
        autoClaimEnabled()) {
      _packetAttempts[uid] = (packet.dateFlag, _now());
      try {
        final result = await claim(formHash);
        if (isCurrent() && result != null && (result.ok || result.already)) {
          _claimedDays[uid] = packet.dateFlag;
          refresh = true;
        }
      } on Object {
        warning('automatic daily red packet failed; manual claim remains available');
      }
    }
    return isCurrent() && refresh;
  }
}
