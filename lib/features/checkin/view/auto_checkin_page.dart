import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/checkin/bloc/auto_checkin_bloc.dart';
import 'package:tsdm_client/features/checkin/models/models.dart';
import 'package:tsdm_client/features/checkin/widgets/auto_checkin_user_card.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// Page to display info about auto checkin status.
class AutoCheckinPage extends StatefulWidget {
  /// Constructor.
  const AutoCheckinPage({super.key});

  @override
  State<AutoCheckinPage> createState() => _AutoCheckinPageState();
}

class _AutoCheckinPageState extends State<AutoCheckinPage> {
  @override
  Widget build(BuildContext context) {
    final tr = context.t.autoCheckinPage;
    return BlocBuilder<AutoCheckinBloc, AutoCheckinState>(
      builder: (context, state) {
        var waitingList = <UserLoginInfo>[];
        var runningList = <UserLoginInfo>[];
        var succeededList = <(UserLoginInfo, CheckinResult)>[];
        var failedList = <(UserLoginInfo, CheckinResult)>[];
        switch (state) {
          case AutoCheckinStateInitial() || AutoCheckinStatePreparing():
            // Do nothing.
            break;
          case AutoCheckinStateLoading(:final info):
            waitingList = info.waiting;
            runningList = info.running;
            succeededList = info.succeeded;
            failedList = info.failed;
          case AutoCheckinStateFinished(succeeded: final s, failed: final f):
            succeededList = s;
            failedList = f;
        }
        final running = [for (final e in runningList) AutoCheckinUserCard(e, tr.user.running)];
        final waiting = [for (final e in waitingList) AutoCheckinUserCard(e, tr.user.waiting)];
        final succeeded = [
          for (final e in succeededList)
            AutoCheckinUserCard(
              // Ok to use record.
              // ignore: avoid_positional_fields_in_records
              e.$1,
              // Ok to use record.
              // ignore: avoid_positional_fields_in_records
              CheckinResult.message(context, e.$2),
              failure: false,
            ),
        ];
        final failed = [
          for (final e in failedList)
            AutoCheckinUserCard(
              // Ok to use record.
              // ignore: avoid_positional_fields_in_records
              e.$1,
              // Ok to use record.
              // ignore: avoid_positional_fields_in_records
              CheckinResult.message(context, e.$2),
              // Ok to use record.
              // ignore: avoid_positional_fields_in_records
              failure: e.$2 is! CheckinResultAlreadyChecked,
            ),
        ];
        final total = running.length + waiting.length + succeeded.length + failed.length;
        final done = succeeded.length + failed.length;
        final colorScheme = Theme.of(context).colorScheme;

        return Scaffold(
          appBar: AppBar(title: Text(tr.title)),
          body: SafeArea(
            bottom: false,
            child: AppCenteredList(
              builder: (context, side, width) {
                final columns = appColumnsFor(width);
                final gap = width < 600 ? appSurfaceGapCompact : appSurfaceGap;
                List<Widget> section(String title, IconData icon, List<Widget> cards) => [
                  if (cards.isNotEmpty) ...[
                    SizedBox(height: gap),
                    AppSectionHeader('$title · ${cards.length}', icon: icon),
                    for (var row = 0; row < appRowCount(cards.length, columns); row++)
                      Padding(
                        padding: EdgeInsets.only(top: row == 0 ? 0 : gap),
                        child: AppColumnsRow(
                          row: row,
                          columns: columns,
                          count: cards.length,
                          gap: gap,
                          itemBuilder: (context, index) => cards[index],
                        ),
                      ),
                  ],
                ];
                return ListView(
                  padding: side.copyWith(top: 12, bottom: 12).add(context.safePadding()),
                  children: [
                    AppSurface(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              const AppIconTile(Icons.domain_verification_outlined),
                              sizedBoxW12H12,
                              Expanded(
                                child: Text(
                                  tr.detail,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                                ),
                              ),
                            ],
                          ),
                          if (total > 0) ...[
                            sizedBoxW12H12,
                            ClipRRect(
                              borderRadius: BorderRadius.circular(appInnerRadius),
                              child: LinearProgressIndicator(value: done / total, minHeight: 6),
                            ),
                            sizedBoxW8H8,
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                AppInfoPill(icon: Icons.sync, label: '${tr.user.running} ${running.length}'),
                                AppInfoPill(
                                  icon: Icons.schedule_outlined,
                                  label: '${tr.user.waiting} ${waiting.length}',
                                ),
                                AppInfoPill(
                                  icon: Icons.check_circle_outline,
                                  label: '${tr.user.success} ${succeeded.length}',
                                ),
                                AppInfoPill(icon: Icons.error_outline, label: '${tr.user.failure} ${failed.length}'),
                              ],
                            ),
                          ] else if (state is AutoCheckinStateLoading || state is AutoCheckinStatePreparing) ...[
                            sizedBoxW12H12,
                            const LinearProgressIndicator(),
                          ],
                        ],
                      ),
                    ),
                    ...section(tr.user.running, Icons.sync, running),
                    ...section(tr.user.waiting, Icons.schedule_outlined, waiting),
                    ...section(tr.user.failure, Icons.error_outline, failed),
                    ...section(tr.user.success, Icons.check_circle_outline, succeeded),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}
