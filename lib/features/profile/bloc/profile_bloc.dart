import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/profile/models/models.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
import 'package:tsdm_client/features/profile/utils/profile_page_api.dart';
import 'package:tsdm_client/utils/logger.dart';

part 'profile_bloc.mapper.dart';
part 'profile_event.dart';
part 'profile_state.dart';

/// Emitter
typedef _Emitter = Emitter<ProfileState>;

/// Bloc of user profile page.
///
/// This profile page is for current logged user.
///
/// Actually other user's profile page should have a similar bloc but
/// without [ProfileStatus.needLogin] status.
class ProfileBloc extends Bloc<ProfileEvent, ProfileState> with LoggerMixin {
  /// Constructor.
  ProfileBloc({
    required ProfileRepository profileRepository,
    required AuthenticationRepository authenticationRepository,
  }) : _profileRepository = profileRepository,
       _authenticationRepository = authenticationRepository,
       super(const ProfileState()) {
    on<ProfileEvent>(
      (event, emit) => switch (event) {
        ProfileLoadRequested(:final username, :final uid) => _onLoadRequested(emit, username: username, uid: uid),
        ProfileRefreshRequested(:final uid, :final username) => _onRefreshRequested(emit, uid: uid, username: username),
        ProfileLogoutRequested() => _onLogoutRequested(emit),
      },
    );
  }

  final ProfileRepository _profileRepository;
  final AuthenticationRepository _authenticationRepository;

  Future<void> _onLoadRequested(_Emitter emit, {String? username, String? uid}) async {
    if (username == null && uid == null && _profileRepository.hasCache()) {
      final cached = _profileRepository.getCache()!;
      (await buildProfilePage(cached).run()).match(
        (e) {
          if (e case ProfileNeedLoginException()) {
            emit(state.copyWith(status: ProfileStatus.needLogin));
            return;
          }
          emit(state.copyWith(status: ProfileStatus.failure, failedToLogoutReason: e));
        },
        (v) {
          final (unreadNoticeCount, hasUnreadMessage) = unreadInfoOf(cached);
          emit(
            state.copyWith(
              status: ProfileStatus.success,
              userProfile: v,
              unreadNoticeCount: unreadNoticeCount,
              hasUnreadMessage: hasUnreadMessage,
              secondaryTitleUrl: secondaryTitleUrlOf(cached),
            ),
          );
        },
      );
      return;
    }
    emit(state.copyWith(status: ProfileStatus.loading));
    final pageEither = await _profileRepository.fetchProfile(username: username, uid: uid).run();
    if (pageEither.isLeft()) {
      final err = pageEither.unwrapErr();
      handle(err);
      if (err case ProfileNeedLoginException()) {
        emit(state.copyWith(status: ProfileStatus.needLogin));
        return;
      }
      emit(state.copyWith(status: ProfileStatus.failure));
      return;
    }
    final page = pageEither.unwrap();

    (await buildProfilePage(page).run()).match(
      (e) {
        if (e case ProfileNeedLoginException()) {
          // The forum's own login prompt (the structured answer of a guest): the session expired.
          emit(state.copyWith(status: ProfileStatus.needLogin));
          return;
        }
        error('failed to parse user profile: $e');
        emit(state.copyWith(status: ProfileStatus.failure, failedToLogoutReason: e));
      },
      (v) {
        final (unreadNoticeCount, hasUnreadMessage) = unreadInfoOf(page);
        emit(
          state.copyWith(
            status: ProfileStatus.success,
            userProfile: v,
            unreadNoticeCount: unreadNoticeCount,
            hasUnreadMessage: hasUnreadMessage,
            secondaryTitleUrl: secondaryTitleUrlOf(page),
          ),
        );
      },
    );
  }

  Future<void> _onRefreshRequested(_Emitter emit, {required String? uid, required String? username}) async {
    emit(state.copyWith(status: ProfileStatus.loading));
    final pageEither = await _profileRepository.fetchProfile(uid: uid, username: username, force: true).run();
    if (pageEither.isLeft()) {
      final err = pageEither.unwrapErr();
      handle(err);
      if (err case ProfileNeedLoginException()) {
        emit(state.copyWith(status: ProfileStatus.needLogin));
        return;
      }
      emit(state.copyWith(status: ProfileStatus.failure));
      return;
    }
    final page = pageEither.unwrap();
    (await buildProfilePage(page).run()).match(
      (e) {
        if (e case ProfileNeedLoginException()) {
          emit(state.copyWith(status: ProfileStatus.needLogin));
          return;
        }
        error('failed to parse user profile: $e');
        emit(state.copyWith(status: ProfileStatus.failure, failedToLogoutReason: e));
        return;
      },
      (v) {
        final (unreadNoticeCount, hasUnreadMessage) = unreadInfoOf(page);
        emit(
          state.copyWith(
            status: ProfileStatus.success,
            userProfile: v,
            unreadNoticeCount: unreadNoticeCount,
            hasUnreadMessage: hasUnreadMessage,
            secondaryTitleUrl: secondaryTitleUrlOf(page),
          ),
        );
      },
    );
  }

  Future<void> _onLogoutRequested(_Emitter emit) async {
    // The account the page shows when the logout was asked: a switch finishing meanwhile must not log out the account
    // switched to.
    final logout = _authenticationRepository.logout(uid: _authenticationRepository.currentUser?.uid);
    emit(state.copyWith(status: ProfileStatus.loggingOut));
    await logout.match((e) {
      if (e is IdentityChangedException) {
        // Nobody logged out: the page follows the account in use by itself.
        emit(state.copyWith(status: ProfileStatus.success));
        return;
      }
      handle(e);
      emit(state.copyWith(status: ProfileStatus.success, failedToLogoutReason: e));
    }, (_) => emit(state.copyWith(status: ProfileStatus.needLogin))).run();
  }
}
