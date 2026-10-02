import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:tsdm_client/features/update/repository/release_update_repository.dart';
import 'package:tsdm_client/widgets/shutdown.dart';

/// Starts a process detached from the app, so it outlives it.
typedef DetachedLauncher = Future<void> Function(String executable, List<String> arguments);

/// Installs the portable Windows build over the folder the app runs from.
///
/// The running files are locked, so the verified zip is unpacked next to the downloads first, then a small
/// PowerShell script waits for the app to exit, copies the new files over the old ones and starts the app again. The
/// files it replaces are backed up first and put back when copying fails. Only the files of the release are written:
/// other files in the folder are left alone, and the user data lives in the application support folder anyway.
class WindowsUpdateInstaller implements UpdateInstaller {
  /// Optional dependencies support offline tests.
  WindowsUpdateInstaller({
    String? executable,
    String? updateDirectory,
    DetachedLauncher? launch,
    Future<void> Function()? quit,
  }) : _executable = executable,
       _updateDirectory = updateDirectory,
       _launch = launch ?? _launchDetached,
       _quit = quit ?? exitApp;

  final String? _executable;
  final String? _updateDirectory;
  final DetachedLauncher _launch;
  final Future<void> Function() _quit;

  /// Executable name inside the release zip and the installed folder.
  static const executableName = 'tsdm_client.exe';

  /// Top level folder of the release zip.
  static const releaseFolder = 'tsdm_client';

  /// Name of the update script written next to the downloads.
  static const scriptName = 'apply-update.ps1';

  /// Log written by the update script, kept for diagnosis.
  static const logName = 'update.log';

  static Future<void> _launchDetached(String executable, List<String> arguments) async {
    await Process.start(executable, arguments, mode: ProcessStartMode.detached);
  }

  @override
  UpdateTarget get target => UpdateTarget.windows;

  @override
  Future<String> directory() async =>
      _updateDirectory ?? p.join((await getApplicationSupportDirectory()).path, 'updates');

  @override
  Future<bool> canInstall() async => true;

  @override
  Future<bool> openPermissionSettings() async => false;

  @override
  Future<bool> install(DownloadedUpdate update) async {
    final executable = File(_executable ?? Platform.resolvedExecutable);
    final installDir = executable.parent;
    // A debug run or an unknown layout is not a portable release folder: never copy files into it.
    if (p.basename(executable.path).toLowerCase() != executableName ||
        !File(p.join(installDir.path, 'flutter_windows.dll')).existsSync()) {
      throw const UpdateDownloadException(UpdateDownloadFailure.unsupported);
    }
    _checkWritable(installDir);

    final updates = await directory();
    final staging = Directory(p.join(updates, 'staging-${update.versionCode}'));
    final backup = p.join(updates, 'backup-${update.versionCode}');
    try {
      if (staging.existsSync()) await staging.delete(recursive: true);
      await extractRelease(File(update.path), staging);
      final script = File(p.join(updates, scriptName));
      await script.writeAsString(updateScript, flush: true);
      await _launch('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        script.path,
        '-ProcessId',
        '$pid',
        '-Source',
        staging.path,
        '-Target',
        installDir.path,
        '-Backup',
        backup,
        '-Log',
        p.join(updates, logName),
      ]);
    } on FileSystemException {
      throw const UpdateDownloadException(UpdateDownloadFailure.storage);
    } on ProcessException {
      throw const UpdateDownloadException(UpdateDownloadFailure.install);
    }
    // Leave a moment for the page to show that the app restarts, then exit so the script can replace the files.
    unawaited(Future<void>.delayed(const Duration(milliseconds: 800), _quit));
    return true;
  }

  static void _checkWritable(Directory dir) {
    final probe = File(p.join(dir.path, '.tsdm_update_probe'));
    try {
      probe
        ..writeAsStringSync('')
        ..deleteSync();
    } on FileSystemException {
      throw const UpdateDownloadException(UpdateDownloadFailure.installLocation);
    }
  }

  /// Unpack the `tsdm_client` folder of the release [zip] into [destination].
  ///
  /// Every entry must sit under that folder with a plain relative path, and the result must hold the executable and
  /// the engine; otherwise nothing is installed.
  static Future<void> extractRelease(File zip, Directory destination) async {
    final input = InputFileStream(zip.path);
    try {
      final archive = ZipDecoder().decodeStream(input);
      await destination.create(recursive: true);
      final root = p.canonicalize(destination.path);
      final written = <String>{};
      for (final entry in archive.files) {
        final name = entry.name;
        if (!name.startsWith('$releaseFolder/') || name.contains(r'\') || name.contains(':')) {
          throw const UpdateDownloadException(UpdateDownloadFailure.integrity);
        }
        final segments = name.substring(releaseFolder.length + 1).split('/');
        if (segments.isNotEmpty && segments.last.isEmpty) segments.removeLast();
        if (segments.isEmpty) continue;
        if (segments.any((e) => e.isEmpty || e == '.' || e == '..')) {
          throw const UpdateDownloadException(UpdateDownloadFailure.integrity);
        }
        final target = p.joinAll([root, ...segments]);
        if (!p.isWithin(root, target)) {
          throw const UpdateDownloadException(UpdateDownloadFailure.integrity);
        }
        if (!entry.isFile) {
          await Directory(target).create(recursive: true);
          continue;
        }
        await Directory(p.dirname(target)).create(recursive: true);
        final output = OutputFileStream(target);
        try {
          entry.writeContent(output);
        } finally {
          await output.close();
        }
        written.add(segments.join('/').toLowerCase());
      }
      if (!written.contains(executableName) || !written.contains('flutter_windows.dll')) {
        throw const UpdateDownloadException(UpdateDownloadFailure.integrity);
      }
    } on ArchiveException {
      throw const UpdateDownloadException(UpdateDownloadFailure.integrity);
    } finally {
      await input.close();
    }
  }

  /// The script run after the app exits. ASCII only: Windows PowerShell reads a script without BOM in the ANSI code
  /// page. Paths come in as arguments, so non-ASCII folders are fine.
  static const updateScript = r'''
param(
  [Parameter(Mandatory = $true)][int]$ProcessId,
  [Parameter(Mandatory = $true)][string]$Source,
  [Parameter(Mandatory = $true)][string]$Target,
  [Parameter(Mandatory = $true)][string]$Backup,
  [Parameter(Mandatory = $true)][string]$Log
)
$ErrorActionPreference = 'Stop'
function Write-Log([string]$Message) {
  Add-Content -LiteralPath $Log -Value ('{0} {1}' -f (Get-Date -Format o), $Message) -Encoding UTF8
}
function Copy-WithRetry([string]$From, [string]$To) {
  $parent = Split-Path -Parent $To
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
  for ($i = 0; $i -lt 20; $i++) {
    try { Copy-Item -LiteralPath $From -Destination $To -Force; return } catch { Start-Sleep -Milliseconds 500 }
  }
  Copy-Item -LiteralPath $From -Destination $To -Force
}
Set-Content -LiteralPath $Log -Value '' -Encoding UTF8
try {
  $app = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  if ($app -and -not $app.WaitForExit(60000)) { throw 'the app did not exit' }
  Start-Sleep -Milliseconds 500
  $files = @(Get-ChildItem -LiteralPath $Source -Recurse -File | ForEach-Object {
    $_.FullName.Substring($Source.TrimEnd('\').Length).TrimStart('\')
  })
  if ($files.Count -eq 0) { throw 'nothing to install' }
  if (Test-Path -LiteralPath $Backup) { Remove-Item -LiteralPath $Backup -Recurse -Force }
  $replaced = @()
  foreach ($file in $files) {
    $old = Join-Path $Target $file
    if (Test-Path -LiteralPath $old -PathType Leaf) {
      Copy-WithRetry $old (Join-Path $Backup $file)
      $replaced += $file
    }
  }
  Write-Log ('backed up {0} files' -f $replaced.Count)
  $added = @()
  $copied = @()
  try {
    foreach ($file in $files) {
      $new = Join-Path $Target $file
      if (-not (Test-Path -LiteralPath $new)) { $added += $file }
      Copy-WithRetry (Join-Path $Source $file) $new
      $copied += $file
    }
    Write-Log ('installed {0} files' -f $files.Count)
  } catch {
    Write-Log ('install failed: {0}' -f $_)
    $failed = 0
    foreach ($file in ($replaced | Where-Object { $copied -contains $_ })) {
      try { Copy-WithRetry (Join-Path $Backup $file) (Join-Path $Target $file) } catch { $failed++; Write-Log ('not restored: {0}' -f $file) }
    }
    foreach ($file in $added) { Remove-Item -LiteralPath (Join-Path $Target $file) -Force -ErrorAction SilentlyContinue }
    if ($failed -eq 0) { Write-Log 'restored the previous version' } else { Write-Log ('restore incomplete, the previous files are in {0}' -f $Backup) }
  }
} catch {
  Write-Log ('failed: {0}' -f $_)
}
Start-Process -FilePath (Join-Path $Target 'tsdm_client.exe') -WorkingDirectory $Target
''';
}
