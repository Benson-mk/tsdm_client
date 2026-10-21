import 'package:tsdm_client/features/offline_thread/repository/offline_thread_repository.dart';
import 'package:tsdm_client/features/settings/models/models.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Repository to manage cached files.
class SettingsCacheRepository {
  /// Constructor.
  ///
  /// [offlineThreads] defaults to the app's own saved thread pages.
  const SettingsCacheRepository({OfflineThreadRepository? offlineThreads}) : _offlineThreads = offlineThreads;

  final OfflineThreadRepository? _offlineThreads;

  OfflineThreadRepository get _offline => _offlineThreads ?? OfflineThreadRepository();

  /// Clear all cache.
  Future<void> clearCache(CacheClearInfo clearInfo) async {
    if (clearInfo.clearOfflineThreads) {
      await _offline.clear();
      if (!clearInfo.clearImage && !clearInfo.clearEmoji && !clearInfo.clearLog) {
        // Only the offline thread pages were chosen: no file to touch.
        return;
      }
    }
    final imageCacheProvider = getIt.get<ImageCacheProvider>();
    await imageCacheProvider.clearCache(clearInfo);
    await closeLogSink();
    if (clearInfo.clearLog) {
      final logDir = await getLogDir();
      if (logDir.existsSync()) {
        for (final entity in logDir.listSync()) {
          await entity.delete(recursive: true);
        }
      }
    }
    await openLogSink();
    await getIt.get<StorageProvider>().clearUserAvatarInfo();
  }

  /// Calculate cache size.
  Future<CacheStorageInfo> calculateCache() async {
    final imageCacheProvider = getIt.get<ImageCacheProvider>();
    final files = await imageCacheProvider.calculateCache();
    return files.copyWith(offlineThreadSize: await _offline.size());
  }

  // void dispose() {
  //   _controller.close();
  // }
}
