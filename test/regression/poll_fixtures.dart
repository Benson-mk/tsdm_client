// Synthetic identities, tokens and content only. Field names follow the observed X5 poll form (#128).
import 'package:dio/dio.dart';

String pollPage(String body, {int uid = 1000, String head = ''}) =>
    '<html><head><script>var discuz_uid = \'$uid\';</script>$head</head><body>$body</body></html>';

const pollTypeSelect = '''
<div class="pbt cl"><div class="ftid"><select name="typeid" id="typeid">
<option value="0">Choose type</option><option value="7">Synthetic type</option></select></div></div>''';

const pollPluginNeutral = '''
<input type="text" name="pollplusviewcredit" value="0"><input type="text" name="pollpluslockday" value="0">''';

String pollForm({
  int uid = 1000,
  String fid = '4',
  String action = 'forum.php?mod=post&amp;action=newthread&amp;fid=4&amp;extra=&amp;topicsubmit=yes',
  String maxOptionsScript = "var maxoptions = parseInt('100');",
  String typeSelect = '',
  String plugin = '',
  String flags = '''
<label><input type="checkbox" name="visibilitypoll" id="visibilitypoll" value="1">Visible after voting</label>
<label><input type="checkbox" name="overt" id="overt" value="1">Public voters</label>''',
  String special = '1',
  String extra = '',
  bool bulk = true,
}) => pollPage('''
<div id="pt"><div class="z"><a href="forum.php?mod=forumdisplay&amp;fid=$fid">Synthetic forum</a></div></div>
<div id="ct"><form id="postform" method="post" action="$action">
<input type="hidden" name="formhash" value="synthetic-token">
<input type="hidden" name="posttime" id="posttime" value="1700000000">
<input type="hidden" name="wysiwyg" id="e_mode" value="0">
<input type="hidden" name="special" value="$special">
<input type="hidden" name="polls" value="yes">
<input type="hidden" name="fid" value="$fid">
<input type="hidden" name="tpolloption" value="1">
<input type="hidden" id="postsave" name="save" value="">
<div id="postbox">
$typeSelect
<div class="pbt cl"><div class="z"><span><input type="text" name="subject" id="subject" class="px" value="" onkeyup="strLenCalc(this, 'checklen', 255);"></span></div></div>
<div class="exfm cl">
<div id="polloption_new" style="display: none"><p><input type="text" name="polloption[]" class="px vm"><input type="hidden" name="pollimage[]" value=""></p></div>
${bulk ? '<textarea name="polloptions" style="display: none"></textarea>' : ''}
<input type="text" name="maxchoices" value="1">
<input type="text" name="expiration" value="">
$flags
$plugin
<script type="text/javascript">$maxOptionsScript</script>
</div>
<div class="area"><textarea name="message" id="e_textarea"></textarea></div>
</div>
<div id="extra_additional_c"><label for="usesig"><input type="checkbox" name="usesig" id="usesig" value="1" checked="checked">Use signature</label></div>
$extra
</form></div>''', uid: uid);

String pollMessage(String text, {String cls = 'alert_right', String? link, int uid = 1000}) => pollPage('''
<div id="messagetext" class="$cls"><p>$text</p>
${link == null ? '' : '<p class="alert_btnleft"><a href="$link">Continue</a></p>'}</div>''', uid: uid);

/// Thread as its author sees it; [label] goes where X5 prints moderating/ignored/draft markers.
String pollThread({String tid = '321', String label = '', int uid = 1000, String body = 'Synthetic poll body'}) =>
    pollPage(
      '''
<div id="postlist"><div><h1 class="ts"><span id="thread_subject">Synthetic poll</span></h1>
<span class="xg1">$label <a href="forum.php?mod=viewthread&amp;tid=$tid">[Copy link]</a></span></div>
<div id="post_654"><table><tr><td class="plc"><div class="pi"><strong><a href="forum.php?mod=viewthread&amp;tid=$tid"><em>1</em></a></strong></div>
<div class="pcb">$body</div></td></tr></table></div></div>''',
      uid: uid,
      head: '<link rel="canonical" href="forum.php?mod=viewthread&amp;tid=$tid">',
    );

String forumWithPollLink({int uid = 1000, String fid = '4', String where = 'menu'}) => pollPage('''
${where == 'menu' ? '<ul id="newspecial_menu"><li><a href="forum.php?mod=post&amp;action=newthread&amp;fid=$fid&amp;special=1">Create poll</a></li></ul>' : ''}
<div id="forum_rules_$fid">${where == 'rules' ? '<a href="forum.php?mod=post&amp;action=newthread&amp;fid=$fid&amp;special=1">poll</a>' : ''}</div>
<a href="forum.php?mod=forumdisplay&amp;fid=$fid&amp;filter=specialtype&amp;specialtype=poll">Polls</a>
<table><tbody id="normalthread_1"><tr><th>${where == 'thread' ? '<a href="forum.php?mod=post&amp;action=newthread&amp;fid=$fid&amp;special=1">x</a>' : ''}</th></tr></tbody></table>
''', uid: uid);

Response<dynamic> pollResponse(String data, {int status = 200, String? location}) => Response<dynamic>(
  requestOptions: RequestOptions(),
  data: data,
  statusCode: status,
  headers: Headers.fromMap({
    if (location != null) 'location': [location],
  }),
);
