import 'package:tsdm_client/features/friend/models/models.dart';
import 'package:universal_html/parsing.dart';

/// `[@]name[/@]`, the mention format of the retired `amucallme_dzx` plugin that the bbcode editor still emits.
///
/// The name may contain brackets (`[TSDM]Alice`), so it runs up to the first `[/@]` on the line; only another `[@]`
/// ends it early so a literal unpaired `[@]` does not swallow the next chip.
final RegExp _legacyMentionRe = RegExp(r'\[@\]((?:(?!\[@\])[^\r\n])+?)\[/@\]');

/// Invisible mark (U+2063, INVISIBLE SEPARATOR) around a username picked in the `atplus` @ panel.
///
/// Since the forum's `atplus` plugin (2026-09), the server only turns `@` + mark + username + mark into a mention
/// (profile link and notice); a bare `@name` stays plain text, exactly like typing `@` in the web editor.
const atplusUserMark = '\u2063';

/// Rewrite editor mentions in [bbcode] to the format the forum turns into mentions.
///
/// Discuz! X5 shows `[@]name[/@]` as plain text. With the `atplus` plugin the server only recognizes
/// `@` + [atplusUserMark] + name + [atplusUserMark], the text its @ panel inserts; the bare `@name` of stock Discuz!
/// used before is left as plain text now. Every embed becomes the marked form, with a space appended unless
/// whitespace already follows (the panel inserts one as well).
String toOfficialMentions(String bbcode) => bbcode.replaceAllMapped(_legacyMentionRe, (m) {
  final name = m.group(1)!.trim();
  final followedByWhitespace = m.end < bbcode.length && bbcode[m.end].trim().isEmpty;
  final mention = '@$atplusUserMark$name$atplusUserMark';
  return followedByWhitespace ? mention : '$mention ';
});

/// Users in an answer of the `atplus` plugin (`plugin.php?id=atplus:search`), `null` when it is not one.
///
/// ```json
/// {"ok":1,"list":[{"uid":1000,"username":"Alice","avatar":"./data/avatar/000/00/10/00_avatar_small.jpg",
///   "group":"使者","friend":0}]}
/// ```
///
/// [key] is the list to read: `list` for a search, `recent` or `friends` for `op=init`. Entries without a uid or a
/// name are skipped; avatars are made absolute against [base].
List<Friend>? parseAtplusUsers(Object? json, String key, {required String base}) {
  if (json is! Map<String, dynamic> || json['ok'] != 1 && json['ok'] != true) {
    return null;
  }
  final list = json[key];
  if (list is! List) {
    return const [];
  }
  final users = <Friend>[];
  final seen = <String>{};
  for (final e in list) {
    if (e is! Map) {
      continue;
    }
    final uid = '${e['uid'] ?? ''}'.trim();
    final username = '${e['username'] ?? ''}'.trim();
    if (uid.isEmpty || username.isEmpty || !seen.add(uid)) {
      continue;
    }
    final avatar = '${e['avatar'] ?? ''}'.trim();
    final group = '${e['group'] ?? ''}'.trim();
    users.add(
      Friend(
        uid: uid,
        username: username,
        avatarUrl: avatar.isEmpty ? null : Uri.parse('$base/').resolve(avatar).toString(),
        groupName: group.isEmpty ? null : group,
      ),
    );
  }
  return users;
}

/// Usernames the current user may mention, from the official `misc.php?mod=getatuser&inajax=1`.
///
/// ```xml
/// <?xml version="1.0" encoding="utf-8"?>
/// <root><![CDATA[Alice,Bob]]></root>
/// ```
///
/// Returns an empty list when the response is not that document.
List<String> parseAtUserList(String xml) {
  final String text;
  try {
    final root = parseXmlDocument(xml).documentElement;
    if (root == null || root.localName != 'root') {
      return const [];
    }
    text = root.innerText;
  } on Exception {
    return const [];
  }
  return text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toSet().toList();
}
