import 'package:flutter/material.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// Ask the optional note of a new favorite.
///
/// [title] defaults to the thread wording ("收藏"); the forum page passes "收藏本版".
/// Returns the note (may be empty) or null when the user cancelled.
Future<String?> showFavoriteNoteDialog(BuildContext context, {String? title}) async => showDialog<String>(
  context: context,
  builder: (context) => RootPage(DialogPaths.favoriteNote, _FavoriteNoteDialog(title: title)),
);

class _FavoriteNoteDialog extends StatefulWidget {
  const _FavoriteNoteDialog({this.title});

  final String? title;

  @override
  State<_FavoriteNoteDialog> createState() => _FavoriteNoteDialogState();
}

class _FavoriteNoteDialogState extends State<_FavoriteNoteDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.threadPage.favorite;
    return AlertDialog(
      icon: const Icon(Icons.star_outline),
      title: Text(widget.title ?? tr.add),
      scrollable: true,
      content: ConstrainedBox(
        // Wide enough for a short note on desktop windows, the dialog insets still apply on phones.
        constraints: const BoxConstraints(minWidth: 320),
        child: TextField(
          controller: _controller,
          autofocus: true,
          minLines: 2,
          maxLines: 4,
          maxLength: 200,
          decoration: InputDecoration(
            hintText: tr.noteHint,
            prefixIcon: const Icon(Icons.sticky_note_2_outlined),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(appInnerRadius)),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.cancel)),
        // Kept a text button: confirmations elsewhere in the app (and their tests) take the last text button as Ok.
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: Text(context.t.general.ok),
        ),
      ],
    );
  }
}
