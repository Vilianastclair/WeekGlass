import 'dart:async';

import 'package:flutter/material.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

import 'update_service.dart';

enum _UpdateChoice { skip, update }

/// Only the foreground route may offer an update; editors keep their focus.
class StartupUpdatePrompt extends StatefulWidget {
  const StartupUpdatePrompt({
    super.key,
    required this.service,
    required this.child,
  }) : settings = false,
       allowRestart = true;

  const StartupUpdatePrompt.inSettings({
    super.key,
    required this.service,
    required this.child,
    required this.allowRestart,
  }) : settings = true;

  final bool settings;
  final bool allowRestart;
  final UpdateService service;
  final Widget child;

  @override
  State<StartupUpdatePrompt> createState() => _StartupUpdatePromptState();
}

class _StartupUpdatePromptState extends State<StartupUpdatePrompt> {
  final Set<int> _pointers = {};
  late final AppLifecycleListener _lifecycle;
  late final bool Function() _plannerGate = _plannerIsFree;
  ModalRoute<dynamic>? _route;
  StartupUpdateOffer? _observedOffer;
  bool _scheduled = false;
  bool _showing = false;
  bool _observedRestart = false;

  bool _plannerIsFree() =>
      mounted && _route?.isCurrent == true && _pointers.isEmpty;

  @override
  void initState() {
    super.initState();
    _observe(widget.service);
    _lifecycle = AppLifecycleListener(onResume: _schedule);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    _schedule();
  }

  @override
  void didUpdateWidget(StartupUpdatePrompt oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service) {
      _ignore(oldWidget.service);
      _observe(widget.service);
    }
    if (oldWidget.service != widget.service ||
        widget.allowRestart != oldWidget.allowRestart)
      _schedule();
  }

  void _observe(UpdateService service) {
    _observedOffer = service.startupOffer;
    _observedRestart = service.shouldPromptForRestart;
    if (!widget.settings) service.canInstallAutomatically = _plannerGate;
    service.addListener(_updateChanged);
  }

  void _ignore(UpdateService service) {
    if (identical(service.canInstallAutomatically, _plannerGate)) {
      service.canInstallAutomatically = null;
    }
    service.removeListener(_updateChanged);
  }

  void _updateChanged() {
    final service = widget.service;
    if (service.startupOffer != _observedOffer ||
        service.shouldPromptForRestart != _observedRestart) {
      _observedOffer = service.startupOffer;
      _observedRestart = service.shouldPromptForRestart;
      _schedule();
    }
  }

  void _schedule() {
    if (_scheduled || !mounted) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) unawaited(_presentWhenReady());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _presentWhenReady() async {
    if (_showing || !_plannerIsFree()) return;
    final service = widget.service;
    if (!widget.settings && service.isAndroid)
      service.resumePendingInstallation();
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed)
      return;
    if (widget.allowRestart && service.shouldPromptForRestart) {
      _showing = true;
      try {
        await showWindowsRestartPrompt(context, service);
      } finally {
        _showing = false;
      }
      return;
    }
    final offer = service.startupOffer;
    if (widget.settings || offer == null) return;
    _showing = true;
    try {
      final choice = await showDialog<_UpdateChoice>(
        context: context,
        barrierDismissible: false,
        barrierColor: Colors.black.withValues(alpha: .24),
        animationStyle: MediaQuery.disableAnimationsOf(context)
            ? AnimationStyle.noAnimation
            : null,
        builder: (_) =>
            _StartupUpdateDialog(offer: offer, isAndroid: service.isAndroid),
      );
      switch (choice) {
        case _UpdateChoice.skip:
          unawaited(service.skipStartupVersion(offer));
        case _UpdateChoice.update:
          unawaited(service.acceptStartupUpdate(offer));
        case null:
          break;
      }
    } finally {
      _showing = false;
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (event) => _pointers.add(event.pointer),
    onPointerUp: (event) {
      _pointers.remove(event.pointer);
      _schedule();
    },
    onPointerCancel: (event) {
      _pointers.remove(event.pointer);
      _schedule();
    },
    child: widget.child,
  );

  @override
  void dispose() {
    _ignore(widget.service);
    _lifecycle.dispose();
    super.dispose();
  }
}

class _StartupUpdateDialog extends StatelessWidget {
  const _StartupUpdateDialog({required this.offer, required this.isAndroid});

  final StartupUpdateOffer offer;
  final bool isAndroid;

  @override
  Widget build(BuildContext context) {
    final palette = WeekGlassPalette.of(context);
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      child: GlassAlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
        contentPadding: const EdgeInsets.fromLTRB(24, 14, 24, 16),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        title: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: palette.accent.withValues(alpha: .12),
                borderRadius: WeekGlassGeometry.corners,
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.system_update_alt_rounded,
                color: palette.accentStrong,
                size: 18,
              ),
            ),
            const SizedBox(width: 12),
            const Flexible(child: Text('发现新版本')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('WeekGlass ${offer.version} 已发布，是否更新？'),
            const SizedBox(height: 8),
            Text(
              isAndroid ? '后台下载后，请在系统确认安装。' : '下载完成后会询问是否重启安装。',
              style: theme.textTheme.bodySmall?.copyWith(color: palette.muted),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _UpdateChoice.skip),
            child: const Text('跳过此版本'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _UpdateChoice.update),
            child: const Text('立即更新'),
          ),
        ],
      ),
    );
  }
}

Future<void> showWindowsRestartPrompt(
  BuildContext context,
  UpdateService service,
) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  barrierColor: Colors.black.withValues(alpha: .24),
  animationStyle: MediaQuery.disableAnimationsOf(context)
      ? AnimationStyle.noAnimation
      : null,
  builder: (context) => PopScope(
    canPop: false,
    child: ListenableBuilder(
      listenable: service,
      builder: (context, _) => GlassAlertDialog(
        title: const Text('重启并更新？'),
        content: Text(
          service.busy
              ? service.message
              : 'WeekGlass ${service.available?['version'] ?? ''} 已就绪。重启前会保存日程。',
        ),
        actions: [
          TextButton(
            onPressed: service.busy
                ? null
                : () async {
                    if (service.busy) return;
                    await service.deferWindowsRestart();
                    if (context.mounted) Navigator.pop(context);
                  },
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: service.busy
                ? null
                : () async {
                    if (service.busy) return;
                    await service.install();
                    if (context.mounted) Navigator.pop(context);
                  },
            child: const Text('重启更新'),
          ),
        ],
      ),
    ),
  ),
);
