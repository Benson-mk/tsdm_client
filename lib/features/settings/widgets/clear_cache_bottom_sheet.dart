import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/int.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/features/settings/bloc/settings_cache_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_cache_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/show_bottom_sheet.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// Show a bottom sheet provides clear cache functionality with clear cache
/// options.
Future<void> showClearCacheBottomSheet({required BuildContext context}) async {
  await showCustomBottomSheet<void>(
    title: context.t.settingsPage.storageSection.clearCache,
    context: context,
    builder: (context) => const RootPage(DialogPaths.clearCache, _ClearCacheBottomSheet()),
  );
}

class _ClearCacheBottomSheet extends StatefulWidget {
  const _ClearCacheBottomSheet();

  @override
  State<_ClearCacheBottomSheet> createState() => _ClearCacheBottomSheetState();
}

class _ClearCacheBottomSheetState extends State<_ClearCacheBottomSheet> {
  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.storageSection;

    // Default clear options.
    return MultiBlocProvider(
      providers: [
        RepositoryProvider(create: (_) => const SettingsCacheRepository()),
        BlocProvider(
          create: (context) =>
              SettingsCacheBloc(cacheRepository: context.repo())..add(SettingsCacheCalculateRequested()),
        ),
      ],
      child: BlocConsumer<SettingsCacheBloc, SettingsCacheState>(
        listenWhen: (_, curr) => curr.status == SettingsCacheStatus.cleared,
        listener: (context, state) {
          showSnackBar(context: context, message: tr.clearSuccess);
          context.pop();
        },
        builder: (context, state) {
          final body = switch (state.status) {
            SettingsCacheStatus.loaded || SettingsCacheStatus.cleared => SingleChildScrollView(
              padding: edgeInsetsL16R16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppNoticeBanner(message: tr.downloadAgainInfo),
                  sizedBoxW12H12,
                  AppInsetBlock(
                    outlined: true,
                    padding: edgeInsetsT4B4,
                    child: Column(
                      children: [
                        CheckboxListTile(
                          secondary: const Icon(Icons.image_outlined),
                          title: Text(tr.images),
                          subtitle: Text(state.storageInfo!.imageSize.withSizeHint()),
                          value: state.clearInfo.clearImage,
                          onChanged: (v) => context.read<SettingsCacheBloc>().add(
                            SettingsCacheUpdateClearInfoRequested(state.clearInfo.copyWith(clearImage: v)),
                          ),
                        ),
                        CheckboxListTile(
                          secondary: const Icon(Icons.emoji_emotions_outlined),
                          title: Text(tr.emoji),
                          subtitle: Text(state.storageInfo!.emojiSize.withSizeHint()),
                          value: state.clearInfo.clearEmoji,
                          onChanged: (v) => context.read<SettingsCacheBloc>().add(
                            SettingsCacheUpdateClearInfoRequested(state.clearInfo.copyWith(clearEmoji: v)),
                          ),
                        ),
                        CheckboxListTile(
                          secondary: const Icon(Symbols.text_ad),
                          title: Text(tr.log),
                          subtitle: Text(state.storageInfo!.logSize.withSizeHint()),
                          value: state.clearInfo.clearLog,
                          onChanged: (v) => context.read<SettingsCacheBloc>().add(
                            SettingsCacheUpdateClearInfoRequested(state.clearInfo.copyWith(clearLog: v)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            _ => const Padding(padding: edgeInsetsL24T24R24B24, child: CenteredCircularIndicator()),
          };

          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              body,
              Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: edgeInsetsL16T12R16B12.add(context.safePadding()),
                      child: FilledButton.icon(
                        icon: const Icon(Icons.cleaning_services_outlined),
                        onPressed: state.status == SettingsCacheStatus.loaded
                            ? () {
                                if (state.clearInfo.hasSelected) {
                                  context.read<SettingsCacheBloc>().add(
                                    SettingsCacheClearCacheRequested(state.clearInfo),
                                  );
                                } else {
                                  showSnackBar(context: context, message: tr.selectOneCache);
                                }
                              }
                            : null,
                        label: Text(context.t.general.ok),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
