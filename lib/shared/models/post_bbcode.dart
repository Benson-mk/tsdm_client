part of 'models.dart';

/// An attachment of a floor, as the thread page answer of the forum's app API gives it (plugin 2.7.0, `schema: 14`,
/// `posts[].attachments[]`): what the forum loaded for this request to print the floor, nothing more.
///
/// A [locked] attachment (a price not paid, a read permission too low, a guest on a forum that only shows guests a
/// thumbnail) has no [url], [thumb] or [download]: nothing may be fetched for it.
@MappableClass()
final class PostAttachment with PostAttachmentMappable {
  /// Constructor.
  const PostAttachment({
    required this.aid,
    required this.filename,
    required this.description,
    required this.isImage,
    required this.url,
    required this.thumb,
    required this.download,
    required this.width,
    required this.height,
    required this.filesize,
    required this.price,
    required this.readPerm,
    required this.downloads,
    required this.locked,
    required this.inPost,
  });

  /// Build from an item [a] of `attachments`; null when it names no attachment id.
  static PostAttachment? fromApi(Map<String, dynamic> a) {
    final aid = _apiInt(a['aid']);
    if (aid <= 0) {
      return null;
    }
    final locked = _apiInt(a['locked']) == 1;
    String link(Object? value) {
      final text = _apiText(value).trim();
      // Never a url for a locked one, even if an answer carried one by mistake.
      return locked || text.isEmpty ? '' : text.prependHost();
    }

    return PostAttachment(
      aid: aid,
      filename: _apiText(a['filename']),
      description: _apiText(a['description']),
      isImage: _apiInt(a['isimage']) == 1,
      url: link(a['url']),
      thumb: link(a['thumb']),
      download: link(a['download']),
      width: _apiInt(a['width']),
      height: _apiInt(a['height']),
      filesize: _apiInt(a['filesize']),
      price: _apiInt(a['price']),
      readPerm: _apiInt(a['readperm']),
      downloads: _apiInt(a['downloads']),
      locked: locked,
      inPost: _apiInt(a['inpost']) == 1,
    );
  }

  /// The attachment id, as `[attach]aid[/attach]` names it in the floor's bbcode.
  final int aid;

  /// File name.
  final String filename;

  /// The description the uploader wrote, plain text; empty when none.
  final String description;

  /// Whether the forum shows it as an image (it is a file when the forum does not show images in posts).
  final bool isImage;

  /// An image: the file itself; a file: its download url. Empty when [locked].
  final String url;

  /// The thumbnail, empty when the forum made none (or [locked]).
  final String thumb;

  /// The download url, empty when [locked].
  final String download;

  /// Image width in pixels, 0 when unknown.
  final int width;

  /// Image height in pixels, 0 when unknown.
  final int height;

  /// Size in bytes.
  final int filesize;

  /// The price, 0 when free.
  final int price;

  /// The read permission it needs, 0 when none.
  final int readPerm;

  /// Download count.
  final int downloads;

  /// Whether the account the page was served to can not have it: [url], [thumb] and [download] are empty.
  final bool locked;

  /// Whether the floor's bbcode places it (`[attach]aid[/attach]`); the others are listed below the floor's content.
  final bool inPost;
}

/// The switches of the forum's bbcode rendering for a floor (plugin 2.7.0, `schema: 14`): the forum's settings for
/// this request (the answer's `codes`), with the floor's own values where the answer gives them (`allowsmilies`,
/// `allowbbcode`, `allowimgcode`, `allowmediacode` of the floor: what the forum passed to its renderer for it).
@MappableClass()
final class PostBbcodeCodes with PostBbcodeCodesMappable {
  /// Constructor.
  const PostBbcodeCodes({
    required this.allowSmilies,
    required this.allowBbcode,
    required this.allowImgCode,
    required this.allowHtml,
    required this.allowMediaCode,
    required this.jammer,
    required this.maxSmilies,
    this.imgWhitelist,
  });

  /// The switches of a floor [post] of an answer whose top level `codes` is [codes]; null when the answer has no
  /// `codes` (an older plugin).
  static PostBbcodeCodes? fromApi(Object? codes, Map<String, dynamic> post) {
    if (codes is! Map<String, dynamic>) {
      return null;
    }
    bool flag(String key) => _apiInt(post.containsKey(key) ? post[key] : codes[key]) != 0;
    return PostBbcodeCodes(
      allowSmilies: flag('allowsmilies'),
      allowBbcode: flag('allowbbcode'),
      allowImgCode: flag('allowimgcode'),
      allowHtml: _apiInt(codes['allowhtml']) != 0,
      allowMediaCode: flag('allowmediacode'),
      jammer: _apiInt(codes['jammer']) != 0,
      maxSmilies: codes.containsKey('maxsmilies') ? _apiInt(codes['maxsmilies']) : -1,
      imgWhitelist: _imgWhitelistOf(codes['imgwhitelist']),
    );
  }

  /// The domains of `codes.imgwhitelist` (plugin 2.8.0) when it is `enabled`; null when it is not, or not given.
  static List<String>? _imgWhitelistOf(Object? value) {
    if (value is! Map<String, dynamic> || _apiInt(value['enabled']) == 0) {
      return null;
    }
    return List.unmodifiable(
      _apiList(value['domains']).whereType<String>().map((e) => e.trim().toLowerCase()).where((e) => e.isNotEmpty),
    );
  }

  /// Smiley codes are turned into images.
  final bool allowSmilies;

  /// Bbcode tags are rendered.
  final bool allowBbcode;

  /// `[img]` is rendered as an image (else a link).
  final bool allowImgCode;

  /// Raw html posts are allowed in the forum.
  final bool allowHtml;

  /// `[media]`, `[audio]`, `[flash]` are rendered as players (else links).
  final bool allowMediaCode;

  /// The forum adds jammer text to the floors.
  final bool jammer;

  /// How many times each smiley code is turned into an image in a floor at most, as the forum's `preg_replace` limit:
  /// 0 or less has no limit (the forum's settings cache turns `maxsmilies` 0 into -1).
  final int maxSmilies;

  /// The image domain whitelist the forum applies to `[img]` (`codes.imgwhitelist`, plugin 2.8.0, when `enabled`):
  /// an `[img]` on a host not ending with one of these (nor the forum's own) is printed as its url, not as an image.
  /// Null when the forum does not check, or the answer does not say.
  final List<String>? imgWhitelist;
}
