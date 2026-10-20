import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

/// A smiley of the forum: the [code] a member types in a post and the image the forum shows for it.
@immutable
final class Smiley {
  /// Constructor.
  const Smiley({required this.id, required this.code, required this.url, required this.type});

  /// The forum's id of the smiley.
  final int id;

  /// What a member types: `:)`, `{:1_1:}`…
  final String code;

  /// Absolute url of the image.
  final String url;

  /// The directory of its group (`default`, `qq`…).
  final String type;

  Map<String, Object?> _toJson() => {'id': id, 'code': code, 'url': url, 'type': type};
}

/// The forum's smilies table (plugin 2.7.0, the `smilies` action), in the order the forum replaces the codes: the
/// longer codes first (`:))` before `:)`), which is the order the app replaces them in too.
@immutable
final class SmiliesTable {
  /// Constructor.
  const SmiliesTable({required this.version, required this.smilies});

  /// The table of a `smilies` answer [json] (or of the copy this app saved, [toJson]); null when it is not one: no
  /// `version`, no `smilies`, or the forum's message (`ok` 0).
  static SmiliesTable? fromJson(Map<String, dynamic>? json) {
    if (json == null || (json.containsKey('ok') && json['ok'] != 1)) {
      return null;
    }
    final version = json['version'];
    final list = json['smilies'];
    if (version is! String || version.isEmpty || list is! List) {
      return null;
    }
    final smilies = <Smiley>[];
    for (final e in list.whereType<Map<String, dynamic>>()) {
      final code = e['code'];
      final url = e['url'];
      if (code is! String || code.isEmpty || url is! String || url.isEmpty) {
        continue;
      }
      smilies.add(
        Smiley(
          id: (e['id'] as num?)?.toInt() ?? 0,
          code: code,
          url: url.prependHost(),
          type: e['type'] is String ? e['type'] as String : '',
        ),
      );
    }
    return SmiliesTable(version: version, smilies: List.unmodifiable(smilies));
  }

  /// The version the forum names for the table (a hash of its content): the thread page answers name the version
  /// their floors were rendered with (`smilies_version`).
  final String version;

  /// The smilies in replacement order.
  final List<Smiley> smilies;

  /// What [fromJson] reads back.
  Map<String, Object?> toJson() => {'version': version, 'smilies': smilies.map((e) => e._toJson()).toList()};
}

/// Where the [SmiliesRepository] keeps the last table between runs.
abstract interface class SmiliesStore {
  /// The saved table, as [SmiliesTable.toJson] text; null when none was saved.
  Future<String?> read();

  /// Save [data].
  Future<void> write(String data);
}

/// [SmiliesStore] in the app database: one row of the key-value settings table under [key], which is not one of
/// the settings (no settings key, not in the settings map): no new table, no schema change.
final class StorageSmiliesStore implements SmiliesStore {
  /// Constructor.
  const StorageSmiliesStore(this._storage);

  final StorageProvider _storage;

  /// The name of the row.
  static const key = 'tsdmAppSmiliesTable';

  @override
  Future<String?> read() => _storage.getString(key);

  @override
  Future<void> write(String data) => _storage.saveString(key, data);
}

/// Asks the forum for its smilies table: the answer of the `smilies` action, null when there is none.
typedef SmiliesFetcher = Future<Map<String, dynamic>?> Function();

/// The forum's smilies table for the app's own post renderer, by version.
///
/// A thread page answer names the version of the table its floors were rendered with (`smilies_version`); a floor
/// that shows smilies asks [tableFor] that version. The table kept (in memory, and saved in [SmiliesStore] for the
/// next run) is used while its version is the same; another version fetches the table again, once: a failed or
/// still different answer is not asked again for that version for [retryAfter], so a page never polls the forum.
/// Nothing is asked before a floor needs smilies, which only happens with the experimental renderer on.
final class SmiliesRepository with LoggerMixin {
  /// Constructor.
  SmiliesRepository({required SmiliesStore store, SmiliesFetcher? fetch})
    : _store = store,
      _fetch = fetch ?? (() => TsdmAppApi.askWaiting(getIt.get<NetClientProvider>(), 'smilies'));

  final SmiliesStore _store;
  final SmiliesFetcher _fetch;

  /// How long a version whose fetch did not give that version is not asked again.
  static const retryAfter = Duration(minutes: 10);

  final _table = ValueNotifier<SmiliesTable?>(null);

  /// The table kept now; changes when a saved or fetched table arrives.
  ValueListenable<SmiliesTable?> get table => _table;

  bool _loaded = false;
  Future<void>? _pending;
  final _askedAt = <String, DateTime>{};

  /// The table of [version] when it is kept; otherwise null, and the saved or the forum's table is fetched in the
  /// background ([table] tells when it arrives).
  SmiliesTable? tableFor(String version) {
    final current = _table.value;
    if (current != null && current.version == version) {
      return current;
    }
    unawaited(ensure(version));
    return null;
  }

  /// Make sure the table of [version] is kept, as far as the saved copy and one fetch can; the table of [version]
  /// when it is, null otherwise.
  Future<SmiliesTable?> ensure(String version) async {
    while (_pending != null) {
      await _pending;
    }
    final current = _table.value;
    if (current == null || current.version != version) {
      final pending = _refresh(version);
      _pending = pending;
      try {
        await pending;
      } finally {
        _pending = null;
      }
    }
    final table = _table.value;
    return table != null && table.version == version ? table : null;
  }

  Future<void> _refresh(String version) async {
    if (!_loaded) {
      _loaded = true;
      try {
        final saved = await _store.read();
        final table = saved == null ? null : SmiliesTable.fromJson(_decode(saved));
        if (table != null && _table.value == null) {
          _table.value = table;
        }
      } on Exception catch (e) {
        error('failed to read the saved smilies table', e);
      }
      if (_table.value?.version == version) {
        return;
      }
    }
    final askedAt = _askedAt[version];
    if (askedAt != null && DateTime.now().difference(askedAt) < retryAfter) {
      return;
    }
    _askedAt[version] = DateTime.now();
    final Map<String, dynamic>? json;
    try {
      json = await _fetch();
    } on Exception catch (e) {
      error('failed to fetch the smilies table', e);
      return;
    }
    final table = SmiliesTable.fromJson(json);
    if (table == null) {
      info('no smilies table from the forum (wanted version $version)');
      return;
    }
    _table.value = table;
    try {
      await _store.write(jsonEncode(table.toJson()));
    } on Exception catch (e) {
      error('failed to save the smilies table', e);
    }
  }

  static Map<String, dynamic>? _decode(String text) {
    try {
      return switch (jsonDecode(text)) {
        final Map<String, dynamic> json => json,
        _ => null,
      };
    } on FormatException {
      return null;
    }
  }

  /// Release the notifier.
  void dispose() => _table.dispose();
}
