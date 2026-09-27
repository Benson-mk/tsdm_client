import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/utils/show_bottom_sheet.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image_provider.dart';
import 'package:tsdm_client/widgets/copy_content_dialog.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// Page to show a detail image.
///
/// The image fills the page and keeps its pinch, double tap and drag zoom; a floating control bar at the bottom
/// resets the zoom, shows the cache statistics and opens the image actions (save, copy the url, reload, sticker).
final class ImageDetailPage extends StatefulWidget {
  /// Constructor.
  const ImageDetailPage(this.imageUrl, {super.key});

  /// Url to load the image.
  ///
  /// Usually this image is loaded from global cache.
  final String imageUrl;

  @override
  State<ImageDetailPage> createState() => _ImageDetailPageState();
}

class _ImageDetailPageState extends State<ImageDetailPage> {
  final _scaleStateController = PhotoViewScaleStateController();

  @override
  void dispose() {
    _scaleStateController.dispose();
    super.dispose();
  }

  Future<void> _showStatistics(BuildContext context) async {
    final tr = context.t.imageDetailPage;
    await showCopyContentDialogFutureBuilder(
      context: context,
      // Calling `then` is better than nested callback.
      // ignore: prefer_async_await
      contentFuture: getIt.get<ImageCacheProvider>().getEnsureCachedFullInfo(widget.imageUrl).then((imageInfo) {
        if (imageInfo == null) {
          return const [];
        }
        return <CopyableContent>[
          CopyableContent(name: tr.url, data: imageInfo.url),
          CopyableContent(name: tr.cacheName, data: imageInfo.fileName),
          CopyableContent(name: tr.cacheSize, data: imageInfo.cacheSize),
          CopyableContent(
            name: tr.sizeTitle,
            data: tr.sizeValue(width: imageInfo.width, height: imageInfo.height),
          ),
        ];
      }),
      errorBuilder: (_, err) => Center(child: Text(tr.failedToLoadWithReason(reason: '$err'))),
      title: tr.statistics,
      route: DialogPaths.imageDetail,
    );
  }

  Widget _buildControlBar(BuildContext context) {
    final tr = context.t.imageDetailPage;
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Padding(
        padding: edgeInsetsL4R4,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.fit_screen_outlined),
              tooltip: tr.fitToScreen,
              onPressed: () => _scaleStateController.scaleState = PhotoViewScaleState.initial,
            ),
            IconButton(
              icon: const Icon(Icons.info_outline),
              tooltip: tr.statistics,
              onPressed: () async => _showStatistics(context),
            ),
            IconButton(
              icon: const Icon(Icons.more_horiz),
              tooltip: context.t.imageBottomSheet.title,
              onPressed: () async =>
                  showImageActionBottomSheet(context: context, imageUrl: widget.imageUrl, showCheckDetail: false),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.imageDetailPage;
    return Scaffold(
      appBar: AppBar(title: Text(tr.title)),
      body: Stack(
        children: [
          // Full size viewer, not constrained by any reading width: the image keeps the whole page.
          Positioned.fill(
            child: PhotoView(
              imageProvider: CachedImageProvider(widget.imageUrl),
              scaleStateController: _scaleStateController,
              maxScale: 3.0,
              minScale: 0.3,
              initialScale: PhotoViewComputedScale.contained,
              backgroundDecoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerLowest),
              loadingBuilder: (_, _) => const CenteredCircularIndicator(),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Center(child: _buildControlBar(context)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
