import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:tsdm_client/constants/constants.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// Page to show app license and license of dependencies.
///
/// The list of packages and the license texts are the Flutter [LicensePage] (with its own master/detail layout on
/// wide windows); this page only frames its loading and failure states the same way as the other pages.
class AppLicensePage extends StatelessWidget {
  /// Constructor.
  const AppLicensePage({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: rootBundle.loadString(assetsLicensePath),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            appBar: AppBar(title: Text(context.t.aboutPage.license)),
            body: AppStateView(
              icon: Icons.error_outline,
              error: true,
              message: '${context.t.general.failedToLoad}: ${snapshot.error}',
            ),
          );
        }
        if (snapshot.hasData) {
          return LicensePage(
            applicationName: context.t.appName,
            applicationVersion: appFullVersion,
            applicationIcon: Column(
              mainAxisSize: MainAxisSize.min,
              children: [sizedBoxW12H12, SvgPicture.asset(assetsLogoSvgPath, width: 120, height: 120), sizedBoxW12H12],
            ),
            applicationLegalese: snapshot.data,
          );
        }
        return Scaffold(
          appBar: AppBar(title: Text(context.t.aboutPage.license)),
          body: const CenteredCircularIndicator(),
        );
      },
    );
  }
}
