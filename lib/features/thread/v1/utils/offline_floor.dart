import 'package:flutter/widgets.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';

/// Whether the floor built under [context] was read back from an offline copy of its thread ([ThreadState.isOffline]):
/// the actions that need the network (reply, rate, edit, report, vote, purchase, red packet) are not offered on it.
///
/// False outside a thread page (the floor of a notice).
bool isOfflineFloor(BuildContext context) => context.readOrNull<ThreadBloc>()?.state.isOffline ?? false;
