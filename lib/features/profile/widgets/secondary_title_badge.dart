import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/constants.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/profile/bloc/current_title_cubit.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';

/// Shared height of badges beside a post author, independent of orientation.
const authorBadgeHeight = 32.0;

/// Shared height of badges in profile pages and dialogs.
const profileBadgeHeight = 64.0;

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

  /// Width preserving the title aspect ratio at the requested display height.
  static double widthFor(double height) => height * badgeImageSize.width / badgeImageSize.height;

  /// Width of a badge that should be about [preferred] wide in [available] room: never wider than the room, nor than
  /// the natural width of the image (a larger box would only upscale it).
  static double fitWidth(double available, {double preferred = 184}) =>
      math.max<double>(0, math.min(math.min(available, preferred), badgeImageSize.width));

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

/// Room of a secondary title of [width] that is not known yet: same size as the badge, so nothing jumps once it is.
class SecondaryTitlePlaceholder extends StatelessWidget {
  /// Constructor.
  const SecondaryTitlePlaceholder({required this.width, super.key});

  /// Width of the badge to come.
  final double width;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: SecondaryTitleBadge.heightFor(width),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
      ),
    ),
  );
}

/// A secondary title that could not be read: the badge room with a retry action.
///
/// It says the title failed to load, never that no title is in use.
class SecondaryTitleRetry extends StatelessWidget {
  /// Constructor.
  const SecondaryTitleRetry({required this.width, required this.onRetry, super.key});

  /// Width of the badge room.
  final double width;

  /// Read the title again.
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final message = '${context.t.profilePage.secondaryTitle} · ${context.t.general.failedToLoad}';
    return Tooltip(
      message: message,
      child: Semantics(
        button: true,
        label: '$message, ${context.t.general.retry}',
        excludeSemantics: true,
        child: SizedBox(
          width: width,
          // Room for the icon and a line of text even when the badge is small.
          height: math.max<double>(SecondaryTitleBadge.heightFor(width), 48),
          child: Material(
            color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onRetry,
              child: Padding(
                padding: edgeInsetsL4R4,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.refresh_outlined, size: 20, color: colorScheme.primary),
                    sizedBoxW2H2,
                    Text(
                      context.t.general.retry,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.labelMedium?.copyWith(color: colorScheme.primary),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Secondary title badge of the logged in account whose uid is [uid], from [CurrentTitleCubit].
///
/// Shows nothing when the cubit is not provided, the known title belongs to another account, or the account uses no
/// title. While the title is being read the badge room is kept ([SecondaryTitlePlaceholder]); when reading failed a
/// retry action takes it ([SecondaryTitleRetry]) instead of pretending no title is used. Asks the cubit to read the
/// title once when [load] is set. [padding] only applies when something is shown.
class CurrentAccountTitleBadge extends StatefulWidget {
  /// Constructor.
  const CurrentAccountTitleBadge({
    required this.uid,
    this.width = 92,
    this.load = true,
    this.padding = EdgeInsets.zero,
    super.key,
  });

  /// Uid of the account shown next to the badge; the badge only appears when it is the current account.
  final int? uid;

  /// Width of the badge.
  final double width;

  /// Request the title when it is not known yet.
  final bool load;

  /// Space around the badge, only when it is shown.
  final EdgeInsetsGeometry padding;

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
        final Widget child;
        if (url != null) {
          child = SecondaryTitleBadge(
            url,
            // Keyed by url: switching titles must not keep the frame of the previous image.
            key: ValueKey(url),
            width: widget.width,
            semanticLabel: state.title?.name,
          );
        } else {
          switch (state.statusFor(widget.uid)) {
            case CurrentTitleStatus.loading:
              child = SecondaryTitlePlaceholder(width: widget.width);
            case CurrentTitleStatus.failure:
              child = SecondaryTitleRetry(width: widget.width, onRetry: () => unawaited(cubit.ensureLoaded()));
            case CurrentTitleStatus.initial || CurrentTitleStatus.success:
              // Not requested for this account, or the account uses no title.
              return sizedBoxEmpty;
          }
        }
        return Padding(padding: widget.padding, child: child);
      },
    );
  }
}
