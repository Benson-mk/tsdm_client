part of 'models.dart';

/// The special block of a thread (plugin 2.8.0, the thread page answer's `special`, `schema: 15`): the poll, the
/// goods, the bounty, the activity or the debate the forum prints in the first floor (`div.pcbs`), as structured
/// fields, with the forum's own forms for what the account the page was served to may do there.
///
/// Only on the page holding the first floor, when the forum printed its content (not banned, hidden, password
/// protected or forged): null otherwise, and for a thread of another kind. Every field is read defensively: a
/// missing or malformed field is empty, 0 or null, an unknown `type` gives no block at all.
///
/// [formHash] is the answer's `formhash` and [viewerUid] its `uid` (null for a guest): the forms belong to that
/// account, and are only sent while it is still the account in use.
sealed class ThreadSpecial {
  const ThreadSpecial({required this.formHash, required this.viewerUid});

  /// The special block of an answer's `special` [value] with the answer's [formHash] and [viewerUid] (`uid`, 0 for a
  /// guest); null when there is none or its `type` is not one of the five.
  static ThreadSpecial? fromApi(Object? value, {String formHash = '', int viewerUid = 0}) {
    if (value is! Map<String, dynamic>) {
      return null;
    }
    final uid = viewerUid > 0 ? viewerUid : null;
    return switch (value['type']) {
      'poll' => PollSpecial._fromApi(value, formHash: formHash, viewerUid: uid),
      'trade' => TradeSpecial._fromApi(value, formHash: formHash, viewerUid: uid),
      'reward' => RewardSpecial._fromApi(value, formHash: formHash, viewerUid: uid),
      'activity' => ActivitySpecial._fromApi(value, formHash: formHash, viewerUid: uid),
      'debate' => DebateSpecial._fromApi(value, formHash: formHash, viewerUid: uid),
      _ => null,
    };
  }

  /// The form hash of the page the block was read from (the answer's `formhash`).
  final String formHash;

  /// The account the page was served to; null for a guest.
  final int? viewerUid;
}

/// How a [SpecialRequest] goes to the forum.
enum SpecialRequestMethod {
  /// A query, the fields in the url (the debate vote, the forum's `ajaxmenu`).
  get,

  /// A posted form.
  post,
}

/// One action of a special block, the way the forum's own page sends it: [url] on the forum's host (without the
/// result parameter, which the transport adds) and the [fields] of the form, its form hash included.
final class SpecialRequest {
  /// Constructor.
  const SpecialRequest({required this.method, required this.url, required this.fields, required this.viewerUid});

  /// GET or POST.
  final SpecialRequestMethod method;

  /// Absolute url on the forum's host.
  final String url;

  /// The form fields; empty for a GET, whose fields are in [url].
  final Map<String, String> fields;

  /// The account the form belongs to (the page's), null for a guest.
  final int? viewerUid;

  @override
  String toString() => 'SpecialRequest(${method.name} $url $fields)';
}

/// The url [relative] (a forum url of an answer, relative or on the forum's host) on the forum's canonical host,
/// when it is the forum's `forum.php?mod=misc&action=[action]`; null for anything else, so that no answer can make
/// the app send a form elsewhere.
String? _specialActionUrl(String relative, String action) {
  if (relative.trim().isEmpty) {
    return null;
  }
  final uri = Uri.tryParse(relative.trim());
  if (uri == null || !uri.isForumOrRelative || uri.userInfo.isNotEmpty || uri.hasFragment) {
    return null;
  }
  final absolute = uri.hasScheme ? uri.toCanonicalForumUri() : Uri.parse('$baseUrl/').resolveUri(uri);
  final query = absolute.queryParameters;
  if (absolute.path != '/forum.php' || query['mod'] != 'misc' || query['action'] != action) {
    return null;
  }
  return absolute.toString();
}

/// A forum url of an answer [value] to open in the browser, on the forum's host; null when empty or foreign.
String? _specialPageUrl(Object? value) {
  final text = _apiText(value).trim();
  if (text.isEmpty) {
    return null;
  }
  final uri = Uri.tryParse(text);
  if (uri == null || !uri.isForumOrRelative) {
    return null;
  }
  return uri.hasScheme ? uri.toCanonicalForumUri().toString() : Uri.parse('$baseUrl/').resolveUri(uri).toString();
}

/// The string fields of a form (`fields`), every value as text.
Map<String, String> _specialFields(Object? value) => switch (value) {
  final Map<String, dynamic> map => {
    for (final e in map.entries)
      if (e.value is String || e.value is num) e.key: '${e.value}',
  },
  _ => const {},
};

num _apiNum(Object? value) => switch (value) {
  final num n => n,
  final String s => num.tryParse(s) ?? 0,
  _ => 0,
};

bool _apiFlag(Object? value) => _apiInt(value) != 0;

List<Map<String, dynamic>> _apiMaps(Object? value) =>
    value is List ? value.whereType<Map<String, dynamic>>().toList() : const [];

/// A site credit as the forum names it: `id` (extcredits N), `title`, `unit`.
final class SpecialCredit {
  /// Constructor.
  const SpecialCredit({required this.id, required this.title, required this.unit});

  /// Null when [value] is not an object.
  static SpecialCredit? fromApi(Object? value) => value is Map<String, dynamic>
      ? SpecialCredit(id: _apiInt(value['id']), title: _apiText(value['title']), unit: _apiText(value['unit']))
      : null;

  /// The extcredits number.
  final int id;

  /// Name (天使币, 威望…).
  final String title;

  /// Unit, often empty.
  final String unit;
}

/// One choice of a field of a form ([SpecialFormInput.choices]).
final class SpecialFormChoice {
  /// Constructor.
  const SpecialFormChoice({required this.value, required this.label});

  /// Value sent.
  final String value;

  /// Text shown.
  final String label;
}

/// A field of a form the forum asks to be filled (the activity's application, its cancel): `name` sent, `title`,
/// `type` as the forum's form type (`text`, `textarea`, `select`, `radio`, `checkbox`, or others the app cannot
/// draw), `required`, the account's own `value` the page prefills, the `choices`, and the forum's own `html` of it.
final class SpecialFormInput {
  /// Constructor.
  const SpecialFormInput({
    required this.name,
    required this.title,
    required this.type,
    required this.required,
    required this.value,
    required this.choices,
    required this.html,
  });

  static SpecialFormInput? _fromApi(Map<String, dynamic> m) {
    final name = _apiText(m['name']);
    if (name.isEmpty) {
      return null;
    }
    return SpecialFormInput(
      name: name,
      title: _apiText(m['title']),
      type: _apiText(m['type']),
      required: _apiFlag(m['required']),
      value: m['value'] is num ? '${m['value']}' : _apiText(m['value']),
      choices: [
        for (final c in _apiMaps(m['choices']))
          SpecialFormChoice(
            value: c['value'] is num ? '${c['value']}' : _apiText(c['value']),
            label: _apiText(c['label']),
          ),
      ],
      html: _apiText(m['html']),
    );
  }

  /// The form types the app draws itself.
  static const drawnTypes = {'text', 'textarea', 'select', 'radio', 'checkbox'};

  /// Field name.
  final String name;

  /// Caption.
  final String title;

  /// Form type.
  final String type;

  /// Must be filled.
  final bool required;

  /// Prefilled value (the account's own).
  final String value;

  /// Choices of a select, radio or checkbox.
  final List<SpecialFormChoice> choices;

  /// The forum's html of the field.
  final String html;

  /// The app draws this field ([drawnTypes]).
  bool get drawn => drawnTypes.contains(type);
}

/// A form of the forum: `action`, `method`, the hidden `fields` (the form hash is the page's) and the `inputs` to fill.
final class SpecialForm {
  /// Constructor.
  const SpecialForm({required this.action, required this.method, required this.fields, required this.inputs});

  /// Null when [value] is not an object or has no action.
  static SpecialForm? fromApi(Object? value) {
    if (value is! Map<String, dynamic> || _apiText(value['action']).isEmpty) {
      return null;
    }
    return SpecialForm(
      action: _apiText(value['action']),
      method: _apiText(value['method']).toUpperCase(),
      fields: _specialFields(value['fields']),
      inputs: _apiMaps(value['inputs']).map(SpecialFormInput._fromApi).whereType<SpecialFormInput>().toList(),
    );
  }

  /// Target, relative to the forum.
  final String action;

  /// `POST` or `GET`.
  final String method;

  /// Hidden fields.
  final Map<String, String> fields;

  /// Fields to fill.
  final List<SpecialFormInput> inputs;
}

/// An action whose url names a placeholder (`{pid}`, `{stand}`): `action_template`, `method`, the hidden `fields`.
final class SpecialActionTemplate {
  /// Constructor.
  const SpecialActionTemplate({required this.actionTemplate, required this.method, required this.fields});

  /// Null when [value] is not an object or has no template.
  static SpecialActionTemplate? fromApi(Object? value) {
    if (value is! Map<String, dynamic> || _apiText(value['action_template']).isEmpty) {
      return null;
    }
    return SpecialActionTemplate(
      actionTemplate: _apiText(value['action_template']),
      method: _apiText(value['method']).toUpperCase(),
      fields: _specialFields(value['fields']),
    );
  }

  /// The url with its placeholder.
  final String actionTemplate;

  /// `POST` or `GET`.
  final String method;

  /// Hidden fields.
  final Map<String, String> fields;
}

// ---------------------------------------------------------------------------------------------------------------------
// Poll.
// ---------------------------------------------------------------------------------------------------------------------

/// The image of a choice of an image poll.
final class PollSpecialImage {
  /// Constructor.
  const PollSpecialImage({required this.aid, required this.small, required this.big, required this.filename});

  /// Attachment id.
  final int aid;

  /// Thumbnail url (absolute), null when none.
  final String? small;

  /// Full image url (absolute), null when none.
  final String? big;

  /// File name.
  final String filename;
}

/// A choice of a poll: `id` (the value sent), `no` (the number the page prints), `text`, and the result when the
/// account may see it (`votes`, `percent`: null when the results are hidden until a vote).
final class PollSpecialChoice {
  /// Constructor.
  const PollSpecialChoice({
    required this.id,
    required this.no,
    required this.text,
    required this.html,
    required this.votes,
    required this.percent,
    required this.image,
  });

  /// The value sent.
  final int id;

  /// The number the page prints.
  final int no;

  /// Plain text.
  final String text;

  /// The forum's html of the text (its `[url]` as a link).
  final String html;

  /// Votes; null when hidden.
  final int? votes;

  /// Percent of the votes (two decimals); null when hidden.
  final double? percent;

  /// The image of an image poll.
  final PollSpecialImage? image;
}

/// The poll form: `action` (relative), `method`, `fields`, and the name the choices are sent as (`choice`).
final class PollSpecialForm {
  /// Constructor.
  const PollSpecialForm({required this.action, required this.method, required this.fields, required this.choice});

  /// Target, relative.
  final String action;

  /// `POST`.
  final String method;

  /// Hidden fields.
  final Map<String, String> fields;

  /// The choices' field name (`pollanswers[]`).
  final String choice;
}

/// A poll (`type: poll`).
final class PollSpecial extends ThreadSpecial {
  /// Constructor.
  const PollSpecial({
    required super.formHash,
    required super.viewerUid,
    required this.multiple,
    required this.maxChoices,
    required this.image,
    required this.overt,
    required this.voters,
    required this.expiration,
    required this.expired,
    required this.resultsVisible,
    required this.afterResult,
    required this.voted,
    required this.canVote,
    required this.why,
    required this.canViewVoters,
    required this.votersUrl,
    required this.choices,
    required this.form,
  });

  factory PollSpecial._fromApi(Map<String, dynamic> m, {required String formHash, required int? viewerUid}) {
    final form = m['form'];
    return PollSpecial(
      formHash: formHash,
      viewerUid: viewerUid,
      multiple: _apiFlag(m['multiple']),
      maxChoices: _apiInt(m['maxchoices']),
      image: _apiFlag(m['image']),
      overt: _apiFlag(m['overt']),
      voters: _apiInt(m['voters']),
      expiration: _apiTime(m['expiration']),
      expired: _apiFlag(m['expired']),
      resultsVisible: _apiFlag(m['results_visible']),
      afterResult: _apiFlag(m['after_result']),
      voted: _apiFlag(m['voted']),
      canVote: _apiFlag(m['can_vote']),
      why: _apiText(m['why']),
      canViewVoters: _apiFlag(m['can_view_voters']),
      votersUrl: _specialPageUrl(m['voters_url']),
      choices: [
        for (final c in _apiMaps(m['choices']))
          if (_apiInt(c['id']) > 0)
            PollSpecialChoice(
              id: _apiInt(c['id']),
              no: _apiInt(c['no']),
              text: _apiText(c['text']),
              html: _apiText(c['html']),
              votes: c['votes'] is num ? _apiInt(c['votes']) : null,
              percent: c['percent'] is num ? (c['percent'] as num).toDouble() : null,
              image: c['image'] is Map<String, dynamic>
                  ? PollSpecialImage(
                      aid: _apiInt((c['image'] as Map<String, dynamic>)['aid']),
                      small: _apiImageUrl((c['image'] as Map<String, dynamic>)['small']),
                      big: _apiImageUrl((c['image'] as Map<String, dynamic>)['big']),
                      filename: _apiText((c['image'] as Map<String, dynamic>)['filename']),
                    )
                  : null,
            ),
      ],
      form: form is Map<String, dynamic> && _apiText(form['action']).isNotEmpty
          ? PollSpecialForm(
              action: _apiText(form['action']),
              method: _apiText(form['method']).toUpperCase(),
              fields: _specialFields(form['fields']),
              choice: _apiText(form['choice']),
            )
          : null,
    );
  }

  /// Several choices allowed.
  final bool multiple;

  /// Most choices allowed.
  final int maxChoices;

  /// An image poll.
  final bool image;

  /// Others see what one voted for.
  final bool overt;

  /// Number of voters.
  final int voters;

  /// End of the vote; null when it never ends.
  final DateTime? expiration;

  /// The vote has ended.
  final bool expired;

  /// The account sees the results now.
  final bool resultsVisible;

  /// The results show after a vote ("投票后结果可见" while the account may vote).
  final bool afterResult;

  /// The account voted.
  final bool voted;

  /// The account may vote.
  final bool canVote;

  /// Why not: `nopermission`, `voted`, `closed`; empty when it may or the thread is archived.
  final String why;

  /// The page links the voters.
  final bool canViewVoters;

  /// The voters page (absolute), null when none.
  final String? votersUrl;

  /// The choices in the forum's order.
  final List<PollSpecialChoice> choices;

  /// The vote form, null when the account may not vote.
  final PollSpecialForm? form;

  /// The vote url (absolute, with `inajax=1` as the page's ajaxpost sends it); null when there is no valid form.
  String? get voteUrl {
    final action = form?.action;
    final url = action == null ? null : _specialActionUrl(action, 'votepoll');
    return url == null ? null : '$url&inajax=1';
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Trade.
// ---------------------------------------------------------------------------------------------------------------------

/// What is left of the time to buy a goods: the forum gives the page days and hours only.
final class TradeRemain {
  /// Constructor.
  const TradeRemain({required this.days, required this.hours});

  /// Days.
  final int days;

  /// Hours.
  final int hours;
}

/// A goods of a trade thread, in the page's order (the recommended first).
final class TradeGoods {
  /// Constructor.
  const TradeGoods({
    required this.pid,
    required this.removed,
    required this.subject,
    required this.sticky,
    required this.quality,
    required this.timeout,
    required this.remain,
    required this.price,
    required this.credit,
    required this.costPrice,
    required this.costCredit,
    required this.thumb,
    required this.image,
    required this.url,
  });

  /// The goods' floor.
  final int pid;

  /// Deleted: the page prints only that, every other field is empty.
  final bool removed;

  /// Name.
  final String subject;

  /// Recommended.
  final bool sticky;

  /// 1 new, 2 second hand, 0 not said.
  final int quality;

  /// The trade ended (closed or expired).
  final bool timeout;

  /// Time left; null when unlimited or ended.
  final TradeRemain? remain;

  /// Price in money (0: none).
  final num price;

  /// Price in the site's trade credit (0: none).
  final int credit;

  /// Original price in money.
  final num costPrice;

  /// Original price in credit.
  final int costCredit;

  /// Thumbnail url (absolute), null when none.
  final String? thumb;

  /// Image url (absolute), null when none.
  final String? image;

  /// The goods page (absolute): buying, bargaining, quantity, shipping and the seller's contact are there.
  final String? url;
}

/// The goods of a trade thread (`type: trade`).
final class TradeSpecial extends ThreadSpecial {
  /// Constructor.
  const TradeSpecial({
    required super.formHash,
    required super.viewerUid,
    required this.count,
    required this.creditUnit,
    required this.canManage,
    required this.manageUrl,
    required this.canAdd,
    required this.addUrl,
    required this.goods,
  });

  factory TradeSpecial._fromApi(Map<String, dynamic> m, {required String formHash, required int? viewerUid}) =>
      TradeSpecial(
        formHash: formHash,
        viewerUid: viewerUid,
        count: m['count'] is num ? _apiInt(m['count']) : null,
        creditUnit: SpecialCredit.fromApi(m['credit_unit']),
        canManage: _apiFlag(m['can_manage']),
        manageUrl: _specialPageUrl(m['manage_url']),
        canAdd: _apiFlag(m['can_add']),
        addUrl: _specialPageUrl(m['add_url']),
        goods: [
          for (final g in _apiMaps(m['goods']))
            TradeGoods(
              pid: _apiInt(g['pid']),
              removed: _apiFlag(g['removed']),
              subject: _apiText(g['subject']),
              sticky: _apiFlag(g['sticky']),
              quality: _apiInt(g['quality']),
              timeout: _apiFlag(g['timeout']),
              remain: g['remain'] is Map<String, dynamic>
                  ? TradeRemain(
                      days: _apiInt((g['remain'] as Map<String, dynamic>)['days']),
                      hours: _apiInt((g['remain'] as Map<String, dynamic>)['hours']),
                    )
                  : null,
              price: _apiNum(g['price']),
              credit: _apiInt(g['credit']),
              costPrice: _apiNum(g['costprice']),
              costCredit: _apiInt(g['costcredit']),
              thumb: _apiImageUrl(g['thumb']),
              image: _apiImageUrl(g['image']),
              url: _specialPageUrl(g['url']),
            ),
        ],
      );

  /// Number of goods, when the page prints it (more than one goods, or the author or a manager looks); null
  /// otherwise.
  final int? count;

  /// The site's trade credit; null when the site takes none.
  final SpecialCredit? creditUnit;

  /// The account may sort the goods (the page's "商品排序").
  final bool canManage;

  /// The page to do it (absolute).
  final String? manageUrl;

  /// The account may add goods.
  final bool canAdd;

  /// The page to do it (absolute).
  final String? addUrl;

  /// The goods.
  final List<TradeGoods> goods;
}

// ---------------------------------------------------------------------------------------------------------------------
// Reward.
// ---------------------------------------------------------------------------------------------------------------------

/// The accepted answer of a resolved bounty.
final class RewardBestPost {
  /// Constructor.
  const RewardBestPost({
    required this.pid,
    required this.authorId,
    required this.author,
    required this.avatar,
    required this.excerpt,
    required this.excerptReason,
    required this.url,
  });

  /// Its floor.
  final int pid;

  /// Its author, 0 when anonymous to the account.
  final int authorId;

  /// Its author's name, empty when anonymous.
  final String author;

  /// Its author's avatar (absolute), null when none.
  final String? avatar;

  /// The forum's excerpt (plain text); null when the account may not read it ([excerptReason]).
  final String? excerpt;

  /// Why [excerpt] is null: `locked` (replies only the author sees), `hide`, `password`.
  final String excerptReason;

  /// The floor (absolute `findpost` url), null when none.
  final String? url;

  /// The author is not named to the account.
  bool get anonymous => authorId <= 0 || author.isEmpty;
}

/// Setting the accepted answer: the form posted for one of [pids].
final class RewardSetBest {
  /// Constructor.
  const RewardSetBest({required this.actionTemplate, required this.method, required this.fields, required this.pids});

  /// The url with `{pid}`.
  final String actionTemplate;

  /// `POST`.
  final String method;

  /// Hidden fields (the page's `form#modactions`).
  final Map<String, String> fields;

  /// The floors of the page the account may accept.
  final List<int> pids;
}

/// A bounty (`type: reward`).
final class RewardSpecial extends ThreadSpecial {
  /// Constructor.
  const RewardSpecial({
    required super.formHash,
    required super.viewerUid,
    required this.price,
    required this.resolved,
    required this.credit,
    required this.canAnswer,
    required this.canSetBest,
    required this.setBest,
    required this.bestPost,
  });

  factory RewardSpecial._fromApi(Map<String, dynamic> m, {required String formHash, required int? viewerUid}) {
    final setBest = m['set_best'];
    final best = m['bestpost'];
    return RewardSpecial(
      formHash: formHash,
      viewerUid: viewerUid,
      price: _apiInt(m['price']).abs(),
      resolved: _apiFlag(m['resolved']),
      credit: SpecialCredit.fromApi(m['credit']),
      canAnswer: _apiFlag(m['can_answer']),
      canSetBest: _apiFlag(m['can_set_best']),
      setBest: setBest is Map<String, dynamic> && _apiText(setBest['action_template']).isNotEmpty
          ? RewardSetBest(
              actionTemplate: _apiText(setBest['action_template']),
              method: _apiText(setBest['method']).toUpperCase(),
              fields: _specialFields(setBest['fields']),
              pids: _apiList(setBest['pids']).map(_apiInt).where((e) => e > 0).toList(),
            )
          : null,
      bestPost: best is Map<String, dynamic> && _apiInt(best['pid']) > 0
          ? RewardBestPost(
              pid: _apiInt(best['pid']),
              authorId: _apiInt(best['authorid']),
              author: _apiText(best['author']),
              avatar: _apiImageUrl(best['avatar']),
              excerpt: best['excerpt'] is String ? best['excerpt'] as String : null,
              excerptReason: _apiText(best['excerpt_reason']),
              url: _specialPageUrl(best['url']),
            )
          : null,
    );
  }

  /// The bounty.
  final int price;

  /// Resolved.
  final bool resolved;

  /// The credit it is paid in.
  final SpecialCredit? credit;

  /// The account may answer (the app's own reply).
  final bool canAnswer;

  /// The account may accept an answer.
  final bool canSetBest;

  /// The form to do it, null when it may not.
  final RewardSetBest? setBest;

  /// The accepted answer, null when none (or on another page).
  final RewardBestPost? bestPost;

  /// The request accepting floor [pid] as the answer; null when the account may not accept that floor.
  SpecialRequest? bestAnswerRequest(int pid) {
    final form = setBest;
    if (!canSetBest || form == null || form.method != 'POST' || !form.pids.contains(pid) || formHash.isEmpty) {
      return null;
    }
    final url = _specialActionUrl(form.actionTemplate.replaceAll('{pid}', '$pid'), 'bestanswer');
    if (url == null || Uri.parse(url).queryParameters['pid'] != '$pid') {
      return null;
    }
    return SpecialRequest(
      method: SpecialRequestMethod.post,
      url: url,
      fields: {'formhash': formHash, ...form.fields},
      viewerUid: viewerUid,
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Activity.
// ---------------------------------------------------------------------------------------------------------------------

/// The credit an activity takes from each applicant.
final class ActivityCredit {
  /// Constructor.
  const ActivityCredit({required this.amount, required this.enough, required this.credit});

  /// Amount taken.
  final int amount;

  /// The account has enough (the forum's rule: always when the site sets no lower limit).
  final bool enough;

  /// The credit.
  final SpecialCredit credit;
}

/// An applicant of an activity.
final class ActivityApplicant {
  /// Constructor.
  const ActivityApplicant({
    required this.uid,
    required this.username,
    required this.avatar,
    required this.dateline,
    required this.message,
    required this.payment,
  });

  /// Uid.
  final int uid;

  /// Name.
  final String username;

  /// Avatar (absolute), null when none.
  final String? avatar;

  /// When they applied (to the minute).
  final DateTime? dateline;

  /// Their message, empty when none or not shown to the account.
  final String message;

  /// What they pay when the activity costs: the amount, or -1 paying their own way; null when it costs nothing.
  final int? payment;
}

/// An activity (`type: activity`).
final class ActivitySpecial extends ThreadSpecial {
  /// Constructor.
  const ActivitySpecial({
    required super.formHash,
    required super.viewerUid,
    required this.activityClass,
    required this.place,
    required this.gender,
    required this.cost,
    required this.number,
    required this.startFrom,
    required this.startTo,
    required this.expiration,
    required this.closed,
    required this.image,
    required this.appliedCount,
    required this.verifiedCount,
    required this.pendingCount,
    required this.remaining,
    required this.credit,
    required this.applied,
    required this.verified,
    required this.canApply,
    required this.applyMode,
    required this.apply,
    required this.canCancel,
    required this.cancel,
    required this.canManage,
    required this.manageUrl,
    required this.applyList,
    required this.applyListMore,
    required this.pending,
  });

  factory ActivitySpecial._fromApi(Map<String, dynamic> m, {required String formHash, required int? viewerUid}) {
    final image = m['image'];
    final credit = m['credit'];
    List<ActivityApplicant> applicants(Object? value) => [
      for (final a in _apiMaps(value))
        ActivityApplicant(
          uid: _apiInt(a['uid']),
          username: _apiText(a['username']),
          avatar: _apiImageUrl(a['avatar']),
          dateline: _apiTime(a['dateline']),
          message: _apiText(a['message']),
          payment: a['payment'] is num ? _apiInt(a['payment']) : null,
        ),
    ];
    return ActivitySpecial(
      formHash: formHash,
      viewerUid: viewerUid,
      activityClass: _apiText(m['class']),
      place: _apiText(m['place']),
      gender: _apiInt(m['gender']),
      cost: _apiInt(m['cost']),
      number: _apiInt(m['number']),
      startFrom: _apiTime(m['starttimefrom']),
      startTo: _apiTime(m['starttimeto']),
      expiration: _apiTime(m['expiration']),
      closed: _apiFlag(m['closed']),
      image: image is Map<String, dynamic> ? (_apiImageUrl(image['thumb']) ?? _apiImageUrl(image['url'])) : null,
      appliedCount: m['applied_count'] is num ? _apiInt(m['applied_count']) : null,
      verifiedCount: _apiInt(m['verified_count']),
      pendingCount: _apiInt(m['pending_count']),
      remaining: m['remaining'] is num ? _apiInt(m['remaining']) : null,
      credit: credit is Map<String, dynamic>
          ? ActivityCredit(
              amount: _apiInt(credit['amount']),
              enough: _apiFlag(credit['enough']),
              credit: SpecialCredit.fromApi(credit)!,
            )
          : null,
      applied: _apiFlag(m['applied']),
      verified: m['verified'] is num ? _apiInt(m['verified']) : null,
      canApply: _apiFlag(m['can_apply']),
      applyMode: _apiText(m['apply_mode']),
      apply: SpecialForm.fromApi(m['apply']),
      canCancel: _apiFlag(m['can_cancel']),
      cancel: SpecialForm.fromApi(m['cancel']),
      canManage: _apiFlag(m['can_manage']),
      manageUrl: _specialPageUrl(m['manage_url']),
      applyList: applicants(m['applylist']),
      applyListMore: _specialPageUrl(m['applylist_more']),
      pending: applicants(m['pending']),
    );
  }

  /// The activity's class.
  final String activityClass;

  /// Where.
  final String place;

  /// 0 anyone, 1 men, 2 women.
  final int gender;

  /// Cost per person (money), 0 when free.
  final int cost;

  /// Places, 0 unlimited.
  final int number;

  /// Start (to the minute).
  final DateTime? startFrom;

  /// End; null when not said.
  final DateTime? startTo;

  /// Applications close; null when not said.
  final DateTime? expiration;

  /// Applications closed.
  final bool closed;

  /// The poster (absolute thumbnail url), null when none.
  final String? image;

  /// Applicants, accepted or not; null when the page does not print it (an archived thread).
  final int? appliedCount;

  /// Accepted applicants.
  final int verifiedCount;

  /// Applicants waiting.
  final int pendingCount;

  /// Places left; null when unlimited.
  final int? remaining;

  /// The credit it takes; null when none.
  final ActivityCredit? credit;

  /// The account applied.
  final bool applied;

  /// The account's application: 0 waiting, 1 accepted, 2 asked to complete it; null when it did not apply.
  final int? verified;

  /// The account may apply (or complete its application).
  final bool canApply;

  /// `join` or `complete`.
  final String applyMode;

  /// The application form.
  final SpecialForm? apply;

  /// The account may cancel its application.
  final bool canCancel;

  /// The cancel form.
  final SpecialForm? cancel;

  /// The account may manage the applications (on the web page).
  final bool canManage;

  /// The page to do it (absolute).
  final String? manageUrl;

  /// The accepted applicants the page shows.
  final List<ActivityApplicant> applyList;

  /// The next page of [applyList] (absolute), null when none.
  final String? applyListMore;

  /// The applicants waiting the page shows.
  final List<ActivityApplicant> pending;

  /// The inputs of [apply] the app cannot draw (a birthday, a file…): the application then goes through the web page.
  bool get applyNeedsWeb => apply?.inputs.any((e) => !e.drawn) ?? false;

  /// The application with the account's [values] (by input name: text, or the list of a checkbox), as the page's
  /// ajaxpost sends it (`inajax=1`); null when the account may not apply, the form is not the forum's or it has a
  /// field the app cannot draw. Values for names the form does not ask are left out.
  SpecialRequest? applyRequest(Map<String, Object> values) {
    final form = apply;
    if (!canApply || form == null || form.method != 'POST' || formHash.isEmpty || applyNeedsWeb) {
      return null;
    }
    final url = _specialActionUrl(form.action, 'activityapplies');
    if (url == null) {
      return null;
    }
    final fields = <String, String>{'formhash': formHash, ...form.fields};
    for (final input in form.inputs) {
      switch (values[input.name]) {
        case final List<String> list when input.type == 'checkbox':
          for (var i = 0; i < list.length; i++) {
            fields['${input.name}[$i]'] = list[i];
          }
        case final String text:
          fields[input.name] = text;
        default:
          if (input.type != 'checkbox') {
            fields[input.name] = input.value;
          }
      }
    }
    return SpecialRequest(
      method: SpecialRequestMethod.post,
      url: '$url&inajax=1',
      fields: fields,
      viewerUid: viewerUid,
    );
  }

  /// Cancelling the application with the account's [message], posted as the page posts it; null when it may not.
  SpecialRequest? cancelRequest(String message) {
    final form = cancel;
    if (!canCancel || form == null || form.method != 'POST' || formHash.isEmpty) {
      return null;
    }
    final url = _specialActionUrl(form.action, 'activityapplies');
    if (url == null) {
      return null;
    }
    return SpecialRequest(
      method: SpecialRequestMethod.post,
      url: url,
      fields: {
        'formhash': formHash,
        ...form.fields,
        for (final input in form.inputs) input.name: input.name == 'message' ? message : input.value,
      },
      viewerUid: viewerUid,
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Debate.
// ---------------------------------------------------------------------------------------------------------------------

/// A debater shown beside a side.
final class DebateUser {
  /// Constructor.
  const DebateUser({required this.uid, required this.username, required this.avatar});

  /// Uid.
  final int uid;

  /// Name.
  final String username;

  /// Avatar (absolute), null when none.
  final String? avatar;
}

/// The umpire's verdict.
final class DebateResult {
  /// Constructor.
  const DebateResult({required this.winner, required this.umpirePoint, required this.bestDebater});

  /// 1 affirmative, 2 negative, another non-zero a draw, 0 not said.
  final int winner;

  /// The umpire's point (plain text).
  final String umpirePoint;

  /// The best debater's name.
  final String bestDebater;
}

/// A debate (`type: debate`).
final class DebateSpecial extends ThreadSpecial {
  /// Constructor.
  const DebateSpecial({
    required super.formHash,
    required super.viewerUid,
    required this.affirmPoint,
    required this.negaPoint,
    required this.affirmVotes,
    required this.negaVotes,
    required this.affirmDebaters,
    required this.negaDebaters,
    required this.affirmAvatars,
    required this.negaAvatars,
    required this.endTime,
    required this.ended,
    required this.umpire,
    required this.result,
    required this.voted,
    required this.canVote,
    required this.vote,
    required this.canUmpire,
    required this.umpireUrl,
  });

  factory DebateSpecial._fromApi(Map<String, dynamic> m, {required String formHash, required int? viewerUid}) {
    List<DebateUser> users(Object? value) => [
      for (final u in _apiMaps(value))
        DebateUser(uid: _apiInt(u['uid']), username: _apiText(u['username']), avatar: _apiImageUrl(u['avatar'])),
    ];
    final result = m['result'];
    return DebateSpecial(
      formHash: formHash,
      viewerUid: viewerUid,
      affirmPoint: _apiText(m['affirmpoint']),
      negaPoint: _apiText(m['negapoint']),
      affirmVotes: _apiInt(m['affirmvotes']),
      negaVotes: _apiInt(m['negavotes']),
      affirmDebaters: m['affirmdebaters'] is num ? _apiInt(m['affirmdebaters']) : null,
      negaDebaters: m['negadebaters'] is num ? _apiInt(m['negadebaters']) : null,
      affirmAvatars: users(m['affirmavatars']),
      negaAvatars: users(m['negaavatars']),
      endTime: _apiTime(m['endtime']),
      ended: _apiFlag(m['ended']),
      umpire: _apiText(m['umpire']),
      result: result is Map<String, dynamic>
          ? DebateResult(
              winner: _apiInt(result['winner']),
              umpirePoint: _apiText(result['umpirepoint']),
              bestDebater: _apiText(result['bestdebater']),
            )
          : null,
      voted: _apiInt(m['voted']),
      canVote: _apiFlag(m['can_vote']),
      vote: SpecialActionTemplate.fromApi(m['vote']),
      canUmpire: _apiFlag(m['can_umpire']),
      umpireUrl: _specialPageUrl(m['umpire_url']),
    );
  }

  /// The affirmative point (plain text).
  final String affirmPoint;

  /// The negative point (plain text).
  final String negaPoint;

  /// Votes of the affirmative side.
  final int affirmVotes;

  /// Votes of the negative side.
  final int negaVotes;

  /// Debaters of the affirmative side; null when the page does not print it (an archived thread).
  final int? affirmDebaters;

  /// Debaters of the negative side; null when the page does not print it.
  final int? negaDebaters;

  /// Debaters the page shows (16 at most).
  final List<DebateUser> affirmAvatars;

  /// Debaters the page shows (16 at most).
  final List<DebateUser> negaAvatars;

  /// End; null when unlimited.
  final DateTime? endTime;

  /// Ended.
  final bool ended;

  /// The umpire's name; empty when none, or when the debate has no end time (the page prints the umpire beside it).
  final String umpire;

  /// The verdict, null when none.
  final DebateResult? result;

  /// The side the account voted for: 0 none, 1 affirmative, 2 negative.
  final int voted;

  /// The account may vote.
  final bool canVote;

  /// The vote, `{stand}` 1 or 2.
  final SpecialActionTemplate? vote;

  /// The account is the umpire and may end the debate or edit the verdict (on the web page).
  final bool canUmpire;

  /// The page to do it (absolute).
  final String? umpireUrl;

  /// The vote for side [stand] (1 affirmative, 2 negative), a GET as the page's ajaxmenu sends it (no form hash, the
  /// forum asks none); null when the account may not vote.
  SpecialRequest? voteRequest(int stand) {
    final template = vote;
    if (!canVote || template == null || template.method != 'GET' || (stand != 1 && stand != 2)) {
      return null;
    }
    final url = _specialActionUrl(template.actionTemplate.replaceAll('{stand}', '$stand'), 'debatevote');
    if (url == null || Uri.parse(url).queryParameters['stand'] != '$stand') {
      return null;
    }
    final query = template.fields.entries
        .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return SpecialRequest(
      method: SpecialRequestMethod.get,
      url: query.isEmpty ? url : '$url&$query',
      fields: const {},
      viewerUid: viewerUid,
    );
  }
}
