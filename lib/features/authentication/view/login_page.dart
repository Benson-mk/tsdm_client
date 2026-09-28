import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/bloc/authentication_bloc.dart';
import 'package:tsdm_client/features/authentication/widgets/login_form.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// Widest the login form grows.
const _loginFormMaxWidth = 520.0;

/// Page of user to login.
class LoginPage extends StatefulWidget {
  /// Constructor.
  const LoginPage({this.redirectBackState, this.username, super.key});

  /// The redirect back route that navigator will push when logged in succeed.
  final GoRouterState? redirectBackState;

  /// Optional autofilled username field in login form.
  final String? username;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.t.loginPage.title)),
      body: BlocProvider(
        create: (context) =>
            AuthenticationBloc(authenticationRepository: context.repo())..add(AuthenticationFetchLoginHashRequested()),
        child: BlocListener<AuthenticationBloc, AuthenticationState>(
          listener: (context, state) {
            if (state.status == AuthenticationStatus.failure) {
              showSnackBar(context: context, message: loginErrorText(context, state.loginException));
            }
          },
          // One scroll view for the whole form: it used to be a list capped at 500 pixels in the middle of the page,
          // which left little room with the keyboard up or at large text scales.
          child: SafeArea(
            top: false,
            child: AppCenteredList(
              maxWidth: _loginFormMaxWidth,
              builder: (context, padding, _) => LoginForm(
                padding: padding.copyWith(top: 24, bottom: 24),
                redirectPath: widget.redirectBackState?.fullPath,
                redirectPathParameters: widget.redirectBackState?.pathParameters,
                redirectExtra: widget.redirectBackState?.extra,
                username: widget.username,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
