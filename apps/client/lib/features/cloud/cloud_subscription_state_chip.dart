import 'package:flutter/material.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

import 'cloud_connection.dart';

class CloudSubscriptionStateChip extends StatelessWidget {
  const CloudSubscriptionStateChip({
    super.key,
    required this.state,
    this.onLight = false,
  });

  final CloudSubscriptionState state;
  final bool onLight;

  @override
  Widget build(BuildContext context) {
    final palette = WeekGlassPalette.of(context);
    final dark = palette.isDark && !onLight;
    final (ink, fill) = switch (state) {
      CloudSubscriptionState.active =>
        dark
            ? (const Color(0xFFC1F3E1), const Color(0xFF215049))
            : (const Color(0xFF17604D), const Color(0xFFDDF7ED)),
      CloudSubscriptionState.expired =>
        dark
            ? (const Color(0xFFFAD9A3), const Color(0xFF53412F))
            : (const Color(0xFF754A17), const Color(0xFFFFECCA)),
      _ =>
        onLight
            ? (const Color(0xFF364969), const Color(0xC8F8FAFF))
            : (palette.muted, palette.accentSoft),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        child: Text(
          state.label,
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: ink, fontWeight: FontWeight.w700, fontSize: 12),
        ),
      ),
    );
  }
}
