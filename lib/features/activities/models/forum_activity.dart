import 'dart:convert';

import 'package:tsdm_client/constants/url.dart';
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
  final heading = document.querySelectorAll('h2 a').where((a) {
    final title = a.text?.trim();
    return title == '活动专区' || title == '活動專區';
  }).firstOrNull;
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

/// [parseForumActivities] for the homepage answered by the forum's app API as structured fields (plugin 2.3.0,
/// `schema: 5`): the description of 活动专区 is the `description` of that forum among the categories (the html the
/// page prints in its `p.xg2`), read with the same rules by putting it where the page has it. Empty when the forum
/// is not listed or has no description.
List<ForumActivity> parseForumActivitiesFromApi(Map<String, dynamic> json) {
  final categories = json['categories'];
  if (categories is! List) return const [];
  for (final category in categories.whereType<Map<String, dynamic>>()) {
    final forums = category['forums'];
    if (forums is! List) continue;
    for (final forum in forums.whereType<Map<String, dynamic>>()) {
      final name = forum['name'];
      if (name is! String || (name.trim() != '活动专区' && name.trim() != '活動專區')) continue;
      final description = forum['description'];
      if (description is! String || description.trim().isEmpty) return const [];
      return parseForumActivities(
        parseHtmlDocument(
          '<html><body><div><h2><a>${htmlEscape.convert(name.trim())}</a></h2><p class="xg2">$description</p></div> '
          '</body></html>',
        ),
      );
    }
  }
  return const [];
}
