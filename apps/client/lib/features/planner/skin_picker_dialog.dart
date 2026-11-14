import 'package:flutter/material.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

import 'planner_controller.dart';

Future<void> openSkinPicker(
  BuildContext context,
  PlannerController controller,
) async {
  final originalSkin = controller.skin;
  final originalMode = controller.themeMode;
  final originalStrength = controller.glassStrength;
  final originalMotion = controller.glassMotion;
  var accepted = false;
  try {
    accepted =
        await showDialog<bool>(
          context: context,
          builder: (_) => _SkinPicker(controller: controller),
        ) ??
        false;
  } finally {
    if (!accepted) {
      controller.previewAppearance(
        skin: originalSkin,
        themeMode: originalMode,
        glassStrength: originalStrength,
        glassMotion: originalMotion,
      );
    }
  }
}

class _SkinPicker extends StatefulWidget {
  const _SkinPicker({required this.controller});
  final PlannerController controller;

  @override
  State<_SkinPicker> createState() => _SkinPickerState();
}

class _SkinPickerState extends State<_SkinPicker> {
  bool saving = false;
  String? error;
  PlannerController get controller => widget.controller;

  void preview({
    WeekGlassSkin? skin,
    ThemeMode? mode,
    double? strength,
    bool? motion,
  }) {
    setState(() => error = null);
    controller.previewAppearance(
      skin: skin ?? controller.skin,
      themeMode: mode ?? controller.themeMode,
      glassStrength: strength,
      glassMotion: motion,
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final brightness = switch (controller.themeMode) {
        ThemeMode.light => Brightness.light,
        ThemeMode.dark => Brightness.dark,
        ThemeMode.system => MediaQuery.platformBrightnessOf(context),
      };
      final duration = MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 240);
      return AnimatedTheme(
        data: brightness == Brightness.dark
            ? WeekGlassTheme.dark(skin: controller.skin)
            : WeekGlassTheme.light(skin: controller.skin),
        duration: duration,
        curve: Curves.easeOutCubic,
        child: Builder(
          builder: (context) {
            return PopScope(
              canPop: !saving,
              child: GlassAlertDialog(
                key: const ValueKey('skin-gallery'),
                insetPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 24,
                ),
                titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                contentPadding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                title: const Row(
                  children: [
                    Icon(Icons.palette_outlined, size: 22),
                    SizedBox(width: 10),
                    Text('皮肤与外观'),
                  ],
                ),
                content: SizedBox(
                  width: 620,
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final mode in const [
                              ThemeMode.light,
                              ThemeMode.dark,
                              ThemeMode.system,
                            ])
                              ChoiceChip(
                                key: ValueKey('appearance-mode-${mode.name}'),
                                label: Text(switch (mode) {
                                  ThemeMode.light => '浅色',
                                  ThemeMode.dark => '深色',
                                  ThemeMode.system => '跟随系统',
                                }),
                                avatar: Icon(switch (mode) {
                                  ThemeMode.light => Icons.light_mode_outlined,
                                  ThemeMode.dark => Icons.dark_mode_outlined,
                                  ThemeMode.system =>
                                    Icons.brightness_auto_outlined,
                                }, size: 17),
                                selected: controller.themeMode == mode,
                                showCheckmark: false,
                                onSelected: saving
                                    ? null
                                    : (_) => preview(mode: mode),
                              ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final largeText =
                                MediaQuery.textScalerOf(context).scale(14) > 18;
                            final columns =
                                constraints.maxWidth >= 560 && !largeText
                                ? 3
                                : 2;
                            final width =
                                (constraints.maxWidth - (columns - 1) * 12) /
                                columns;
                            return Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              children: [
                                for (final skin in WeekGlassSkin.values)
                                  SizedBox(
                                    width: width,
                                    child: _SkinTile(
                                      key: ValueKey('skin-${skin.id}'),
                                      skin: skin,
                                      brightness: brightness,
                                      selected: skin == controller.skin,
                                      onPressed: saving
                                          ? null
                                          : () => preview(skin: skin),
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                        const SizedBox(height: 22),
                        _LightControls(
                          controller: controller,
                          enabled: !saving,
                          onStrength: (value) => preview(strength: value),
                          onMotion: (value) => preview(motion: value),
                        ),
                        if (error != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: saving
                        ? null
                        : () => Navigator.pop(context, false),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: saving
                        ? null
                        : () async {
                            setState(() {
                              saving = true;
                              error = null;
                            });
                            try {
                              await controller.saveAppearance(
                                skin: controller.skin,
                                themeMode: controller.themeMode,
                              );
                              if (context.mounted) Navigator.pop(context, true);
                            } catch (_) {
                              if (mounted) {
                                setState(() {
                                  saving = false;
                                  error = '外观未能保存，请重试。';
                                });
                              }
                            }
                          },
                    child: Text(saving ? '保存中…' : '保存外观'),
                  ),
                ],
              ),
            );
          },
        ),
      );
    },
  );
}

class _LightControls extends StatelessWidget {
  const _LightControls({
    required this.controller,
    required this.enabled,
    required this.onStrength,
    required this.onMotion,
  });
  final PlannerController controller;
  final bool enabled;
  final ValueChanged<double> onStrength;
  final ValueChanged<bool> onMotion;

  @override
  Widget build(BuildContext context) {
    final p = WeekGlassPalette.of(context);
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '流动色光',
          style: TextStyle(color: p.text, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 72,
          child: Row(
            children: [
              for (final sample in const [
                ('mist_blue', '专注'),
                ('lavender', '阅读'),
                ('sage_green', '灵感'),
              ]) ...[
                if (sample.$1 != 'mist_blue') const SizedBox(width: 10),
                Expanded(
                  child: LiquidGlassSurface(
                    colorKey: sample.$1,
                    child: Center(
                      child: Text(
                        sample.$2,
                        style: TextStyle(
                          color: p.eventColor(sample.$1, selected: true),
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            const Expanded(child: Text('色光强度')),
            Text(
              '${(controller.glassStrength * 100).round()}%',
              style: TextStyle(color: p.muted, fontSize: 12),
            ),
          ],
        ),
        Slider(
          key: const ValueKey('glass-strength'),
          value: controller.glassStrength,
          max: LiquidGlass.maxStrength,
          divisions: 125,
          label: '${(controller.glassStrength * 100).round()}%',
          semanticFormatterCallback: (value) =>
              '色光强度 ${(value * 100).round()}%',
          onChanged: enabled ? onStrength : null,
        ),
        SwitchListTile.adaptive(
          key: const ValueKey('glass-motion'),
          contentPadding: EdgeInsets.zero,
          title: const Text('让色光缓缓流动'),
          subtitle: Text(reducedMotion ? '系统已减少动态效果，色光保持静止' : '关闭后保留静止的光影'),
          value: controller.glassMotion,
          onChanged: enabled ? onMotion : null,
        ),
      ],
    );
  }
}

class _SkinTile extends StatefulWidget {
  const _SkinTile({
    super.key,
    required this.skin,
    required this.brightness,
    required this.selected,
    required this.onPressed,
  });
  final WeekGlassSkin skin;
  final Brightness brightness;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  State<_SkinTile> createState() => _SkinTileState();
}

class _SkinTileState extends State<_SkinTile> {
  bool hovered = false;
  bool focused = false;

  @override
  Widget build(BuildContext context) {
    final palette = WeekGlassPalette.forSkin(widget.skin, widget.brightness);
    final active = widget.selected || hovered || focused;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);
    return Semantics(
      button: true,
      selected: widget.selected,
      onTap: widget.onPressed,
      label: '${widget.skin.label}，${widget.skin.description}',
      child: ExcludeSemantics(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: WeekGlassGeometry.corners,
            onTap: widget.onPressed,
            onHover: (value) => setState(() => hovered = value),
            onFocusChange: (value) => setState(() => focused = value),
            child: AnimatedContainer(
              duration: duration,
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: palette.canvas,
                borderRadius: WeekGlassGeometry.corners,
                border: Border.all(
                  color: active ? palette.accentStrong : palette.lineStrong,
                  width: 1.2,
                ),
                boxShadow: active
                    ? [
                        BoxShadow(
                          color: palette.accent.withValues(alpha: .14),
                          blurRadius: 14,
                          offset: const Offset(0, 4),
                        ),
                      ]
                    : const [],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 12,
                    ),
                    decoration: palette.glassDecoration(layer: GlassLayer.card),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.wb_twilight_rounded,
                          size: 20,
                          color: palette.accentStrong,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '专注时光',
                          style: TextStyle(
                            color: palette.text,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '09:00 – 10:00',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: palette.muted, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.skin.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.text,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 3),
                      Icon(
                        widget.selected
                            ? Icons.check_circle_rounded
                            : Icons.circle_outlined,
                        size: 16,
                        color: widget.selected
                            ? palette.accentStrong
                            : palette.mutedSoft,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.skin.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.muted,
                      fontSize: 11,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
