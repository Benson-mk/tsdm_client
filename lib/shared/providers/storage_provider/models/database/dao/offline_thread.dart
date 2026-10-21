part of 'dao.dart';

/// DAO for table [OfflineThread].
@DriftAccessor(tables: [OfflineThread])
final class OfflineThreadDao extends DatabaseAccessor<AppDatabase> with _$OfflineThreadDaoMixin {
  /// Constructor.
  OfflineThreadDao(super.attachedDatabase);

  Expression<bool> _isKey(
    $OfflineThreadTable e, {
    required int uid,
    required int tid,
    required int page,
    required int orderType,
    required int authorId,
  }) =>
      e.uid.equals(uid) &
      e.tid.equals(tid) &
      e.page.equals(page) &
      e.orderType.equals(orderType) &
      e.authorId.equals(authorId);

  /// Insert or replace the page.
  Future<void> upsert(OfflineThreadCompanion companion) async {
    await into(offlineThread).insertOnConflictUpdate(companion);
  }

  /// The saved page of the key, null when none.
  Future<OfflineThreadEntity?> selectPage({
    required int uid,
    required int tid,
    required int page,
    required int orderType,
    required int authorId,
  }) async =>
      (select(offlineThread)..where(
            (e) => _isKey(e, uid: uid, tid: tid, page: page, orderType: orderType, authorId: authorId),
          ))
          .getSingleOrNull();

  /// Mark the page of the key used at [time].
  Future<void> touch({
    required int uid,
    required int tid,
    required int page,
    required int orderType,
    required int authorId,
    required DateTime time,
  }) async {
    await (update(offlineThread)..where(
          (e) => _isKey(e, uid: uid, tid: tid, page: page, orderType: orderType, authorId: authorId),
        ))
        .write(OfflineThreadCompanion(lastUsedAt: Value(time.millisecondsSinceEpoch)));
  }

  /// Every saved page, without the bodies, for tests and checks.
  Future<List<OfflineThreadEntity>> selectAll() async => select(offlineThread).get();

  /// Delete every saved page of thread [tid] for user [uid].
  Future<int> deleteThread({required int uid, required int tid}) async =>
      (delete(offlineThread)..where((e) => e.uid.equals(uid) & e.tid.equals(tid))).go();

  /// Delete every saved page of user [uid].
  Future<int> deleteByUid(int uid) async => (delete(offlineThread)..where((e) => e.uid.equals(uid))).go();

  /// Delete all saved pages.
  Future<int> deleteAll() async => delete(offlineThread).go();

  /// Total size of the saved bodies in bytes.
  Future<int> totalSize() async {
    final sum = offlineThread.size.sum();
    final row = await (selectOnly(offlineThread)..addColumns([sum])).getSingle();
    return row.read(sum) ?? 0;
  }

  /// Whether no page is saved.
  Future<bool> isEmpty() async {
    final row =
        await (selectOnly(offlineThread)
              ..addColumns([offlineThread.uid])
              ..limit(1))
            .getSingleOrNull();
    return row == null;
  }

  /// Keep the [limit] most recently used pages of thread [tid] for user [uid] (any page, order and author filter);
  /// delete the others. Returns the number of pages deleted.
  Future<int> keepRecentPages({required int uid, required int tid, required int limit}) async {
    if (limit < 0) {
      return 0;
    }
    return customUpdate(
      'DELETE FROM offline_thread WHERE uid = ?1 AND tid = ?2 AND rowid NOT IN ( '
      'SELECT rowid FROM offline_thread WHERE uid = ?1 AND tid = ?2 '
      'ORDER BY last_used_at DESC, page, order_type, author_id LIMIT ?3 '
      ')',
      variables: [Variable.withInt(uid), Variable.withInt(tid), Variable.withInt(limit)],
      updates: {offlineThread},
      updateKind: UpdateKind.delete,
    );
  }

  /// Keep the [limit] most recently used threads (one thread being one account and one tid, whatever its pages);
  /// delete the pages of the others. Returns the number of pages deleted.
  Future<int> keepRecentThreads(int limit) async {
    if (limit < 0) {
      return 0;
    }
    return customUpdate(
      'DELETE FROM offline_thread WHERE (uid, tid) NOT IN ( '
      'SELECT uid, tid FROM offline_thread GROUP BY uid, tid '
      'ORDER BY MAX(last_used_at) DESC, uid, tid LIMIT ? '
      ')',
      variables: [Variable.withInt(limit)],
      updates: {offlineThread},
      updateKind: UpdateKind.delete,
    );
  }
}
