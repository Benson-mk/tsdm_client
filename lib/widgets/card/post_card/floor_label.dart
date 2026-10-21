import 'package:tsdm_client/i18n/strings.g.dart';

/// The floor number a floor goes by, as the page prints it: "#N", "#" when the page prints none; a hot reply says
/// "推荐" there, with the floor it really is when that is known ("推荐 #N", see `Post.hotFloor`).
String postFloorLabel(Translations t, {required int? floor, bool hot = false, int? hotFloor}) {
  if (hot) {
    return [t.postCard.hotReply, if (hotFloor != null) '#$hotFloor'].join(' ');
  }
  return floor == null ? '#' : '#$floor';
}
