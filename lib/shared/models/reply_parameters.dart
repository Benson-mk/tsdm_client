part of 'models.dart';

/// Model contains parameters to make a reply to:
///
/// * Thread.
/// * Post.
@MappableClass()
class ReplyParameters with ReplyParametersMappable {
  /// Constructor.
  const ReplyParameters({
    required this.fid,
    required this.tid,
    required this.postTime,
    required this.formHash,
    required this.subject,
    this.debate = false,
    this.debateStand,
  });

  /// Forum id.
  final String fid;

  /// Thread id.
  final String tid;

  /// Post time.
  final String? postTime;

  /// Form hash used in post request.
  final String formHash;

  /// Subject usually is an empty string.
  final String subject;

  /// The thread is a debate: a reply takes a side (`stand`: 0 neutral, 1 affirmative, 2 negative), as the forum's
  /// reply forms ask while the account took none.
  final bool debate;

  /// The side the account took in the debate with its first reply (1 or 2), which the forum keeps for every later
  /// reply; null while it took none or the page does not tell (plugin 2.8.0, `special.reply_stand`, first page only).
  final int? debateStand;
}
