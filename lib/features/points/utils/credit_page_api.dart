import 'package:tsdm_client/features/points/models/models.dart';
import 'package:tsdm_client/features/points/repository/model/models.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';

/// The structured credit log answer in [data]: a JSON answer of the forum's app API that carries the credit log page
/// (`home.php?mod=spacecp&ac=credit&op=log`, with its filters and pages) as fields (plugin 2.5.0, `type: credit`,
/// `schema` 12 or later), or the forum's own message of such a plugin (a guest: `ok` 0, `error: message`, with
/// `login` telling the two apart). Null when the answer has to be read from its `document` as before: a web page,
/// an older plugin's answer (no `schema`, no `login`), a failed build, and the other credit pages (`op=base`, the
/// system reward log), which the plugin keeps answering as `type: credit` without a `schema`.
///
/// The log is then built by [pointsChangelogFromApi]; the `document` of the answer, when there is one, is never
/// parsed.
Map<String, dynamic>? creditApiAnswerOf(Object? data) {
  final json = tsdmAppAnswerJson(data);
  if (json == null) {
    return null;
  }
  final schema = json['schema'];
  final structured = schema is num && schema >= 12;
  if (json['ok'] == 1) {
    return structured && json['type'] == 'credit' ? json : null;
  }
  if (json['ok'] == 0 && json['error'] == 'message' && (structured || json['login'] is int)) {
    return json;
  }
  return null;
}

/// One page of the credit log built from a structured answer: the changes of the page, the pagination the forum
/// printed and the filters of its query form.
typedef PointsChangelogPage = ({
  List<PointsChange> changes,
  int currentPage,
  int totalPages,
  ChangelogAllParameters allParameters,
});

/// The label of the choice that filters by no operation, as the forum's query form prints its first option
/// (`<option value="">请选择操作类型</option>`): the plugin lists the operation codes only, and the app's query form
/// offers (and starts on) the first choice of the list.
const creditLogAnyOperationName = '请选择操作类型';

/// The credit log of a structured answer [json] ([creditApiAnswerOf]): the rows of the page as [PointsChange.fromApi]
/// builds them (a row without an operation or a time dropped, as the page parser drops a malformed row; the forum
/// skips a record without any change, so a page may hold fewer than 20), the pagination the forum printed (`page`,
/// `pages`) and the filters of the query form ([changelogParametersFromApi]). The forum's message (`ok` 0: a guest)
/// is null, as the message page parsed to (no table on it).
PointsChangelogPage? pointsChangelogFromApi(Map<String, dynamic> json) {
  if (json['ok'] != 1) {
    talker.error('failed to build points changelog: the forum answered a message: ${json['message']}');
    return null;
  }
  final changes = tsdmAppList(json['logs']).map(PointsChange.fromApi).nonNulls.toList();
  final page = tsdmAppInt(json['page']);
  final pages = tsdmAppInt(json['pages']);
  final currentPage = page > 0 ? page : 1;
  return (
    changes: changes,
    currentPage: currentPage,
    totalPages: pages > 0 ? pages : currentPage,
    allParameters: changelogParametersFromApi(json),
  );
}

/// The filters of the query form of a structured answer [json] (`filters`: the credits, `exttype`; the direction,
/// `income`; the operations, `optype`), the same [ChangelogAllParameters] the web page gives through
/// `parseAllParameters` (its three `<select>`s): the values and the order of the page, the choice of no operation
/// first among the operations ([creditLogAnyOperationName], an empty value), as the page's form lists it. Empty
/// lists for the forum's message, which carries no form (no `filters`).
ChangelogAllParameters changelogParametersFromApi(Map<String, dynamic> json) {
  final filters = tsdmAppMap(json['filters']);
  if (filters.isEmpty) {
    return const ChangelogAllParameters.empty();
  }
  return ChangelogAllParameters(
    extTypeList: tsdmAppList(
      filters['exttype'],
    ).map((e) => ChangelogPointsType(name: tsdmAppText(e['name']).trim(), extType: _valueOf(e))).toList(),
    operationTypeList: [
      const ChangelogOperationType(name: creditLogAnyOperationName, operation: ''),
      ...tsdmAppList(
        filters['optype'],
      ).map((e) => ChangelogOperationType(name: tsdmAppText(e['name']).trim(), operation: _valueOf(e))),
    ],
    changeTypeList: tsdmAppList(
      filters['income'],
    ).map((e) => ChangelogChangeType(name: tsdmAppText(e['name']).trim(), changeType: _valueOf(e))).toList(),
  );
}

/// The `value` of a filter option [option] as the query sends it: a number (`exttype`, `income`) or a code
/// (`optype`).
String _valueOf(Map<String, dynamic> option) => switch (option['value']) {
  final num n => '${n.toInt()}',
  final String s => s.trim(),
  _ => '',
};
