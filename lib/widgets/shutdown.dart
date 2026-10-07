import 'dart:io';

import 'package:flutter/services.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/platform.dart';

/// Graceful shutdown.
///
/// Closing the storage is tried for a moment only: on desktop the process must end whatever happens there, the
/// Windows update script waits for it before replacing the files (GitHub #172).
Future<void> exitApp() async {
  try {
    await getIt.get<StorageProvider>().dispose().timeout(const Duration(seconds: 3));
  } on Object catch (e, st) {
    talker.handle(e, st, 'failed to close the storage before exit');
  }
  // Close the app.
  if (isAndroid || isIOS) {
    await SystemNavigator.pop(animated: true);
  } else {
    // CAUTION: unsafe operation.
    exit(0);
  }
}
