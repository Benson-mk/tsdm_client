import 'package:flutter/material.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';

/// Network image with loading indicator.
class NetworkIndicatorImage extends StatelessWidget {
  /// Constructor.
  const NetworkIndicatorImage(
    this.src, {
    this.width,
    this.height,
    this.maxWidth,
    this.maxHeight,
    this.minWidth,
    this.minHeight,
    this.fit,
    super.key,
  });

  /// Image network source url.
  final String src;

  /// Fixed image width.
  final double? width;

  /// Fixed image height.
  final double? height;

  /// Max image width.
  final double? maxWidth;

  /// Max image height.
  final double? maxHeight;

  /// Min image width.
  final double? minWidth;

  /// Min image height.
  final double? minHeight;

  /// How the image is fitted into its box; null keeps the image's default (scaled down only, never enlarged).
  final BoxFit? fit;

  @override
  Widget build(BuildContext context) => CachedImage(
    src,
    width: width,
    height: height,
    maxWidth: maxWidth,
    maxHeight: maxHeight,
    minWidth: minWidth,
    minHeight: minHeight,
    fit: fit,
  );
}
