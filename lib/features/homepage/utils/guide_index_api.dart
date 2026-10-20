import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/homepage/models/models.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';

/// The modules of the guide index page (`forum.php?mod=guide&view=index`) from a structured guide answer [json]
/// (plugin 2.4.0, `schema: 7`, `guideApiAnswerOf`).
///
/// The same [GuideModule] list `parseGuideIndex` reads from the web page: `modules` in the page's order (最新热门,
/// 最新精华, 最新回复, 最新发表), each with its title, its `view` and the url of its full list (`more`, relative as the
/// page prints it), its rows as [GuideItem]s and, when it lists none, the sentence the page prints instead
/// (`empty`). A row is the shared row shape of the list pages, read as [NormalThread.fromApi] reads it: the title is
/// the plain `subject`, the thread the one the page links (a moved thread's target), the forum from `fid` and `forum`
/// (none when the row names no forum), `extra` the text on the right of the row (hot: "N人参与", new: the last reply
/// as the page shows it), and the row is highlighted when the forum set a title style (`style`), as the page's inline
/// style on the title; a row without a thread or a subject is dropped, as the page parser drops it
/// ([tsdmAppIsThreadRow]). The forum's message (`ok` 0: the guide switched off) is an empty list, as the web page of
/// the message parsed to one.
List<GuideModule> guideModulesFromApi(Map<String, dynamic> json) {
  if (json['ok'] != 1) {
    talker.info('guide index: the forum answered a message: ${json['message']}');
    return const [];
  }
  final modules = <GuideModule>[];
  for (final module in tsdmAppList(json['modules'])) {
    final view = tsdmAppText(module['view']);
    final more = tsdmAppText(module['more']);
    if (view.isEmpty || more.isEmpty) {
      continue;
    }
    final items = tsdmAppList(module['threads']).where(tsdmAppIsThreadRow).map(_item).toList();
    final empty = tsdmAppText(module['empty']);
    modules.add(
      GuideModule(
        title: tsdmAppText(module['title']),
        view: view,
        moreUrl: more.prependHost(),
        items: items,
        emptyMessage: items.isEmpty && empty.isNotEmpty ? empty : null,
      ),
    );
  }
  return modules;
}

GuideItem _item(Map<String, dynamic> row) {
  final fid = tsdmAppInt(row['fid']);
  final thread = NormalThread.fromApi(row, fid: fid, typePrefix: 0);
  final forumName = tsdmAppText(row['forum']);
  final extra = tsdmAppText(row['extra']).trim();
  final style = row['style'];
  final highlighted =
      style is Map<String, dynamic> &&
      (tsdmAppInt(style['bold']) == 1 ||
          tsdmAppInt(style['italic']) == 1 ||
          tsdmAppInt(style['underline']) == 1 ||
          tsdmAppText(style['color']).isNotEmpty ||
          tsdmAppText(style['bgcolor']).isNotEmpty);
  return GuideItem(
    tid: thread.threadID,
    title: thread.title,
    url: thread.url,
    fid: fid > 0 ? '$fid' : null,
    forumName: forumName.isEmpty ? null : forumName,
    extra: extra.isEmpty ? null : extra,
    highlighted: highlighted,
  );
}
