/// The local record of a claimed daily red packet.
///
/// The forum homepage carries the packet only while it can be claimed; once claimed the page looks the same as a day
/// without a packet, so the app remembers the claims it made (or that the server answered "already claimed") per
/// account and shows "claimed" instead of "none" for the rest of that day. Only this app's own claims are known: a
/// claim made on the website is not.
library;

/// Storage key of the record of the account [uid]: the value is the `dateflag` (`YYYYMMDD`) of the claimed packet.
String dailyRedPacketClaimKey(int uid) => 'dailyRedPacketClaimed.$uid';

/// The `dateflag` form of [day], `YYYYMMDD` like the forum's.
String dailyRedPacketDateFlag(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}${day.month.toString().padLeft(2, '0')}${day.day.toString().padLeft(2, '0')}';

/// Whether a record of [claimedDateFlag] means the packet of today ([now], local time) was claimed.
///
/// The site's day is not known here; the local calendar day stands in for it, so around midnight the record may be
/// a few hours off. The record is only used when the page offers no packet, a packet on the page always wins.
bool dailyRedPacketClaimedToday(String? claimedDateFlag, {DateTime? now}) =>
    claimedDateFlag != null && claimedDateFlag == dailyRedPacketDateFlag(now ?? DateTime.now());
