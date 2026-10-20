import 'package:collection/collection.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/profile/models/managed_forum.dart';
import 'package:tsdm_client/features/profile/models/models.dart';
import 'package:tsdm_client/features/profile/models/profile_medal.dart';
import 'package:tsdm_client/features/profile/utils/parse_profile.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// The QQ number in the `<a href="//wpa.qq.com/msgrd?v=3&uin=…">` the forum prints for the QQ field.
final RegExp _qqRe = RegExp(r'uin=(?<qq>\d+)');

/// The birthday the forum prints: `2000 年 10 月 11 日`, any part missing, `-` when none.
final RegExp _birthdayRe = RegExp(r'((?<y>\d+) 年)? ?((?<m>\d+) 月)? ?((?<d>\d+) 日)?');

/// A profile page as the repository fetched it: the web page (or an older plugin's answer, rebuilt as one), or the
/// structured answer of the forum's app API (plugin 2.2.0, `schema: 4`).
///
/// The callers read the page through [buildProfilePage], [unreadInfoOf] and [secondaryTitleUrlOf], which take the
/// path the page needs, so that the web page is parsed as it always was and the structured answer is never parsed
/// from a `document`.
sealed class ProfilePage {
  const ProfilePage();

  /// The avatar of the profile owner, null when the page has none (a message, a guest page).
  String? get avatarUrl;

  /// Whether the page was served to a logged in account (a guest's page means the session expired).
  bool get loggedIn;
}

/// The web page of the profile (or an older plugin's answer, whose `document` is the page), parsed as before.
final class ProfileWebPage extends ProfilePage {
  /// Constructor.
  const ProfileWebPage(this.document);

  /// The page.
  final uh.Document document;

  @override
  String? get avatarUrl => parseProfileAvatarUrl(document);

  @override
  bool get loggedIn => isLoggedInDocument(document);
}

/// The structured answer of the forum's app API ([profileApiAnswerOf]): the profile, or the forum's message.
final class ProfileApiPage extends ProfilePage {
  /// Constructor.
  const ProfileApiPage(this.json);

  /// The answer.
  final Map<String, dynamic> json;

  @override
  String? get avatarUrl {
    final avatar = _text(_map(json['user'])['avatar']);
    return json['ok'] == 1 && avatar.isNotEmpty ? avatar : null;
  }

  /// The profile is served to the account `uid` names; a message answer names no account, and only the login prompt
  /// (`login` 1) is a guest's.
  @override
  bool get loggedIn => json['ok'] == 1 ? _int(json['uid']) > 0 : json['login'] != 1;
}

/// The structured profile page answer in [data]: a JSON answer of the forum's app API that carries every field the
/// app reads (plugin 2.2.0, `type: profile` with `schema` 4 or later), or the forum's own message of such a plugin
/// (please log in, no such user, no permission: `ok` 0, `error: message`, with `login` telling a guest apart). Null
/// when the answer has to be read from its `document` as before: a web page, another page's answer, an older plugin's
/// answer (no `schema`, no `login`), a failed build.
///
/// The page is then built by [profileFromApi]; the `document` of the answer, when there is one, is never parsed.
Map<String, dynamic>? profileApiAnswerOf(Object? data) {
  final json = tsdmAppAnswerJson(data);
  if (json == null) {
    return null;
  }
  final schema = json['schema'];
  final structured = schema is num && schema >= 4;
  if (json['ok'] == 1) {
    return structured && json['type'] == 'profile' ? json : null;
  }
  if (json['ok'] == 0 && json['error'] == 'message' && (structured || json['login'] is int)) {
    return json;
  }
  return null;
}

/// Build the [UserProfile] of [page]: the web page through [buildProfile] as before, the structured answer through
/// [profileFromApi].
TaskEither<AppException, UserProfile> buildProfilePage(ProfilePage page) => switch (page) {
  ProfileWebPage(:final document) => buildProfile(document),
  ProfileApiPage(:final json) => TaskEither.fromEither(profileFromApi(json)),
};

/// The unread notice count and the unread message flag the page header shows: [buildUnreadInfoStatus] of the web
/// page, `unread` of the structured answer (none on a message answer).
(int unreadNoticeCount, bool hasUnreadMessage) unreadInfoOf(ProfilePage page) => switch (page) {
  ProfileWebPage(:final document) => buildUnreadInfoStatus(document),
  ProfileApiPage(:final json) => () {
    final unread = _map(json['unread']);
    return (_int(unread['notice']), _int(unread['pm']) > 0);
  }(),
};

/// The secondary title image of the profile owner ([parseProfileSecondaryTitleUrl]): from the web page, or from the
/// `profile_html` of the structured answer, where the blocks other plugins add to the profile stay as html
/// ([profileHtmlDocumentOf]).
String? secondaryTitleUrlOf(ProfilePage page) => switch (page) {
  ProfileWebPage(:final document) => parseProfileSecondaryTitleUrl(document),
  ProfileApiPage(:final json) => parseProfileSecondaryTitleUrl(profileHtmlDocumentOf(json)),
};

/// The profile block of a structured answer [json] as a document: `profile_html` is the inner html of the page's
/// `div.bm_c.u_profile`, put back where the page has it (inside `div#ct`), so that the parsers of the blocks other
/// plugins add to the profile (the title badges, the medal center rows, the block-user notes) read it as the page.
/// An empty document for a message answer.
uh.Document profileHtmlDocumentOf(Map<String, dynamic> json) => parseHtmlDocument(
  '<html><head></head><body><div id="wp" class="wp"><div id="ct"><div class="bm_c u_profile">'
  '${_text(json['profile_html'])}'
  '</div></div></div></body></html>',
);

/// Build the user profile from a structured answer [json] of the forum's app API ([profileApiAnswerOf]).
///
/// The same [UserProfile] the web page gives through [buildProfile], from the fields instead of the html, so that the
/// page renders it unchanged:
///
/// * `user` is the owner: name, uid, avatar, online, the email state (the forum has no video verification: null as on
///   the page), the custom title and the signature html, in the one-cell table the page prints it in (empty ones are
///   absent, as the page prints no row for them);
/// * `stats.friends` with the uid is the friends row: the model keeps the `统计信息` fragment the page prints (the
///   `好友数 N` anchor to the friends page), composed here so `parseFriendsInfo` reads it as before;
/// * `profiles` are the rows the forum prints after its privacy filter, matched by id first (`birthday`,
///   `constellation`, `msn`, `bio`, `field1` for the nickname, `gender`, `residecity`, `qq`), by title second (the
///   page's `生日`, `星座`, `MSN`, `自我介绍`, `昵称`, `性别`, `来自`/`居住地`, `QQ`); a row the forum does not print is
///   null; the QQ number is read from the `uin=` of the value as from the page;
/// * `medals` are the forum's medals ([ProfileMedal.fromApi]); `manage_forums` the moderated forums (null when none,
///   as the page prints no block then);
/// * `checkin` is the check-in plugin's block, each field the text the page prints (`[LV.1]初来乍到`, the last check-in
///   as `yyyy-MM-dd HH:mm` in the forum's time, `今天未签到`/`今天已签到`); null (no plugin, or its block switched off)
///   leaves every check-in field null, as a page without the block; no day and no remaining day are null, as before;
/// * `groups.admin` and `groups.member` are the two group rows: the model keeps the html fragment of the row, composed
///   here as the page prints it (the colored name linked to the group, the group icon when it has one), so the group
///   section reads it as before;
/// * `activity` gives the online hours (`N 小时`, null when 0: the page hides the row), the four times as the forum's
///   wall clock (`timeoffset` hours from the unix seconds, null when 0) in naive [DateTime]s, exactly what the old
///   parser reads from the page, so that the page shows the same as the web (and as the check-in line) whatever the
///   device's zone: the page prints them as absolute times, and reading them as the real instants they are is deferred
///   until the whole app's time handling is fixed; the IPs (empty when the viewer may not see them: null, as a page
///   without the rows) and the time zone text;
/// * `stats.credits` and `stats.extcredits` are the statistics rows, matched by title as the page's rows are, each
///   value with its unit as the page prints it (`5 枚`), the unknown ones as the special attributes in the forum's
///   order.
///
/// The forum's message (`ok` 0): the login prompt of a guest (`login` 1) is [ProfileNeedLoginException], any other
/// (no such user, no permission) [ServerRespondedErrorException] with the message, as the page's `#messagetext p`.
Either<AppException, UserProfile> profileFromApi(Map<String, dynamic> json) {
  if (json['ok'] != 1) {
    if (json['login'] == 1) {
      return Either.left(ProfileNeedLoginException());
    }
    return Either.left(ServerRespondedErrorException(_text(json['message'])));
  }

  final user = _map(json['user']);
  final stats = _map(json['stats']);
  final groups = _map(json['groups']);
  final activity = _map(json['activity']);
  final uid = _int(user['uid']);
  final timeOffset = json['timeoffset'] is num ? json['timeoffset'] as num : 8;

  ///////////  Basic status ///////////

  final customTitle = _text(user['customstatus']);
  // The page prints the signature in a one-cell table (`<table><tr><td>$sightml</td></tr></table>`) and the old parser
  // keeps that table; the same wrapper here, so the signature renders as before.
  final sightml = _text(user['signature_html']);
  final signature = sightml.isEmpty ? '' : '<table><tbody><tr><td>$sightml</td></tr></tbody></table>';
  final friendsLink = 'home.php?mod=space&amp;uid=$uid&amp;do=friend&amp;view=me&amp;from=space';
  final friendsCount = '<a href="$friendsLink" target="_blank">好友数 ${_int(stats['friends'])}</a>';

  ///////////  Some other basic status ///////////

  // The rows the forum prints, by id and by title.
  final byId = <String, String>{};
  final byTitle = <String, String>{};
  for (final row in _list(json['profiles'])) {
    final id = _text(row['id']);
    final title = _text(row['title']);
    final value = _text(row['value']);
    if (id.isNotEmpty) {
      byId.putIfAbsent(id, () => value);
    }
    if (title.isNotEmpty) {
      byTitle.putIfAbsent(title, () => value);
    }
  }
  String? field(String id, List<String> titles) {
    final value = byId[id] ?? titles.map((t) => byTitle[t]).whereType<String>().firstOrNull;
    return value == null || value.trim().isEmpty ? null : value.trim();
  }

  String? birthdayYear;
  String? birthdayMonth;
  String? birthdayDay;
  final birthday = field('birthday', ['生日']);
  if (birthday != null) {
    final match = _birthdayRe.firstMatch(birthday);
    if (match != null) {
      birthdayYear = match.namedGroup('y');
      birthdayMonth = match.namedGroup('m');
      birthdayDay = match.namedGroup('d');
    }
  }
  final qqField = field('qq', ['QQ']);
  final qq = qqField == null ? null : _qqRe.firstMatch(qqField)?.namedGroup('qq') ?? qqField;

  final profileMedals = _list(json['medals']).map(ProfileMedal.fromApi).toList();
  final managedForums = _list(
    json['manage_forums'],
  ).map((e) => ManagedForum(name: _text(e['name']), fid: _int(e['fid']))).where((e) => e.fid > 0).toList();

  ///////////  Checkin status ///////////

  int? checkinDaysCount;
  String? checkinThisMonthCount;
  String? checkinRecentTime;
  String? checkinAllCoins;
  String? checkinLastTimeCoin;
  String? checkinLevel;
  String? checkinNextLevel;
  int? checkinNextLevelDays;
  String? checkinTodayStatus;
  if (json['checkin'] is Map<String, dynamic>) {
    final checkin = _map(json['checkin']);
    final days = _int(checkin['days']);
    checkinDaysCount = days == 0 ? null : days;
    checkinThisMonthCount = '${_int(checkin['mdays'])}';
    checkinRecentTime = _forumTime(checkin['last'], timeOffset);
    checkinAllCoins = '${_int(checkin['reward'])}';
    checkinLastTimeCoin = '${_int(checkin['lastreward'])}';
    if (checkin['level'] is Map<String, dynamic>) {
      final level = _map(checkin['level']);
      checkinLevel = '[${_text(level['code'])}]${_text(level['name'])}';
      final next = _text(level['next']);
      checkinNextLevel = next.isEmpty ? null : '[$next]${_text(level['next_name'])}';
      final remain = _int(level['remain']);
      checkinNextLevelDays = remain == 0 ? null : remain;
    }
    checkinTodayStatus = _int(checkin['today']) == 1 ? '今天已签到' : '今天未签到';
  }

  ///////////  User group status ///////////

  final moderatorGroup = groups['admin'] is Map<String, dynamic> ? _groupFragment(_map(groups['admin'])) : null;
  final userGroup = groups['member'] is Map<String, dynamic> ? _groupFragment(_map(groups['member'])) : null;

  ///////////  Activity status ///////////

  final registerIP = _text(activity['regip']);
  final lastVisitIP = _text(activity['lastip']);
  final timezone = _text(activity['timezone_text']);

  ///////////  Statistics status ///////////

  String? famous;
  String? coins;
  String? publicity;
  String? natural;
  String? scheming;
  String? spirit;
  String? specialAttr;
  String? specialAttrName;
  String? specialAttr2;
  String? specialAttrName2;
  for (final row in _list(stats['extcredits'])) {
    final title = _text(row['title']).trim();
    final unit = _text(row['unit']).trim();
    final number = _number(row['value']);
    final value = number == null ? null : (unit.isEmpty ? number : '$number $unit');
    switch (title) {
      case '威望':
        famous = value;
      case '天使币':
        coins = value;
      case '宣传':
        publicity = value;
      case '天然':
        natural = value;
      case '腹黑':
        scheming = value;
      case '精灵':
        spirit = value;
      case '':
      case '已用空间':
        break;
      default:
        if (specialAttr == null) {
          specialAttr = value;
          specialAttrName = title.replaceFirst(':', '');
        } else {
          specialAttr2 = value;
          specialAttrName2 = title.replaceFirst(':', '');
        }
    }
  }

  return Either.right(
    UserProfile(
      avatarUrl: _text(user['avatar']).isEmpty ? null : _text(user['avatar']),
      username: _text(user['username']).isEmpty ? null : _text(user['username']),
      uid: uid > 0 ? '$uid' : null,
      emailVerified: _int(user['email_verified']) == 1,
      videoVerified: null,
      customTitle: customTitle.isEmpty ? null : customTitle,
      signature: signature.isEmpty ? null : signature,
      friendsCount: friendsCount,
      online: _int(user['online']) == 1,
      birthdayYear: birthdayYear,
      birthdayMonth: birthdayMonth,
      birthdayDay: birthdayDay,
      zodiac: field('constellation', ['星座']),
      msn: field('msn', ['MSN']),
      introduction: field('bio', ['自我介绍']),
      nickname: field('field1', ['昵称']),
      gender: field('gender', ['性别']),
      from: field('residecity', ['来自', '居住地']),
      qq: qq,
      profileMedals: profileMedals,
      mangedForums: managedForums.isEmpty ? null : managedForums,
      checkinDaysCount: checkinDaysCount,
      checkinThisMonthCount: checkinThisMonthCount,
      checkinRecentTime: checkinRecentTime,
      checkinAllCoins: checkinAllCoins,
      checkinLastTimeCoin: checkinLastTimeCoin,
      checkinLevel: checkinLevel,
      checkinNextLevel: checkinNextLevel,
      checkinNextLevelDays: checkinNextLevelDays,
      checkinTodayStatus: checkinTodayStatus,
      moderatorGroup: moderatorGroup,
      userGroup: userGroup,
      onlineTime: _int(activity['oltime']) > 0 ? '${_int(activity['oltime'])} 小时' : null,
      registerTime: _wallClock(activity['regdate'], timeOffset),
      lastVisitTime: _wallClock(activity['lastvisit'], timeOffset),
      lastActiveTime: _wallClock(activity['lastactivity'], timeOffset),
      registerIP: registerIP.isEmpty ? null : registerIP,
      lastVisitIP: lastVisitIP.isEmpty ? null : lastVisitIP,
      lastPostTime: _wallClock(activity['lastpost'], timeOffset),
      timezone: timezone.isEmpty ? null : timezone,
      credits: _number(stats['credits']),
      famous: famous,
      coins: coins,
      publicity: publicity,
      natural: natural,
      scheming: scheming,
      spirit: spirit,
      specialAttr: specialAttr,
      specialAttrName: specialAttrName,
      specialAttr2: specialAttr2,
      specialAttrName2: specialAttrName2,
    ),
  );
}

/// The html fragment of a group row, as the page prints it and the group section reads it: the name in its color,
/// linked to the group page, then the group icon as the last element when the group has one (the section shows a
/// group only through its icon, as on the page).
String _groupFragment(Map<String, dynamic> group) {
  final title = _text(group['title']);
  final color = _text(group['color']);
  final icon = _text(group['icon']);
  final link = '$baseUrl/home.php?mod=spacecp&amp;ac=usergroup&amp;gid=${_int(group['gid'])}';
  final name = '<font color="$color"><a href="$link" target="_blank">${_escape(title)}</a></font>';
  return icon.isEmpty ? name : '$name <img src="$icon" alt="${_escape(title)}" />';
}

String _escape(String text) =>
    text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

/// The forum's wall clock of a time of the answer (unix seconds, `timeoffset` hours), to the minute as the page
/// prints it, as a naive [DateTime] (the device's zone, the forum's clock values): what the old parser reads from the
/// page. Null when missing or 0.
///
/// Not the real instant: the page shows these as absolute times (`yyyyMMDDHHMM`), so the instant would differ from
/// the web page and from the check-in line on a device outside the forum's zone. Reading them as instants waits for
/// the app's time handling as a whole.
DateTime? _wallClock(Object? value, num timeOffset) {
  final seconds = _int(value);
  if (seconds <= 0) {
    return null;
  }
  final t = DateTime.fromMillisecondsSinceEpoch(
    seconds * 1000,
    isUtc: true,
  ).add(Duration(milliseconds: (timeOffset * 3600 * 1000).round()));
  return DateTime(t.year, t.month, t.day, t.hour, t.minute);
}

/// A time of the answer as the forum prints it, `yyyy-MM-dd HH:mm` in the forum's time ([_wallClock]); null when
/// missing or 0.
String? _forumTime(Object? value, num timeOffset) {
  final t = _wallClock(value, timeOffset);
  if (t == null) {
    return null;
  }
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// A number of the answer as the page prints it (`5`, `-7694`, `1.5`), null when missing.
String? _number(Object? value) => switch (value) {
  final int n => '$n',
  final double d => d == d.truncateToDouble() ? '${d.toInt()}' : '$d',
  final String s when s.trim().isNotEmpty => s.trim(),
  _ => null,
};

int _int(Object? value) => switch (value) {
  final num n => n.toInt(),
  final String s => int.tryParse(s) ?? 0,
  _ => 0,
};

String _text(Object? value) => value is String ? value : '';

Map<String, dynamic> _map(Object? value) => value is Map<String, dynamic> ? value : const {};

List<Map<String, dynamic>> _list(Object? value) =>
    value is List ? value.whereType<Map<String, dynamic>>().toList() : const [];
