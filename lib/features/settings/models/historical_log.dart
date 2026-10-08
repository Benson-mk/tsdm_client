import 'dart:io';

/// Log file.
final class HistoricalLog {
  /// Constructor.
  const HistoricalLog(this.time, this.file, {this.background = false});

  /// Time of the log, in days.
  final DateTime time;

  /// File entity to the log file.
  final File file;

  /// Written by the Android background message service (`tsdm_client_bg_<day>.log`), not by the app itself.
  final bool background;
}
