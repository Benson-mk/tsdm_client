import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/homepage/models/models.dart';
import 'package:tsdm_client/instance.dart';

/// The modules of the guide index page (`forum.php?mod=guide&view=index`) from a structured guide answer [json]
/// (plugin 2.4.0, `schema: 7`, `guideApiAnswerOf`).
///
/// The same [GuideModule] list `parseGuideIndex` reads from the web page: `modules` in the page's order (最新热门,
/// 最新精华, 最新回复, 最新发表), each with its title, its `view` and the url of its full list (`more`, relative as the
/// page prints it), its rows as [GuideItem]s and, when it lists none, the sentence the page prints instead
/// (`empty`). A row is the shared row shape of the list pages: the title is the plain `subject`, the thread the one
/// the page links (a moved thread's target), the forum from `fid` and `forum` (none when the row names no forum),
/// `extra` the text on the right of the row (hot: "N人参与", new: the last reply as the page shows it), and the row
/// is highlighted when the forum set a title style (`style`), as the page's inline style on the title. The forum's
/// message (`ok` 0: the guide switched off) is an empty list, as the web page of the message parsed to one.
List<GuideModule> guideModulesFromApi(Map<String, dynamic> json) {
  if (json['ok'] != 1) {
    talker.info('guide index: the forum answered a message: ${json['message']}');
    return const [];
  }
  final modules = <GuideModule>[];
  for (final module in _list(json['modules'])) {
    final view = _text(module['view']);
    final more = _text(module['more']);
    if (view.isEmpty || more.isEmpty) {
      continue;
    }
    final items = _list(module['threads']).map(_item).nonNulls.toList();
    final empty = _text(module['empty']);
    modules.add(
      GuideModule(
        title: _text(module['title']),
        view: view,
        moreUrl: more.prependHost(),
        items: items,
        emptyMessage: items.isEmpty && empty.isNotEmpty ? empty : null,
      ),
    );
  }
  return modules;
}

GuideItem? _item(Map<String, dynamic> row) {
  final moved = _int(row['moved']);
  final groupTid = _int(row['grouptid']);
  final tid = moved > 0 ? moved : (groupTid > 0 ? groupTid : _int(row['tid']));
  final title = _text(row['subject']);
  if (tid <= 0 || title.isEmpty) {
    return null;
  }
  final fid = _int(row['fid']);
  final forumName = _text(row['forum']);
  final extra = _text(row['extra']).trim();
  final style = row['style'];
  final highlighted =
      style is Map<String, dynamic> &&
      (_int(style['bold']) == 1 ||
          _int(style['italic']) == 1 ||
          _int(style['underline']) == 1 ||
          _text(style['color']).isNotEmpty ||
          _text(style['bgcolor']).isNotEmpty);
  return GuideItem(
    tid: '$tid',
    title: title,
    url: '$baseUrl/forum.php?mod=viewthread&tid=$tid',
    fid: fid > 0 ? '$fid' : null,
    forumName: forumName.isEmpty ? null : forumName,
    extra: extra.isEmpty ? null : extra,
    highlighted: highlighted,
  );
}

int _int(Object? value) => switch (value) {
  final num n => n.toInt(),
  final String s => int.tryParse(s) ?? 0,
  _ => 0,
};

String _text(Object? value) => value is String ? value : '';

List<Map<String, dynamic>> _list(Object? value) =>
    value is List ? value.whereType<Map<String, dynamic>>().toList() : const [];
