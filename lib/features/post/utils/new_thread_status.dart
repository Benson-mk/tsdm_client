import 'package:tsdm_client/features/draft_box/models/draft_data.dart';
import 'package:tsdm_client/features/post/utils/draft_marker.dart';
import 'package:universal_html/html.dart' as uh;

/// Visibility of a just created thread as shown to its author.
enum NewThreadHeaderStatus {
  /// Normal header without any status label.
  visible,

  /// Header labelled as awaiting moderation (displayorder -2).
  moderating,

  /// Header labelled as draft (displayorder -4).
  draft,

  /// Anything else, including an unknown label, another thread or no header.
  unknown,
}

// Upstream default `moderating` labels; an unlisted label is treated as unknown, never as visible.
final _moderatingRe = RegExp(r'^(审核中|審核中|under review)$', caseSensitive: false);
final _decorationRe = RegExp(r'[\[\]()（）【】|]');

/// Text of a header label; only the "[copy link]" anchor back to thread [tid] and bracket decoration are ignored.
///
/// Other anchors count as status text: e.g. the author's hidden-thread marker is an anchor.
String _labelText(uh.Element element, String tid) {
  String collect(uh.Node node) => switch (node) {
    uh.Text() => node.text ?? '',
    uh.Element(localName: 'a') when threadTidOf(node.attributes['href']) == tid => '',
    uh.Element() => node.nodes.map(collect).join(),
    _ => '',
  };
  return element.nodes.map(collect).join().replaceAll(_decorationRe, ' ').trim().replaceAll(RegExp(r'\s+'), ' ');
}

/// The author's marker of a thread hidden below the report threshold (upstream `hiderecover` link).
bool _isHiddenMarker(uh.Element element) =>
    element.id == 'hiderecover' ||
    element.querySelector('#hiderecover') != null ||
    element
        .querySelectorAll('a[href]')
        .any((a) => draftForumUri(a.attributes['href'])?.queryParameters['action'] == 'hiderecover');

/// Classify the author's view of thread [tid] from its header only, never from subject or post text.
///
/// The author can read their own pending, ignored, hidden and draft threads, so a post list alone proves nothing.
NewThreadHeaderStatus classifyNewThreadHeader(uh.Document document, String tid) {
  final heading = document.querySelector('#postlist h1.ts');
  if (heading == null || heading.querySelector('#thread_subject') == null) return NewThreadHeaderStatus.unknown;
  final canonical = document.querySelector('head link[rel="canonical"]')?.attributes['href'];
  final firstPost = document.querySelector('#postlist div[id^="post_"]');
  // The canonical url may be rewritten (`thread-<tid>-1-1.html`); threadTidOf also rejects other sites.
  if (canonical != null ? threadTidOf(canonical) != tid : !isFirstThreadPost(firstPost, tid: tid)) {
    return NewThreadHeaderStatus.unknown;
  }
  if (isDraftThreadDocument(document)) return NewThreadHeaderStatus.draft;

  final next = heading.nextElementSibling;
  final sibling = next?.localName == 'span' ? next : null;
  final labels = [
    ...heading.children.where((e) => e.localName == 'span' && e.id != 'thread_subject'),
    ?sibling,
  ];
  var status = NewThreadHeaderStatus.visible;
  for (final label in labels) {
    if (_isHiddenMarker(label)) return NewThreadHeaderStatus.unknown;
    final text = _labelText(label, tid);
    if (text.isEmpty) continue;
    if (!_moderatingRe.hasMatch(text)) return NewThreadHeaderStatus.unknown;
    status = NewThreadHeaderStatus.moderating;
  }
  return status;
}

/// Tid of a same-origin `viewthread` link or rewritten thread url, if valid.
String? threadTidOf(String? url) {
  final uri = draftForumUri(url);
  if (uri == null) return null;
  final rewritten = RegExp(r'^/thread-([1-9]\d*)-\d+-\d+\.html$').firstMatch(uri.path)?.group(1);
  if (rewritten != null) return rewritten;
  if (uri.path != '/forum.php' || uri.queryParameters['mod'] != 'viewthread') return null;
  final tid = uri.queryParameters['tid'];
  return tid != null && RegExp(r'^[1-9]\d*$').hasMatch(tid) ? tid : null;
}

/// Whether an explicit success message says the new thread awaits moderation.
///
/// Matches the upstream English text and the Chinese wording used by the forum's moderation notices.
bool mentionsModeration(String text) =>
    text.contains('需要审核') || text.contains('需要審核') || text.toLowerCase().contains('requires moderation');
