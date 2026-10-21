part of 'models.dart';

/// Data model for subreddit.
@MappableClass()
final class Forum with ForumMappable {
  /// Constructor.
  const Forum({
    required this.forumID,
    required this.url,
    required this.name,
    required this.iconUrl,
    required this.threadCount,
    required this.replyCount,
    required this.latestThreadUrl,
    required this.latestThreadTime,
    required this.latestThreadTimeText,
    required this.threadTodayCount,

    /// Expanded layout only.
    this.subForumList,
    this.subThreadList,
    this.latestThreadTitle,
    this.latestThreadUserName,
    this.latestThreadUserUrl,
    this.isPrivate = false,
    this.redirectUrl,
  });

  /// Build a [Forum] from a forum [s] of a structured answer of the forum's app API: a subforum of the forum page
  /// (plugin 2.0.0, `schema: 2`, see `forumPageFromApi`), the expanded layout the forum page lists its subforums in,
  /// a forum of a category or of the "我收藏的版块" panel of the homepage (`schema: 5`).
  ///
  /// * The url is the forum's page, or the address a redirect forum points to (`redirect`, empty otherwise).
  /// * `todayposts` 0 is no count, as the page prints no `<em>` then.
  /// * `lastpost` (null when the forum has no thread) gives the latest thread: its redirect url to the last post, its
  ///   whole subject (the page cuts it to 30 bytes, not imitated), its time (the forum's unix seconds, the real
  ///   instant) and its author with the member's url by username.
  /// * `subforums` are the forum's own subforums (the page's "子版块: a, b" row), null when there are none as the page
  ///   has no row then.
  /// * `description_html` (plugin 2.8.2: the description as the page prints it in its `p.xg2`) gives the shortcuts to
  ///   threads the description links to ([subThreadList], the "链接" of the card), read as [fromFlRowNode] reads them
  ///   from the page; none without it (`description` is plain text).
  /// * `redirect` makes a link forum ([redirectUrl], see [forumRedirectUrlOf]): the page prints no latest thread for
  ///   it, so none is given whatever `lastpost` holds (plugins before 2.8.2 send one with the subforums of the forum
  ///   page). `private` (plugin 2.8.1 for the panel, 2.8.2 for the categories and the subforums) gives [isPrivate];
  ///   without it, a subforum the viewer sees only by name (`permission` 1, plugins before 2.8.2) is one, as the page
  ///   prints "私密版块" for it. The page prints no latest thread for such a forum either.
  factory Forum.fromApi(Map<String, dynamic> s) {
    final fid = _apiInt(s['fid']);
    final redirectUrl = forumRedirectUrlOf(_apiText(s['redirect']), fid);
    final isPrivate = s.containsKey('private') ? _apiInt(s['private']) == 1 : _apiInt(s['permission']) == 1;
    final lastPost = redirectUrl == null && !isPrivate && s['lastpost'] is Map<String, dynamic>
        ? s['lastpost'] as Map<String, dynamic>
        : null;
    // An anonymous last post names no author: the page prints the forum's "匿名" in its place, without a link.
    final lastPostAuthor = lastPost == null ? null : _apiText(lastPost['author']);
    final latestThreadTime = lastPost == null ? null : _apiTime(lastPost['dateline']);
    final todayCount = _apiInt(s['todayposts']);
    final subForumList = s['subforums'] is List
        ? (s['subforums'] as List)
              .whereType<Map<String, dynamic>>()
              .map((e) => (_apiText(e['name']), '$baseUrl/forum.php?mod=forumdisplay&fid=${_apiInt(e['fid'])}'))
              .toList()
        : const <(String, String)>[];
    final descriptionHtml = s['description_html'];
    final subThreadList = descriptionHtml is String && descriptionHtml.contains('tid=')
        ? _descriptionThreadLinks(descriptionHtml)
        : const <(String, String)>[];

    return Forum(
      forumID: fid,
      url: redirectUrl ?? '$baseUrl/forum.php?mod=forumdisplay&fid=$fid',
      name: _apiText(s['name']),
      iconUrl: _apiText(s['icon']),
      threadCount: _apiInt(s['threads']),
      replyCount: _apiInt(s['posts']),
      threadTodayCount: todayCount > 0 ? todayCount : null,
      latestThreadTime: latestThreadTime,
      latestThreadTimeText: latestThreadTime?.yyyyMMDDHHMM(),
      latestThreadUrl: lastPost == null
          ? null
          : '$baseUrl/forum.php?mod=redirect&tid=${_apiInt(lastPost['tid'])}&goto=lastpost',
      latestThreadTitle: lastPost == null ? null : _apiText(lastPost['subject']),
      latestThreadUserName: lastPostAuthor == null || lastPostAuthor.isNotEmpty ? lastPostAuthor : _anonymousName,
      latestThreadUserUrl: lastPostAuthor == null || lastPostAuthor.isEmpty
          ? null
          : '$baseUrl/home.php?mod=space&username=${Uri.encodeComponent(lastPostAuthor)}',
      subForumList: subForumList.isEmpty ? null : subForumList,
      subThreadList: subThreadList.isEmpty ? null : subThreadList,
      isPrivate: isPrivate,
      redirectUrl: redirectUrl,
    );
  }

  /// The links to threads (`tid=`) of a forum's description [html] (`description_html`), as [fromFlRowNode] reads the
  /// description from the page: put in its `p.xg2` in the forum's cell, the html is parsed as the page's is (a block
  /// in the description closes the paragraph and stays in the cell).
  static List<(String, String)> _descriptionThreadLinks(String html) => _threadLinksOf(
    parseHtmlDocument('<table><tbody><tr><td><p class="xg2">$html</p></td></tr></tbody></table>').querySelectorAll(
      'td > p a',
    ),
  );

  /// The shortcuts of a forum card among the links [anchors] of its row ([subThreadList]): each link to a thread
  /// (`tid=`) with its text, or the name of the picture an image link holds (`alt`, `title`); a link with neither
  /// (a banner without a name, as many of the production forum's descriptions have) is left out, as a shortcut
  /// without a label would be an empty button.
  static List<(String, String)> _threadLinksOf(Iterable<uh.Element> anchors) => [
    for (final anchor in anchors)
      if (anchor.attributes['href'] case final String href when href.contains('tid='))
        if (_linkTitleOf(anchor) case final String title) (title, href),
  ];

  /// The label of the link [anchor]: its text (the text of its first innermost element, as the page's readers take
  /// it, else all of it), else the `alt` or `title` of a picture in it, else its own `title`; null when none.
  static String? _linkTitleOf(uh.Element anchor) {
    for (final text in [
      anchor.firstEndDeepText(),
      anchor.innerText,
      ...anchor.querySelectorAll('img').expand((e) => [e.attributes['alt'], e.attributes['title']]),
      anchor.attributes['title'],
    ]) {
      final title = text?.trim();
      if (title != null && title.isNotEmpty) {
        return title;
      }
    }
    return null;
  }

  /// The address of the link forum [fid] whose `redirect` setting is [redirect], as [redirectUrl] keeps it; null when
  /// [redirect] is empty (not a link forum).
  ///
  /// The setting is whatever the site wrote: it is resolved on the forum (a relative address) and kept only when it
  /// is a web address (`http`, `https`, with a host). Anything else (an address that does not parse, another scheme
  /// such as `javascript:`, `intent:` or `file:`) gives the forum's own page, which the forum redirects to the
  /// address as it does on the web page: one forum's setting never fails the page that lists it.
  static String? forumRedirectUrlOf(String redirect, int fid) {
    final text = redirect.trim();
    if (text.isEmpty) {
      return null;
    }
    Uri? uri;
    try {
      final parsed = Uri.tryParse(text);
      uri = parsed == null ? null : Uri.parse('$baseUrl/').resolveUri(parsed);
    } on FormatException {
      uri = null;
    }
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https')) || uri.host.isEmpty) {
      talker.warning('link forum $fid: not a web address, the forum page is opened instead');
      return '$baseUrl/forum.php?mod=forumdisplay&fid=$fid';
    }
    return uri.toString();
  }

  /// Forum id.
  final int forumID;

  /// Url of forum page.
  final String url;

  /// Forum name.
  final String name;

  /// Forum icon url.
  final String iconUrl;

  /// Total thread count.
  final int threadCount;

  /// Total reply count.
  final int replyCount;

  /// The url of latest thread in the forum.
  final String? latestThreadUrl;

  /// The publish time of the latest thread in forum.
  final DateTime? latestThreadTime;

  /// Text format of [latestThreadTime].
  final String? latestThreadTimeText;

  /// Count of thread published today.
  final int? threadTodayCount;

  /// Expanded layout only.

  /// Subreddit list.
  final List<(String subForumName, String url)>? subForumList;

  /// All sub-thread.
  final List<(String threadTitle, String url)>? subThreadList;

  /// Latest thread title.
  final String? latestThreadTitle;

  /// User name of the latest reply in latest thread.
  final String? latestThreadUserName;

  /// Url of the latest thread.
  final String? latestThreadUserUrl;

  /// Whether the viewer may not enter the forum and the page prints "私密版块" in place of its latest thread (a forum
  /// the site still lists to those who may not enter, `hideprivate` off).
  final bool isPrivate;

  /// The address a link forum (the page prints "链接到外部地址" in place of its counts and latest thread) leads to,
  /// opened in the browser as the page opens it in a new window; null for any other forum.
  ///
  /// The `redirect` of the forum's app API, a web address ([forumRedirectUrlOf]); read from the web page, which prints
  /// no address, the forum's own page, which the forum redirects to it.
  final String? redirectUrl;

  /// Is current forum in expanded layout when parsing from server side
  /// html document.
  bool get isExpanded => latestThreadTitle != null && latestThreadUserName != null;

  /// Build a [Forum] model from <tr class="fl_row"> node.
  ///
  /// This function build from expanded style forums.
  ///
  /// Discuz X5 layout:
  ///
  /// <tr class="fl_row">
  ///   <td class="fl_icn"><a href="forum.php?mod=forumdisplay&fid=17"><img src="..." /></a></td>
  ///   <td>
  ///     <h2><a href="forum.php?mod=forumdisplay&fid=17">新人报到</a><em class="xw0 xi1" title="今日"> (35)</em></h2>
  ///     <p class="xg2">description</p>
  ///     <p>子版块: <a href="...">name</a>, <a href="...">name</a></p>
  ///     <p>版主: ...</p>
  ///   </td>
  ///   <td class="fl_i">
  ///     <span class="xi2"><span title="228800">22万</span></span><span class="xg1"> / <span title="1990197">199万</span></span>
  ///   </td>
  ///   <td class="fl_by">
  ///     <div>
  ///       <a href="forum.php?mod=redirect&tid=xxx&goto=lastpost#lastpost" class="xi2">title</a>
  ///       <cite><span title="2026-9-4 18:58">1 小时前</span> <a href="home.php?mod=space&username=xxx">xxx</a></cite>
  ///     </div>
  ///   </td>
  /// </tr>
  ///
  /// Return null if the row is not a forum row (e.g. the empty trailing `<tr class="fl_row"></tr>` in X5), or
  /// required info not found.
  static Forum? fromFlRowNode(uh.Element element) {
    if (element.children.isEmpty) {
      // Empty trailing row, not a forum.
      return null;
    }

    /// Build from '<tr class="fl_row">' of '<tr>' (only the first row in table)
    /// node [element] inside table, with expanded layout.
    final titleNode =
        // X5: the only <h2> in row is the forum title.
        element.querySelector('td > h2 > a') ??
        element.querySelector('td:nth-child(2) > h2 > a') ??
        // Theme 旅行者
        element.querySelector('td:nth-child(1) > h2 > a');
    final name = titleNode?.firstEndDeepText()?.trim();
    final url = titleNode?.firstHref();
    final forumID = url?.uriQueryParameter('fid')?.parseToInt() ?? url?.split('fid=').lastOrNull?.parseToInt();
    if (name == null || forumID == null || url == null) {
      talker.error(
        'failed to build forum: name or fid or url not found: name=$name, '
        'fid=$forumID, url=$url',
      );
      return null;
    }

    // Allow empty.
    final iconUrl = (element.querySelector('td.fl_icn img') ?? element.querySelector('td > a > img'))
        ?.dataOriginalOrSrcImgUrl();

    final countNode = element.querySelector('td.fl_i');
    final threadCount =
        // X5.
        countNode?.querySelector('span.xi2')?.parseCountNumber() ??
        (element.querySelector('td:nth-child(3) > span:nth-child(1)') ??
                // 旅行者 theme
                element.querySelector('td:nth-child(2) > span:nth-child(1)'))
            ?.firstEndDeepText()
            ?.parseToInt();
    final replyCount =
        // X5.
        countNode?.querySelector('span.xg1')?.parseCountNumber() ??
        (element.querySelector('td:nth-child(3) > span:nth-child(2)') ??
                // 旅行者 theme
                element.querySelector('td:nth-child(2) > span:nth-child(2)'))
            ?.firstEndDeepText()
            ?.split(' ')
            .lastOrNull
            ?.parseToInt();

    if (threadCount == null || replyCount == null) {
      talker.error(
        'failed to build forum: threadCount '
        'or replyCount not found',
      );
      return null;
    }

    final threadTodayCount =
        // X5 and Style 1: With avatar.
        //
        // <em class="xw0 xi1" title="今日"> (35)</em>
        (titleNode?.parent?.querySelector('em') ?? element.querySelector('td:nth-child(2) > h2 > em'))
            ?.firstEndDeepText()
            ?.split('(')
            .lastOrNull
            ?.split(')')
            .firstOrNull
            ?.parseToInt() ??
        // Style 2: With welcome text.
        (element.querySelector('td:nth-child(2) > h2 > em:nth-child(3)') ??
                // 旅行者 theme
                element.querySelector('td:nth-child(2) > h2 > em:nth-child(3)'))
            ?.firstEndDeepText()
            ?.parseToInt();

    final latestThreadNode =
        // X5.
        element.querySelector('td.fl_by > div') ??
        element.querySelector('td:nth-child(4) > div') ??
        // 旅行者 theme
        element.querySelector('td:nth-child(3) > div');
    final citeNode = latestThreadNode?.querySelector('cite');
    // Time text of latest thread is in span with title attribute when in recent 7 days, otherwise plain text in
    // cite node: <cite>2025-11-16 16:41 <a href="...">user</a></cite>
    final citeTimeText = citeNode?.nodes
        .firstWhereOrNull((e) => e.nodeType == uh.Node.TEXT_NODE && (e.text?.trim().isNotEmpty ?? false))
        ?.text
        ?.trim();
    final latestThreadTime =
        citeNode?.querySelector('span[title]')?.attributes['title']?.parseToDateTimeUtc8() ??
        citeTimeText?.parseToDateTimeUtc8();
    final latestThreadTimeText = citeNode?.querySelector('span')?.firstEndDeepText() ?? citeTimeText;
    final latestThreadUrl = latestThreadNode?.querySelector('a')?.firstHref();

    // Expanded layout only.
    final latestThreadTitle = latestThreadNode?.querySelector('a')?.firstEndDeepText()?.trim();
    final latestThreadUserName = citeNode?.querySelector('a')?.firstEndDeepText();
    final latestThreadUserUrl = citeNode?.querySelector('a')?.firstHref();

    final subForumList = element
        .querySelectorAll('td > p')
        .firstWhereOrNull((e) => e.nodes.firstOrNull?.text?.contains('子版块') ?? false)
        ?.querySelectorAll('a')
        .map((e) => (e.firstEndDeepText()?.trim(), e.attributes['href']))
        .whereType<(String, String)>()
        .toList();

    final subThreadList = _threadLinksOf(element.querySelectorAll('td > p a'));

    return Forum(
      forumID: forumID,
      url: url,
      name: name,
      iconUrl: iconUrl ?? '',
      threadCount: threadCount,
      replyCount: replyCount,
      threadTodayCount: threadTodayCount,
      latestThreadTime: latestThreadTime,
      latestThreadTimeText: latestThreadTimeText,
      latestThreadUrl: latestThreadUrl,
      // Expanded layout only.
      latestThreadTitle: latestThreadTitle,
      latestThreadUserName: latestThreadUserName,
      latestThreadUserUrl: latestThreadUserUrl,
      subForumList: subForumList,
      subThreadList: subThreadList,
    );
  }

  /// Build a [Forum] model from the collapsed layout node `<td class="fl_g">`.
  ///
  /// Discuz X5 layout:
  ///
  /// <td class="fl_g">
  ///   <div class="flex flex-column">
  ///     <div class="fl_icn_g"><a href="forum.php?mod=forumdisplay&fid=703"><img src="..." /></a></div>
  ///     <dl>
  ///       <dt><a href="forum.php?mod=forumdisplay&fid=703">动漫</a><em class="xw0 xi1" title="今日"> (10)</em></dt>
  ///       <dd><em>主题: 35</em>, <em>帖数: <span title="352345">35万</span></em></dd>
  ///       <dd><a href="forum.php?mod=redirect&tid=xxx&goto=lastpost#lastpost">最后发表: <span title="2026-9-4 18:46">1 小时前</span></a></dd>
  ///     </dl>
  ///   </div>
  /// </td>
  ///
  /// The last `<dd>` is "从未" if no thread in forum.
  ///
  /// Return null if the node is not a forum (name or url not found).
  static Forum? fromFlGNode(uh.Element element) {
    final titleNode =
        element.querySelector('div.tsdm_fl_inf > dl > dt > a') ??
        // X5 and style 5.
        element.querySelector('dl > dt > a');
    final name = titleNode?.firstEndDeepText()?.trim();
    final url = titleNode?.firstHref();
    final forumID = url?.uriQueryParameter('fid')?.parseToInt() ?? url?.split('fid=').lastOrNull?.parseToInt();
    if (name == null || url == null || forumID == null) {
      talker.error('failed to build collapsed forum: name=$name, fid=$forumID, url=$url');
      return null;
    }

    final iconUrl = (element.querySelector('div.fl_icn_g img') ?? element.querySelector('img'))
        ?.dataOriginalOrSrcImgUrl();

    final dlNode = element.querySelector('dl');
    // X5: <dd><em>主题: 35</em>, <em>帖数: <span title="352345">35万</span></em></dd>
    // Style 1: <dd><em><span>主题</span><span>35</span></em> ...
    // Style 3: <dd><em><font>主题</font><font>12345</font></em> ...
    final countEmList = dlNode?.querySelectorAll('dd > em').toList() ?? const [];
    final threadCount =
        countEmList.firstWhereOrNull((e) => e.innerText.contains('主题'))?.parseCountNumber() ??
        countEmList.elementAtOrNull(0)?.parseCountNumber();
    final replyCount =
        countEmList.firstWhereOrNull((e) => e.innerText.contains('帖数'))?.parseCountNumber() ??
        countEmList.elementAtOrNull(1)?.parseCountNumber();

    final threadTodayCount =
        // X5 and Style 5: <dt><a>name</a><em title="今日"> (10)</em></dt>
        dlNode
            ?.querySelector('dt > em')
            ?.firstEndDeepText()
            ?.split('(')
            .lastOrNull
            ?.split(')')
            .firstOrNull
            ?.parseToInt() ??
        // Style 1: third <em> in <dd>.
        countEmList.elementAtOrNull(2)?.firstEndDeepText()?.replaceFirst(' (', '').replaceFirst(')', '').parseToInt();

    final latestThreadNode = dlNode
        ?.querySelectorAll('dd > a')
        .firstWhereOrNull(
          (e) => e.attributes['href']?.contains('tid=') ?? false,
        );
    var latestThreadTime = latestThreadNode?.querySelector('span[title]')?.attributes['title']?.parseToDateTimeUtc8();
    // "最后发表: 1 小时前" or "最后发表: 2026-8-1 12:00"
    var latestThreadTimeText = latestThreadNode?.innerText.trim();
    if (latestThreadTimeText != null && latestThreadTimeText.contains('最后发表:')) {
      latestThreadTimeText = latestThreadTimeText.replaceFirst('最后发表:', '').trim();
    }
    if (latestThreadTime == null && latestThreadTimeText != null) {
      latestThreadTime = latestThreadTimeText.parseToDateTimeUtc8();
    }
    final latestThreadUrl = latestThreadNode?.firstHref();

    return Forum(
      forumID: forumID,
      url: url,
      name: name,
      iconUrl: iconUrl ?? '',
      threadCount: threadCount ?? -1,
      replyCount: replyCount ?? -1,
      threadTodayCount: threadTodayCount,
      latestThreadTime: latestThreadTime,
      latestThreadTimeText: latestThreadTimeText,
      latestThreadUrl: latestThreadUrl,
    );
  }
}
