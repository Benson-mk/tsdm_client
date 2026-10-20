import 'package:bloc/bloc.dart';
import 'package:collection/collection.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/post_report/utils/report_page_context.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;

part 'notification_detail_cubit.mapper.dart';

part 'notification_detail_state.dart';

/// Cubit of the notification detail page.
class NotificationDetailCubit extends Cubit<NotificationDetailState> with LoggerMixin {
  /// Constructor.
  NotificationDetailCubit({required NotificationRepository notificationRepository})
    : _notificationRepository = notificationRepository,
      super(const NotificationDetailState());

  static final _pidRe = RegExp(r'pid=(?<pid>\d+)');
  static final _tidRe = RegExp(r'ptid=(?<ptid>\d+)');

  final NotificationRepository _notificationRepository;

  /// Fetch notification detail from [url].
  ///
  /// Usually the [url] is a thread page and the logic below is trying to get
  /// the corresponding post in thread.
  ///
  /// The page built from the structured answer of the forum's app API gives the floor, the reply form and whether
  /// the thread is closed as its fields ([_fromBuiltPage]); the document of any other answer is parsed as before
  /// ([_fromDocument]).
  Future<void> fetchDetail(String url) async {
    emit(state.copyWith(status: NotificationDetailStatus.loading));
    await _notificationRepository
        .fetchNoticeThread(url)
        .match(
          (e) {
            handle(e);

            error('failed to fetch notification detail: $e');
            emit(state.copyWith(status: NotificationDetailStatus.failed));
          },
          (v) {
            final match = _pidRe.firstMatch(url);
            final pid = match?.namedGroup('pid');
            if (pid == null) {
              error('pid not found in url: $url');
              emit(state.copyWith(status: NotificationDetailStatus.failed));
              return;
            }
            // Parse thread id.
            final tidMatch = _tidRe.firstMatch(url);
            final tid = tidMatch?.namedGroup('ptid');
            if (tid == null) {
              error('failed to build reply page: tid not found');
              emit(state.copyWith(status: NotificationDetailStatus.failed));
              return;
            }
            switch (v) {
              case NoticeThreadPageBuilt(:final page):
                _fromBuiltPage(page, tid: tid, pid: pid);
              case NoticeThreadPageDocument(:final document, :final page):
                _fromDocument(document, page, tid: tid, pid: pid);
            }
          },
        )
        .run();
  }

  /// The floor [pid] of the page [page] built from the structured answer, of the thread [tid] the notice points to.
  ///
  /// The report target of the floor is only kept when the page is that thread (#127), as the document path keeps the
  /// report links; the reply form is the page's, none when the forum printed none.
  void _fromBuiltPage(ThreadPageInfo page, {required String tid, required String pid}) {
    final post = page.postList.firstWhereOrNull((e) => e.postID == pid);
    if (post == null) {
      error('failed to build reply page: post not found for pid $pid');
      emit(state.copyWith(status: NotificationDetailStatus.failed));
      return;
    }
    final postData = page.tid == tid ? post : post.copyWith(reportTarget: null);
    if (isClosed) {
      return;
    }
    emit(
      state.copyWith(
        status: NotificationDetailStatus.success,
        post: postData,
        replyParameters: page.replyParameters,
        tid: tid,
        pid: pid,
        page: '${page.currentPage}',
        threadClosed: page.threadClosed,
      ),
    );
  }

  /// The floor [pid] of the thread page [document], parsed as the web page, of the thread [tid] the notice points
  /// to; [page] is the page number the forum redirected to.
  void _fromDocument(uh.Document document, String? page, {required String tid, required String pid}) {
    final threadClosed = isThreadClosedForReply(document);

    final postNode = document.querySelector('div#post_$pid');
    if (postNode == null) {
      error('failed to build reply page: post node not found for pid $pid');
      emit(state.copyWith(status: NotificationDetailStatus.failed));
      return;
    }
    // Report links are only kept when the page is the thread the notice points to (#127).
    final postData = Post.fromPostNode(
      postNode,
      document.currentPage() ?? 1,
      reportContext: postReportPageContextOf(document, expectedTid: tid),
      viewerUid: parseLoggedUidFromDocument(document),
    );
    final replyParameters = _parseParameters(document, tid);
    if (isClosed) {
      return;
    }
    emit(
      state.copyWith(
        status: NotificationDetailStatus.success,
        post: postData,
        replyParameters: replyParameters,
        tid: tid,
        pid: pid,
        page: page,
        threadClosed: threadClosed,
      ),
    );
  }

  ReplyParameters? _parseParameters(uh.Document document, String tid) {
    final fid = document.querySelector('input[name="srhfid"]')?.attributes['value'];
    final postTime = document.querySelector('input[name="posttime"]')?.attributes['value'];
    final formHash = document.querySelector('input[name="formhash"]')?.attributes['value'];
    final subject = document.querySelector('input[name="subject"]')?.attributes['value'];

    if (fid == null || postTime == null || formHash == null || subject == null) {
      debug(
        'failed to get reply form hash: fid=$fid postTime=$postTime '
        'formHash=$formHash subject=$subject',
      );
      return null;
    }
    return ReplyParameters(fid: fid, tid: tid, postTime: postTime, formHash: formHash, subject: subject);
  }
}
