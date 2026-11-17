import 'package:flutter/material.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

import 'cloud_connection.dart';
import 'cloud_subscription_state_chip.dart';

enum _CloudButtonKind { entry, subscription, rail, dock }

/// The cloud service has one material, from the shortcut to the plans link.
class CloudServiceButton extends StatelessWidget {
  const CloudServiceButton.entry({
    super.key,
    required this.onPressed,
    required String this.detail,
    this.state,
  }) : _kind = _CloudButtonKind.entry;

  const CloudServiceButton.subscription({super.key, required this.onPressed})
    : _kind = _CloudButtonKind.subscription,
      detail = null,
      state = null;

  const CloudServiceButton.rail({super.key, required this.onPressed})
    : _kind = _CloudButtonKind.rail,
      detail = null,
      state = null;

  const CloudServiceButton.dock({super.key, required this.onPressed})
    : _kind = _CloudButtonKind.dock,
      detail = null,
      state = null;

  static const label = '云服务';

  final _CloudButtonKind _kind;
  final VoidCallback? onPressed;
  final String? detail;
  final CloudSubscriptionState? state;

  @override
  Widget build(BuildContext context) {
    final palette = WeekGlassPalette.of(context);
    final text = Theme.of(context).textTheme;
    final enabled = onPressed != null;
    final ink = enabled ? const Color(0xFF172A4B) : palette.muted;
    final compact = _kind == _CloudButtonKind.rail;
    final shortcut = compact || _kind == _CloudButtonKind.dock;
    final subscription = _kind == _CloudButtonKind.subscription;
    final title = subscription ? '订阅云服务' : label;
    final icon = Icon(
      Icons.cloud_outlined,
      color: ink,
      size: compact ? 20 : (subscription ? 19 : 23),
    );
    const corners = WeekGlassGeometry.corners;
    final content = switch (_kind) {
      _CloudButtonKind.rail => SizedBox(width: 34, height: 34, child: icon),
      _CloudButtonKind.dock => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 60, minWidth: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            icon,
            const SizedBox(height: 3),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                color: ink,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
      _ => Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 12,
          vertical: subscription ? 10 : 11,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 28),
          child: Row(
            children: [
              if (subscription)
                icon
              else
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0x88FFFFFF),
                    border: Border.all(color: const Color(0xDFFFFFFF)),
                    borderRadius: corners,
                  ),
                  child: SizedBox(width: 37, height: 37, child: icon),
                ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 3,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          title,
                          style: text.titleMedium?.copyWith(
                            color: ink,
                            fontSize: subscription ? 15 : 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (state case final status?)
                          CloudSubscriptionStateChip(
                            state: status,
                            onLight: true,
                          ),
                      ],
                    ),
                    if (detail case final description?) ...[
                      const SizedBox(height: 3),
                      Text(
                        description,
                        style: text.bodySmall?.copyWith(
                          color: const Color(0xFF3B4E72),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                subscription
                    ? Icons.open_in_new_rounded
                    : Icons.chevron_right_rounded,
                size: subscription ? 17 : 21,
                color: ink,
              ),
            ],
          ),
        ),
      ),
    };
    final button = Semantics(
      label: compact ? label : null,
      button: true,
      enabled: enabled,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: enabled ? null : palette.surfaceSoft,
          borderRadius: corners,
          border: Border.all(
            color: enabled ? const Color(0xDFFFFFFF) : palette.line,
          ),
          gradient: enabled
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    const Color(0xF7F2FDFF),
                    Color.lerp(
                      const Color(0xF7CBE6FA),
                      palette.accent.withValues(alpha: .97),
                      .16,
                    )!,
                    const Color(0xF7D9CEF9),
                  ],
                  stops: const [0, .56, 1],
                )
              : null,
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: palette.accent.withValues(alpha: .18),
                    blurRadius: compact ? 5 : 10,
                    offset: Offset(0, compact ? 1 : 3),
                  ),
                ]
              : null,
        ),
        child: IridescentGlass(
          enabled: enabled,
          child: Material(
            type: MaterialType.transparency,
            borderRadius: corners,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              borderRadius: corners,
              onTap: onPressed,
              focusColor: const Color(0x414761A7),
              hoverColor: const Color(0x277A99E6),
              splashColor: const Color(0x366484C7),
              child: content,
            ),
          ),
        ),
      ),
    );
    return shortcut
        ? Tooltip(
            message: label,
            excludeFromSemantics: true,
            child: Padding(
              padding: compact
                  ? const EdgeInsets.fromLTRB(0, 3, 0, 4)
                  : const EdgeInsets.symmetric(horizontal: 2),
              child: button,
            ),
          )
        : button;
  }
}
