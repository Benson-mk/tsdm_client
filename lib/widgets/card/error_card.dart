import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/list.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// Show error and retry.
class ErrorCard extends StatelessWidget {
  /// Constructor.
  const ErrorCard({required this.child, this.message, super.key});

  /// Extra optional error message.
  final String? message;

  /// Child widget to interact.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final windowWidth = MediaQuery.sizeOf(context).width;
    final cardWidth = math.min<double>(windowWidth * 2 / 3, 500);
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: cardWidth),
        // The rounded surface and icon block shared with [AppStateView].
        child: AppSurface(
          padding: edgeInsetsL24T24R24B24,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(appSurfaceRadius),
                ),
                child: SizedBox.square(
                  dimension: (cardWidth - 48).clamp(0, 64).toDouble(),
                  child: Icon(
                    Icons.error_outline_outlined,
                    size: 32,
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
              ),
              Text(
                message ?? getIt.get<NetErrorSaver>().error() ?? context.t.general.failedToLoad,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              Center(child: child),
            ].insertBetween(sizedBoxW12H12),
          ),
        ),
      ),
    );
  }
}
