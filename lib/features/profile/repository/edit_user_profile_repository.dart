import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/profile/models/birthday_info.dart';
import 'package:tsdm_client/features/profile/models/editable_user_profile.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

typedef _Keys = UserProfileKeys;

/// The repository provide functionality about editing user profile.
final class EditUserProfileRepository with LoggerMixin {
  AsyncEither<UserProfile> _parseProfilePage(uh.Document doc) => AsyncEither(() async {
    final v = doc.querySelector('form[target="frame_profile"]');
    if (v == null) {
      error('failed to fetch editable user profile: form not found');
      return left(EditUserProfileFormNotFound());
    }
    final profile = UserProfile.fromForm(v);
    if (profile == null) {
      error('failed to fetch editable user profile: invalid form');
      return left(EditUserProfileFormNotFound());
    }

    return right(profile);
  });

  /// Load profile from page.
  AsyncEither<UserProfile> loadProfile() => getIt
      .get<NetClientProvider>()
      .get('$baseUrl/home.php?mod=spacecp')
      .mapHttp((v) => parseHtmlDocument(v.data as String))
      .flatMap(_parseProfilePage);

  /// Upload user profile [profile] to server.
  ///
  /// The forum answers the editor's frame a `parent.show_success('')` script when the profile was saved, and its
  /// 提示信息 page otherwise. With the forum's app API (plugin 2.6.0) that comes as the write result
  /// ([tsdmAppWriteResultOf]): the script as a `page` (a `parent.show_error(` page is not `ok`), the message as a
  /// `message` with its verdict; an older plugin answers the forum's page, read as before.
  AsyncVoidEither uploadProfile(UserProfile profile) => getIt
      .get<NetClientProvider>()
      .postMultipartForm(
        '$baseUrl/home.php?mod=spacecp&ac=profile&op=base',
        data: <String, String>{
          'formhash': profile.formHash,
          _Keys.gender: profile.gender.value.toString(),
          _Keys.gender.visibility(): profile.genderVisibility.value.toString(),
          _Keys.birthYear: '${profile.birthdayYear ?? "0"}',
          _Keys.birthMonth: '${profile.birthdayMonth ?? "0"}',
          _Keys.birthday: '${profile.birthdayDay ?? "0"}',
          _Keys.birthday.visibility(): profile.birthdayVisibility.value.toString(),
          _Keys.qq: '${profile.qq ?? ""}',
          _Keys.qq.visibility(): profile.qqVisibility.value.toString(),
          _Keys.msn: profile.msn ?? '',
          _Keys.msn.visibility(): profile.msnVisibility.value.toString(),
          _Keys.homepage: profile.homepage ?? '',
          _Keys.homepage.visibility(): profile.homepageVisibility.value.toString(),
          _Keys.bio: profile.bio,
          _Keys.bio.visibility(): profile.bioVisibility.value.toString(),
          _Keys.hobby: profile.hobby ?? '',
          _Keys.hobby.visibility(): profile.hobbyVisibility.value.toString(),
          _Keys.location: profile.location ?? '',
          _Keys.location.visibility(): profile.locationVisibility.value.toString(),
          _Keys.nickname: profile.nickname ?? '',
          _Keys.nickname.visibility(): profile.nicknameVisibility.value.toString(),
          _Keys.wordsToSay: profile.wordsToSay ?? '',
          _Keys.wordsToSay.visibility(): profile.wordsToSayVisibility.value.toString(),
          _Keys.skill: profile.skill ?? '',
          _Keys.skill.visibility(): profile.skillVisibility.value.toString(),
          _Keys.favoriteBangumi: profile.favoriteBangumi ?? '',
          _Keys.favoriteBangumi.visibility(): profile.favoriteBangumiVisibility.value.toString(),
          _Keys.pageStyle: profile.pageStyle?.value.toString() ?? '0',
          _Keys.customTitle: profile.customTitle ?? '',
          _Keys.signature: profile.signature ?? '',
          _Keys.timezone: profile.timeZone?.value ?? '0',
          'profilesubmit': 'true',
          'profilesubmitbtn': 'true',
        },
      )
      .mapHttp((v) => v.data)
      .flatMap((data) {
        final result = tsdmAppWriteResultOf(data);
        final bool saved;
        final String? failure;
        if (result != null) {
          // As without the plugin: the editor's frame is answered `parent.show_success('')` when the profile was
          // saved (a `page`; a `parent.show_error(` page is not `ok`). A 提示信息 page counts only when the forum
          // shows it as a success (`alert_right`): the hook of an AJAX form, a redirect or a note is no proof.
          saved = switch (result.kind) {
            TsdmAppWriteKind.page => result.ok && result.documentHtml.contains('show_success'),
            TsdmAppWriteKind.message => result.succeeded && result.alert == 'right',
            TsdmAppWriteKind.handle || TsdmAppWriteKind.redirect => false,
          };
          failure = result.reason.isNotEmpty
              ? result.reason
              : result.document.querySelector('div#messagetext > p')?.innerText;
        } else {
          final doc = tsdmAppAnswerText(data);
          saved = doc.contains('show_success');
          failure = parseHtmlDocument(doc).querySelector('div#messagetext > p')?.innerText;
        }
        if (saved) {
          return TaskEither<AppException, void>.right(null);
        }
        error('failed to upload user profile: $failure');
        return TaskEither<AppException, void>.left(EditUserProfileUploadFailed());
      });
}
