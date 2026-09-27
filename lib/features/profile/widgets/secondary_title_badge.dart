import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/constants.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/profile/bloc/current_title_cubit.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';

/// Image of a secondary title (the forum's second badge, natively [badgeImageSize]).
///
/// The image is contained in a box of [width] with the natural aspect ratio, so it is never cropped nor stretched and
/// takes a predictable room; loading and broken images get the usual [CachedImage] placeholders.
class SecondaryTitleBadge extends StatelessWidget {
  /// Constructor.
  const SecondaryTitleBadge(this.imageUrl, {this.width = 92, this.semanticLabel, super.key});

  /// Image url, as rendered by the forum.
  final String imageUrl;

  /// Width of the box, the height follows the natural aspect ratio.
  final double width;

  /// Title name for screen readers, when known.
  final String? semanticLabel;

  /// Height of a badge [width] wide.
  static double heightFor(double width) => width * badgeImageSize.height / badgeImageSize.width;

  @override
  Widget build(BuildContext context) {
    final height = heightFor(width);
    return Semantics(
      image: true,
      label: semanticLabel,
      child: SizedBox(
        width: width,
        height: height,
        child: CachedImage(imageUrl, width: width, height: height, fit: BoxFit.contain),
      ),
    );
  }
}

/// Secondary title badge of the logged in account whose uid is [uid], from [CurrentTitleCubit].
///
/// Shows nothing when the cubit is not provided, the title is unknown or none is used, or the known title belongs to
/// another account. Asks the cubit to read the title once when [load] is set.
class CurrentAccountTitleBadge extends StatefulWidget {
  /// Constructor.
  const CurrentAccountTitleBadge({required this.uid, this.width = 92, this.load = true, super.key});

  /// Uid of the account shown next to the badge; the badge only appears when it is the current account.
  final int? uid;

  /// Width of the badge.
  final double width;

  /// Request the title when it is not known yet.
  final bool load;

  @override
  State<CurrentAccountTitleBadge> createState() => _CurrentAccountTitleBadgeState();
}

class _CurrentAccountTitleBadgeState extends State<CurrentAccountTitleBadge> {
  CurrentTitleCubit? _cubit;

  void _requestLoad() {
    final cubit = _cubit;
    if (widget.load && widget.uid != null && cubit != null) {
      unawaited(cubit.ensureLoaded());
    }
  }

  @override
  void initState() {
    super.initState();
    _cubit = context.readOrNull<CurrentTitleCubit>();
    _requestLoad();
  }

  @override
  void didUpdateWidget(CurrentAccountTitleBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uid != widget.uid) {
      _requestLoad();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cubit = _cubit;
    if (cubit == null) {
      return sizedBoxEmpty;
    }
    return BlocBuilder<CurrentTitleCubit, CurrentTitleState>(
      bloc: cubit,
      builder: (context, state) {
        final url = state.imageUrlFor(widget.uid);
        if (url == null) {
          return sizedBoxEmpty;
        }
        return SecondaryTitleBadge(
          url,
          // Keyed by url: switching titles must not keep the frame of the previous image.
          key: ValueKey(url),
          width: widget.width,
          semanticLabel: state.title?.name,
        );
      },
    );
  }
}
