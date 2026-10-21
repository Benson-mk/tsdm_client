import 'dart:convert';

import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// An activity link published in the forum homepage description.
final class ForumActivity {
  /// Constructor.
  const ForumActivity({required this.title, required this.url});

  /// The forum's original title.
  final String title;

  /// Absolute HTTP(S) destination, dispatched through the existing app router.
  final String url;
}

/// Parse only the description of 活动专区, excluding its subforums and moderators.
///
/// The live X5 HTML nests a paragraph inside `p.xg2`. HTML parsing closes the
/// outer paragraph automatically, so traverse siblings up to the next ordinary
/// paragraph rather than assuming all links are descendants of `.xg2`.
List<ForumActivity> parseForumActivities(uh.Document document) {
  final heading = document
      .querySelectorAll('h2 a')
      .where((a) => _activityForumNames.contains(a.text?.trim()))
      .firstOrNull;
  final container = heading?.parent?.parent;
  if (container == null) return const [];
  final description = container.querySelector('p.xg2');
  if (description == null) return const [];
  final nodes = <uh.Element>[description];
  var next = description.nextElementSibling;
  while (next != null && (next.getAttribute('align') == 'center' || next.tagName.toLowerCase() != 'p')) {
    nodes.add(next);
    next = next.nextElementSibling;
  }
  final links = <ForumActivity>[];
  for (final node in nodes) {
    for (final anchor in node.querySelectorAll('a[href]')) {
      final title = anchor.text?.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
      final href = anchor.getAttribute('href')?.trim() ?? '';
      final target = Uri.tryParse(href);
      if (title.isEmpty || href.isEmpty || target == null) continue;
      final uri = Uri.parse(homePage).resolveUri(target);
      if (!['https', 'http'].contains(uri.scheme)) continue;
      if (uri.host.isEmpty || uri.userInfo.isNotEmpty) continue;
      links.add(ForumActivity(title: title, url: uri.toString()));
    }
  }
  return List.unmodifiable(links);
}

/// The names 活动专区 goes by on the page.
const _activityForumNames = {'活动专区', '活動專區'};

/// The forum 活动专区 among the categories of a structured homepage answer [json], null when it is not listed.
Map<String, dynamic>? _activityForumOf(Map<String, dynamic> json) {
  final categories = json['categories'];
  if (categories is! List) {
    return null;
  }
  for (final category in categories.whereType<Map<String, dynamic>>()) {
    final forums = category['forums'];
    if (forums is! List) {
      continue;
    }
    for (final forum in forums.whereType<Map<String, dynamic>>()) {
      final name = forum['name'];
      if (name is String && _activityForumNames.contains(name.trim())) {
        return forum;
      }
    }
  }
  return null;
}

/// [parseForumActivities] for the homepage answered by the forum's app API as structured fields (plugin 2.3.0,
/// `schema: 5`).
///
/// * Plugin 2.8.2 gives the description of 活动专区 as the page prints it in its `p.xg2` (`description_html`): it is
///   read with the same rules by putting it where the page has it.
/// * Before, the forum's `description` is plain text, without the links. The answer asked with its `document` (see
///   [activitiesNeedDocument]) is read as the web page.
///
/// Empty when the forum is not listed or has no description, and for a lean answer of an older plugin.
List<ForumActivity> parseForumActivitiesFromApi(Map<String, dynamic> json) {
  final forum = _activityForumOf(json);
  final description = forum?['description_html'];
  if (forum != null && description is String) {
    final name = (forum['name'] as String).trim();
    if (description.trim().isEmpty) {
      return const [];
    }
    return parseForumActivities(
      parseHtmlDocument(
        '<html><body><div><h2><a>${htmlEscape.convert(name)}</a></h2><p class="xg2">$description</p></div> '
        '</body></html>',
      ),
    );
  }
  if (json['document'] is String) {
    return parseForumActivities(tsdmAppPageDocument(json));
  }
  return const [];
}

/// Whether the activity links of a structured homepage answer [json] are only on the web page: 活动专区 is listed
/// without `description_html` (plugins 2.3.0 to 2.8.1 give its description as plain text) and the answer was asked
/// lean (`nodoc=1`, no `document`). The activities page then asks the page once more with its document
/// (`ForumHomeRepository.fetchPageDocument`). No such request for an answer of plugin 2.8.2, one without the forum,
/// or the forum's message.
bool activitiesNeedDocument(Map<String, dynamic> json) {
  if (json['ok'] != 1 || json['document'] is String) {
    return false;
  }
  final forum = _activityForumOf(json);
  return forum != null && !forum.containsKey('description_html');
}
