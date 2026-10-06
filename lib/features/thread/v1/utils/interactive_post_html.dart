import 'package:html/dom.dart';
import 'package:html/parser.dart';

final _interactiveMarkup = RegExp(
  r'<(?:style|svg|canvas|script|form|input|select|textarea|button|iframe)\b|\son[a-z]+\s*=',
  caseSensitive: false,
);
final _leadingCell = RegExp(r'^\s*<(?:td|th)(?:\s|>)', caseSensitive: false);
final _leadingRow = RegExp(r'^\s*<tr(?:\s|>)', caseSensitive: false);

/// Handlers of well known Discuz helpers on images and links, with any arguments.
final _nativeHandler = RegExp(
  r'^\s*(?:return\s+)?(?:zoom|showWindow|showMenu|hideMenu|showTip|hideTip|atarget|attachimg|thumbImg|img_onmouseoverfunc)'
  r'\s*\([^;{}]*\)\s*;?\s*(?:return\s+(?:false|true)\s*;?\s*)?$',
  caseSensitive: false,
);

/// A handler that is one plain call of a function, optionally returning its result or a boolean afterwards. Matched
/// against the value with its string literals emptied, so the arguments cannot hide statements.
final _singleCall = RegExp(
  r'^\s*(?:return\s+)?([A-Za-z_$][\w$]*)\s*\(([^;{}()]*)\)\s*;?\s*(?:return\s+(?:false|true)\s*;?\s*)?$',
);
final _callee = RegExp(r'^\s*(?:return\s+)?([A-Za-z_$][\w$]*)\s*\(');
final _stringLiteral = RegExp(r'''"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`''');

/// An assignment or increment inside the arguments is authored behaviour, a comparison is not.
final _argumentWrite = RegExp(r'(?<![=!<>])=(?!=)|\+\+|--');

/// Functions a post may define in its own scripts: declarations, assigned function expressions or arrows, variables
/// and globals assigned on `window`.
final _definedFunction = RegExp(
  r'\bfunction\s*\*?\s*([A-Za-z_$][\w$]*)'
  r'|([A-Za-z_$][\w$]*)\s*=\s*(?:async\s+)?(?:function\b|\([^()]*\)\s*=>|[A-Za-z_$][\w$]*\s*=>)'
  r'|\b(?:var|let|const)\s+([A-Za-z_$][\w$]*)\s*='
  r'|\b(?:window|self|globalThis)\.([A-Za-z_$][\w$]*)\s*=(?!=)',
);

/// Browser functions are never forum helpers: a handler calling them does something the native reader does not.
const _browserActions = {'alert', 'confirm', 'prompt', 'eval', 'open', 'print', 'fetch', 'setTimeout', 'setInterval'};

final _nativeNeteasePlayer = RegExp(r'//music\.163\.com/outchain/player\?.*id=\d+.*');
final _nativePollIdentity = RegExp(r'''^\s*(?:var\s+)?discuz_uid\s*=\s*['"]\d+['"]\s*;?\s*$''');

/// The forum puts this at the start of every message it may reload after a reply (#165).
final _nativeReplyReload = RegExp(r'''^\s*replyreload\s*\+=\s*['"],['"]\s*\+\s*\d+\s*;?\s*$''');

/// The authored message HTML when it needs the interactive viewer, otherwise null.
///
/// A post's data can also contain the forum's poll, rating and red packet interfaces. Prefer the exact message id,
/// then a single legacy message with a different id. Ambiguous message boundaries are not exported. Bare fragments
/// are accepted for nonstandard markup. Detection does not sanitize the returned HTML: source spans preserve the
/// message's scripts, styles, whitespace and entities, and a bare fragment is returned exactly as supplied.
String? interactivePostHtml(String data, {required String postId}) {
  // Ordinary text and formatting do not need a second DOM parse alongside the native reader.
  if (!_interactiveMarkup.hasMatch(data)) {
    return null;
  }
  // A standalone table cell needs its normal parent context or the HTML parser discards its message wrapper.
  final container = _leadingCell.hasMatch(data) ? 'tr' : (_leadingRow.hasMatch(data) ? 'tbody' : 'div');
  final fragment = parseFragment(data, container: container, generateSpans: true);
  final messages = fragment.querySelectorAll('[id^="postmessage_"]');
  final exact = messages.where((element) => element.id == 'postmessage_$postId').toList();
  if (exact.length > 1) {
    return null;
  }
  final fallback = messages.where((element) => element.classes.contains('t_f')).toList();
  final Element? message;
  if (exact.isNotEmpty) {
    message = exact.single;
  } else if (fallback.length == 1) {
    message = fallback.single;
  } else if (messages.isNotEmpty) {
    return null;
  } else {
    message = null;
  }

  if (message == null) {
    return _containsInteractiveContent(fragment, bareFragment: true) ? data : null;
  }
  final start = message.sourceSpan?.end.offset;
  final end = message.endSourceSpan?.start.offset;
  if (start == null || end == null || end < start || end > data.length) {
    return null;
  }
  return _containsInteractiveContent(message) ? data.substring(start, end) : null;
}

bool _containsInteractiveContent(Node root, {bool bareFragment = false}) {
  final elements = switch (root) {
    Element() => root.querySelectorAll('*'),
    DocumentFragment() => root.querySelectorAll('*'),
    _ => const <Element>[],
  };
  final hasNativePoll = bareFragment && elements.any((element) => element.localName == 'form' && element.id == 'poll');
  final defined = _definedFunctions(elements);
  for (final element in elements) {
    if (_isNativeControl(element, root)) {
      continue;
    }
    final tag = element.localName;
    if (tag == 'script' && hasNativePoll && _nativePollIdentity.hasMatch(element.text)) {
      continue;
    }
    if (tag == 'script' && _nativeReplyReload.hasMatch(element.text)) {
      continue;
    }
    if (const {'style', 'svg', 'canvas', 'script', 'form', 'select', 'textarea', 'button'}.contains(tag)) {
      return true;
    }
    if (tag == 'input' && element.attributes['type']?.toLowerCase() != 'hidden') {
      return true;
    }
    if (tag == 'iframe' && !_nativeNeteasePlayer.hasMatch(element.attributes['src'] ?? '')) {
      return true;
    }
    for (final attribute in element.attributes.entries) {
      if (attribute.key is! String || !(attribute.key as String).toLowerCase().startsWith('on')) {
        continue;
      }
      if (attribute.value.trim().isEmpty) {
        continue;
      }
      // Images and links already have native tap handlers. A custom handler still counts.
      if ((tag == 'img' || tag == 'a') && _isNativeHandler(element, attribute.value, defined)) {
        continue;
      }
      return true;
    }
  }
  return false;
}

/// Names of the functions the post's own scripts define.
Set<String> _definedFunctions(Iterable<Element> elements) => {
  for (final script in elements.where((element) => element.localName == 'script'))
    for (final match in _definedFunction.allMatches(script.text))
      match.group(1) ?? match.group(2) ?? match.group(3) ?? match.group(4)!,
};

/// Whether the handler [value] on an image or link is forum markup rather than something the author wrote.
///
/// Instead of listing every Discuz helper, a handler is native when it is a single plain call of a function the post
/// does not define itself: the forum's helpers live in the forum's scripts, which a post does not carry. A call of a
/// function defined by the post, more than one statement, an assignment, a browser function, or a link whose only
/// action is the handler (no real `href`) is authored.
bool _isNativeHandler(Element element, String value, Set<String> defined) {
  final callee = _callee.firstMatch(value)?.group(1);
  if (callee == null || defined.contains(callee)) {
    return false;
  }
  if (_nativeHandler.hasMatch(value)) {
    return true;
  }
  final call = _singleCall.firstMatch(value.replaceAll(_stringLiteral, '""'));
  if (call == null || _browserActions.contains(callee) || _argumentWrite.hasMatch(call.group(2)!)) {
    return false;
  }
  if (element.localName == 'a') {
    final href = element.attributes['href']?.trim().toLowerCase() ?? '';
    if (href.isEmpty || href.startsWith('#') || href.startsWith('javascript:')) {
      return false;
    }
  }
  return true;
}

bool _isNativeControl(Element element, Node root) {
  if (element.classes.contains('spoilerbutton') || element.classes.contains('spoiler_btn')) {
    return true;
  }
  for (Element? current = element; current != null && current != root; current = current.parent) {
    final tag = current.localName;
    if (tag == 'code' || tag == 'pre' || current.classes.contains('blockcode')) {
      return true;
    }
    if ((tag == 'form' && current.id == 'poll') ||
        current.classes.contains('hb-entry') ||
        current.id == 'hb_mask' ||
        (tag == 'dl' && current.id.startsWith('ratelog_'))) {
      return true;
    }
  }
  return false;
}
