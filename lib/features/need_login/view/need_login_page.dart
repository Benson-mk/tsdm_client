import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// A page to show need to login hint.
///
/// This page can be used by:
/// 1. Pushing route to [ScreenPaths.needLogin] and redirect back.
/// 2. Embedded in another page, pass the redirect back route, parameters and
/// extra info to constructor.
///
/// When using like 1., will `pushNamed` back.
/// When using like 2., will `pushReplacementNamed` back.
class NeedLoginPage extends StatelessWidget {
  /// Constructor.
  const NeedLoginPage({
    required this.backUri,
    this.showAppBar = false,
    this.needPop = false,
    this.popCallback,
    super.key,
  });

  /// Only show app bar when using this page as an entire screen, not embedded.
  final bool showAppBar;

  /// When redirect back, use `push` or `pushReplacement`.
  final bool needPop;

  /// Router uri to redirect back after login.
  final Uri backUri;

  /// Callback funtion that will be called when login succeed before navigate
  /// back.
  final FutureOr<void> Function(BuildContext context)? popCallback;

  @override
  Widget build(BuildContext context) {
    // Same state view as the other empty and locked pages: icon block, message, one login action.
    return Scaffold(
      appBar: showAppBar ? AppBar(title: Text(context.t.appName)) : null,
      body: SafeArea(
        child: AppStateView(
          icon: Icons.lock_person_outlined,
          message: t.general.needLoginToSeeThisPage,
          action: FilledButton.icon(
            icon: const Icon(Icons.login_outlined),
            label: Text(t.loginPage.login),
            onPressed: () async {
              await context.pushNamed(ScreenPaths.login);
              if (!context.mounted) {
                return;
              }
              if (needPop) {
                await popCallback?.call(context);
                if (!context.mounted) {
                  return;
                }
                context.pushReplacement(backUri.toString());
              } else {
                await context.push(backUri.toString());
              }
            },
          ),
        ),
      ),
    );
  }
}
