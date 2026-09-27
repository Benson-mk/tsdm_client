import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// Type of editing the fast rate template.
enum FastRateTemplateEditType {
  /// Create a new one.
  create,

  /// Edit one we already have.
  edit,
}

/// Page to edit template.
class FastRateTemplateEditPage extends StatefulWidget {
  /// Constructor.
  const FastRateTemplateEditPage(this.editType, this.initialValue, {super.key});

  /// Type of the edit.
  final FastRateTemplateEditType editType;

  /// Optional initial template value.
  final FastRateTemplateModel? initialValue;

  @override
  State<FastRateTemplateEditPage> createState() => _FastRateTemplateEditPageState();
}

class _FastRateTemplateEditPageState extends State<FastRateTemplateEditPage> with LoggerMixin {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController editingControllerName;
  late final TextEditingController editingControllerWw;
  late final TextEditingController editingControllerTsb;
  late final TextEditingController editingControllerXc;
  late final TextEditingController editingControllerJl;
  late final TextEditingController editingControllerTr;
  late final TextEditingController editingControllerFh;
  late final TextEditingController editingControllerSpecial;
  late final TextEditingController editingControllerSpecial2;

  /// All current templates, for duplicate check.
  final List<FastRateTemplateModel> allTemplates = [];

  final numberInputFormatter = FilteringTextInputFormatter.allow(RegExp(r'^(-)?[0-9]*$'));

  /// Allow override same name template.
  bool allowOverride = false;

  String? attributeValidator(String? v, BuildContext context) {
    if (v == null || int.tryParse(v) == null) {
      return context.t.fastRateTemplate.editPage.invalidValue;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    editingControllerName = TextEditingController(text: widget.initialValue?.name);
    editingControllerWw = TextEditingController(text: '${widget.initialValue?.ww ?? "0"}');
    editingControllerTsb = TextEditingController(text: '${widget.initialValue?.tsb ?? "0"}');
    editingControllerXc = TextEditingController(text: '${widget.initialValue?.xc ?? "0"}');
    editingControllerTr = TextEditingController(text: '${widget.initialValue?.tr ?? "0"}');
    editingControllerFh = TextEditingController(text: '${widget.initialValue?.fh ?? "0"}');
    editingControllerJl = TextEditingController(text: '${widget.initialValue?.jl ?? "0"}');
    editingControllerSpecial = TextEditingController(text: '${widget.initialValue?.special ?? "0"}');
    editingControllerSpecial2 = TextEditingController(text: '${widget.initialValue?.special2 ?? "0"}');
  }

  @override
  void dispose() {
    editingControllerName.dispose();
    editingControllerWw.dispose();
    editingControllerTsb.dispose();
    editingControllerXc.dispose();
    editingControllerJl.dispose();
    editingControllerTr.dispose();
    editingControllerFh.dispose();
    editingControllerSpecial.dispose();
    editingControllerSpecial2.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.fastRateTemplate;

    final body = FutureBuilder(
      future: getIt.get<StorageProvider>().getAllFastRateTemplate().run(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          error('failed to load all fast rate templates: ${snapshot.error}');
          return AppStateView(error: true, icon: Icons.error_outline, message: context.t.general.failedToLoad);
        }

        if (!snapshot.hasData) {
          return const CenteredCircularIndicator();
        }

        final result = snapshot.data!;
        if (result.isLeft()) {
          error('failed to unpack fast rate all templates result: ${result.unwrapErr()}');
          return AppStateView(error: true, icon: Icons.error_outline, message: context.t.general.failedToLoad);
        }

        final allTemplates = result.unwrap();

        Widget score(TextEditingController controller, String label) => TextFormField(
          controller: controller,
          decoration: InputDecoration(labelText: label),
          keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
          inputFormatters: [numberInputFormatter],
          validator: (v) => attributeValidator(v, context),
        );

        final scoreFields = [
          score(editingControllerWw, tr.ww),
          score(editingControllerTsb, tr.tsb),
          score(editingControllerXc, tr.xc),
          score(editingControllerTr, tr.tr),
          score(editingControllerFh, tr.fh),
          score(editingControllerJl, tr.jl),
          score(editingControllerSpecial, tr.special),
          score(editingControllerSpecial2, tr.special2),
        ];

        return Form(
          key: _formKey,
          child: Column(
            children: [
              Expanded(
                child: AppCenteredList(
                  maxWidth: appFormMaxWidth,
                  // Not a lazy list: every field stays built, so the form validates all of them.
                  builder: (context, horizontal, width) => SingleChildScrollView(
                    padding: horizontal.add(const EdgeInsets.symmetric(vertical: 12)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AppFormSection(
                          children: [
                            TextFormField(
                              controller: editingControllerName,
                              autofocus: widget.editType == FastRateTemplateEditType.create,
                              decoration: InputDecoration(labelText: tr.name),
                              validator: (v) {
                                if (v == null || v.isEmpty) {
                                  return tr.editPage.nameNotEmpty;
                                }

                                // Duplicate check.
                                if (widget.editType == FastRateTemplateEditType.create && !allowOverride) {
                                  // Uid equality is ignored here.
                                  if (allTemplates.any((e) => e.name == v)) {
                                    return tr.editPageAlreadyExists;
                                  }
                                }

                                return null;
                              },
                            ),
                            // Only show override option if drafting new templates.
                            if (widget.editType == FastRateTemplateEditType.create)
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(tr.editPageOverride),
                                value: allowOverride,
                                onChanged: (v) => setState(() => allowOverride = v),
                              ),
                          ],
                        ),
                        appListSeparator,
                        AppFormSection(
                          title: context.t.ratePostPage.title,
                          icon: Icons.star_rate_outlined,
                          children: [
                            LayoutBuilder(
                              builder: (context, constraints) {
                                // Two fields per row on phones, four once there is room; large text gets fewer.
                                final fit = (constraints.maxWidth / MediaQuery.textScalerOf(context).scale(150))
                                    .floor();
                                final perRow = fit < 1 ? 1 : (fit > 4 ? 4 : fit);
                                final fieldWidth = (constraints.maxWidth - 12 * (perRow - 1)) / perRow;
                                return Wrap(
                                  spacing: 12,
                                  runSpacing: 12,
                                  children: [
                                    for (final field in scoreFields) SizedBox(width: fieldWidth, child: field),
                                  ],
                                );
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              AppBottomActionBar(
                child: FilledButton(
                  child: Text(context.t.general.ok),
                  onPressed: () {
                    if (!_formKey.currentState!.validate()) {
                      return;
                    }

                    context.pop(
                      FastRateTemplateModel(
                        name: editingControllerName.text,
                        ww: int.parse(editingControllerWw.text),
                        tsb: int.parse(editingControllerTsb.text),
                        xc: int.parse(editingControllerXc.text),
                        tr: int.parse(editingControllerTr.text),
                        fh: int.parse(editingControllerFh.text),
                        jl: int.parse(editingControllerJl.text),
                        special: int.parse(editingControllerSpecial.text),
                        special2: int.parse(editingControllerSpecial2.text),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(switch (widget.editType) {
          FastRateTemplateEditType.create => tr.editPageTitle,
          FastRateTemplateEditType.edit => tr.edit,
        }),
      ),
      body: body,
    );
  }
}
