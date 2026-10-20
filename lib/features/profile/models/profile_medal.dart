import 'package:dart_mappable/dart_mappable.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

part 'profile_medal.mapper.dart';

/// Medal info in profile page.
@MappableClass()
final class ProfileMedal with ProfileMedalMappable {
  /// Constructor.
  const ProfileMedal({
    required this.name,
    required this.image,
    required this.alter,
    required this.description,
    this.id,
  });

  /// Build from a row of `medals` in the structured profile answer of the forum's app API (plugin 2.2.0,
  /// `schema: 4`, see `profileFromApi`): the forum's own medal, with the medal name as the alternative text, as the
  /// page prints it.
  ///
  /// The medal id is kept as the opaque string the answer gives (the forum's medal ids are not always numeric).
  factory ProfileMedal.fromApi(Map<String, dynamic> row) {
    final name = row['name'] is String ? row['name'] as String : '';
    return ProfileMedal(
      name: name,
      image: row['image'] is String ? row['image'] as String : '',
      alter: name,
      description: row['description'] is String ? row['description'] as String : '',
      id: switch (row['id']) {
        final String s => s,
        final num n => '${n.toInt()}',
        _ => null,
      },
    );
  }

  /// Medal name.
  final String name;

  /// The forum's id of the medal, as the structured answer names it (opaque: not always numeric); null when read from
  /// the web page, which does not name it.
  final String? id;

  /// Image url.
  final String image;

  /// Alter text.
  final String alter;

  /// Medal description.
  final String description;

  /// Build instance from `<img>` node.
  ///
  /// Discuz X3:
  ///
  /// ```html
  /// <img src=$IMAGE alt=$ALTER onmouseover="showTip(this)" tip="<h4>$NAME</h4><p>$DESCRIPTION</p>" />
  /// ```
  ///
  /// Discuz X5, the tip is in a separate node found by id, provide it through [tipNode]:
  ///
  /// ```html
  /// <img src=$IMAGE alt=$ALTER id="md_1911" onmouseover="showMenu({'ctrlid':this.id, 'menuid':'md_1911_menu'})" />
  /// ...
  /// <div id="md_1911_menu" class="tip tip_4">
  ///   <div class="tip_horn"></div>
  ///   <div class="tip_c"><h4>$NAME</h4><p>$DESCRIPTION</p></div>
  /// </div>
  /// ```
  static ProfileMedal? fromImg(uh.Element element, {uh.Element? tipNode}) {
    final image = element.imageUrl();
    final alter = element.attributes['alt'];
    final tip = element.attributes['tip'];
    if (image == null || alter == null || (tip == null && tipNode == null)) {
      talker.warning('failed to build profile medal: image=$image, alter=$alter, tip=$tip, tipNode=${tipNode != null}');
      return null;
    }

    // Tip is expected to be `<h4>论坛贡献荣誉II</h4><p>论坛贡献荣誉II</p>` format.
    final name =
        (tipNode?.querySelector('h4') ?? parseHtmlDocument(tip ?? '').querySelector('h4'))?.innerText.trim() ?? alter;
    final description =
        (tipNode?.querySelector('p') ?? parseHtmlDocument(tip ?? '').querySelector('p'))?.innerText.trim() ?? '';

    return ProfileMedal(name: name, image: image, alter: alter, description: description);
  }

  /// The id of tip node for medal `<img>` node in Discuz X5.
  ///
  /// `md_1911` => `md_1911_menu`.
  static String? tipNodeId(uh.Element element) => element.id.isEmpty ? null : '${element.id}_menu';
}
