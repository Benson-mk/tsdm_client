import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/logger.dart';

/// The account this device acts as, and whether more than one account is saved (GitHub #184).
@immutable
final class CurrentAccountState {
  /// Constructor.
  const CurrentAccountState({this.user, this.accountCount = 0});

  /// The logged in account, null when not logged in.
  final UserLoginInfo? user;

  /// How many accounts are saved on this device.
  final int accountCount;

  /// Whether pages show which account is in use.
  ///
  /// Only with more than one saved account: with a single one there is nothing to confuse, and the app bars stay as
  /// short as before.
  bool get showsAccount => user != null && (user!.username?.isNotEmpty ?? false) && accountCount > 1;

  /// Username of [user], empty when not logged in.
  String get username => user?.username ?? '';

  /// Avatar of [user] on the forum, used when it is not cached yet; the cache is keyed by username.
  String? get avatarUrl => avatarUrlOfUid(user?.uid?.toString());

  @override
  bool operator ==(Object other) =>
      other is CurrentAccountState &&
      other.user?.uid == user?.uid &&
      other.user?.username == user?.username &&
      other.accountCount == accountCount;

  @override
  int get hashCode => Object.hash(user?.uid, user?.username, accountCount);
}

/// Follows the logged in account and the saved accounts, so pages can tell which account they act as (GitHub #184).
///
/// Users with several accounts sometimes replied with the wrong one: only the homepage showed the avatar.
final class CurrentAccountCubit extends Cubit<CurrentAccountState> with LoggerMixin {
  /// Constructor.
  ///
  /// [currentUser] reads the logged in account, re-read on every [authStatus] event. [accounts] streams the saved
  /// accounts.
  CurrentAccountCubit({
    required UserLoginInfo? Function() currentUser,
    required Stream<AuthStatus> authStatus,
    required Stream<List<UserLoginInfo>> accounts,
  }) : _currentUser = currentUser,
       super(CurrentAccountState(user: currentUser())) {
    _authSub = authStatus.listen((_) => _emit(user: _currentUser()));
    _accountsSub = accounts.listen((e) => _emit(accountCount: e.length));
  }

  final UserLoginInfo? Function() _currentUser;
  late final StreamSubscription<AuthStatus> _authSub;
  late final StreamSubscription<List<UserLoginInfo>> _accountsSub;

  void _emit({UserLoginInfo? user, int? accountCount}) {
    if (isClosed) {
      return;
    }
    emit(CurrentAccountState(user: user ?? _currentUser(), accountCount: accountCount ?? state.accountCount));
  }

  @override
  Future<void> close() async {
    await _authSub.cancel();
    await _accountsSub.cancel();
    return super.close();
  }
}
