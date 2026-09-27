import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:tsdm_client/constants/constants.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// Page showing changelog bundled with app.
class LocalChangelogPage extends StatelessWidget {
  /// Constructor.
  const LocalChangelogPage({super.key});

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.othersSection;
    return Scaffold(
      appBar: AppBar(title: Text(tr.changelog)),
      body: SafeArea(
        top: false,
        bottom: false,
        child: FutureBuilder(
          future: compute(readChangelogContent, ''),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              // Unreachable.
              return AppStateView(icon: Icons.error_outline, error: true, message: 'error: ${snapshot.error}');
            }

            if (!snapshot.hasData) {
              return const CenteredCircularIndicator();
            }

            // Reading width on wide windows; the markdown keeps its own scroll view and the full width scrollbar.
            return AppCenteredList(
              maxWidth: appReadingMaxWidth,
              builder: (context, padding, _) => Markdown(
                data: snapshot.data!,
                padding: padding.copyWith(top: 16, bottom: 24 + MediaQuery.paddingOf(context).bottom),
              ),
            );
          },
        ),
      ),
    );
  }
}
