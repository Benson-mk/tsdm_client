import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';

/// The messages of the forum's thread page (`forum.php?mod=viewthread`, with the forum checks it runs first) that mean
/// the thread is gone or not viewable for the account asking, by key of the forum's message language pack
/// (`source/i18n/SC_UTF8/lang_message.php`, `TC_UTF8`): the visible sentence of each, up to its first tag, with its
/// placeholders (`{readperm}`…) standing for any text.
///
/// Every other message keeps the saved pages: a request refused for being too frequent, the forum closed for
/// maintenance, the antitheft challenge, a page without the floors asked for (`post_not_found`), the login prompt, a
/// message a forum administrator wrote. A priced forum or thread is no message: the forum redirects to the forum page,
/// or prints the purchase lock in the first floor.
const offlineThreadRefusals = <String, List<String>>{
  // The thread does not exist, was deleted, or waits for moderation.
  'thread_nonexistence': ['抱歉，指定的主题不存在或已被删除或正在被审核', '抱歉，指定的主題不存在或已被刪除或正在被審核'],
  // The thread asks a higher read permission.
  'thread_nopermission': ['抱歉，本帖要求阅读权限高于 {readperm} 才能浏览', '抱歉，本帖要求閲讀權限高於 {readperm} 才能瀏覽'],
  // The user group of the account may not read.
  'group_nopermission': ['抱歉，您所在的用户组({grouptitle})无法进行此操作', '抱歉，您所在的用戶組({grouptitle})無法進行此操作'],
  // The forum of the thread is not viewable for the user group.
  'viewperm_none_nopermission': ['抱歉，您没有权限访问该版块', '抱歉，您沒有權限訪問該版塊'],
  'viewperm_upgrade_nopermission': ['抱歉，您需要升级您所在的用户组后才能访问该版块，详细请', '抱歉，您需要升級您所在的用戶組後才能訪問該版塊，詳細請'],
  'forum_access_view_disallow': ['抱歉，您在本版没有权限进行此操作', '抱歉，您在本版沒有權限進行此操作'],
  // The forum asks credits, a medal, or lists the users who may enter.
  'forum_permforum_nopermission': ['您需要满足以下条件才能访问这个版块', '您需要滿足以下條件才能訪問這個版塊'],
  'forum_permforum_nomedal': ['您需要拥有以下勋章才能访问这个版块', '您需要擁有以下勳章才能訪問這個版塊'],
  'forum_permforum_disallow': ['本版块只有特定用户可以访问', '本版塊只有特定用戶可以訪問'],
};

final List<RegExp> _refusals = [
  for (final sentences in offlineThreadRefusals.values)
    for (final sentence in sentences)
      RegExp(
        '^${sentence.split(RegExp(r'\{[a-z_]+\}')).map(RegExp.escape).join('.+?')}',
      ),
];

/// Whether the thread page [page] is the forum refusing the thread to the account that asked: the forum's message
/// (a structured answer `ok 0, error message` with `login 0`, or the web page's `#messagetext` without the login form)
/// whose text is one of [offlineThreadRefusals]. The saved pages of the thread are deleted for that account then.
bool forumRefusesThread(ThreadPageInfo page) {
  if (page.havePermission || page.needLogin) {
    return false;
  }
  final text = (page.permissionDeniedMessage?.text ?? '').replaceAll(RegExp(r'[\s ]+'), ' ').trim();
  return text.isNotEmpty && _refusals.any((e) => e.hasMatch(text));
}
