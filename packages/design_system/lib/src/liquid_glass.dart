import 'dart:math' as math;
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'weekglass_geometry.dart';

/// Shared material resources. A shader instance belongs to one painted surface;
/// the compiled program and animation clock are shared by the whole window.
abstract final class LiquidGlass {
  static const defaultStrength = .72;
  static const maxStrength = 1.25;
  static ui.FragmentProgram? _program;
  static ui.FragmentProgram? _mobileProgram;
  static ui.Image? _noise;
  static Future<void>? _loading;

  /// Preload once at application startup, before creating the first scope.
  static Future<void> load() => _loading ??= _load();
  static Future<void> _load() async {
    await Future.wait([_loadDesktop(), _loadMobile()]);
  }

  static Future<void> _loadMobile() async {
    try {
      _mobileProgram = await ui.FragmentProgram.fromAsset(
        'packages/weekglass_design_system/shaders/liquid_glass_mobile.frag',
      );
    } catch (error) {
      debugPrint('WeekGlass mobile liquid material unavailable: $error');
    }
  }

  static Future<void> _loadDesktop() async {
    try {
      // The approved lattice is immutable: calculate its hashes once, then
      // let the GPU interpolate a small shared texture instead of evaluating
      // dozens of trigonometric hashes per pixel on every surface/frame.
      const edge = 129;
      final bytes = Uint8List(edge * edge * 4);
      for (var y = 0; y < edge; y++) {
        for (var x = 0; x < edge; x++) {
          final hash =
              math.sin((x % 128) * 127.1 + (y % 128) * 311.7) * 43758.5453123;
          final value = ((hash - hash.floor()) * 255).round();
          final offset = (y * edge + x) * 4;
          bytes[offset] = bytes[offset + 1] = bytes[offset + 2] = value;
          bytes[offset + 3] = 255;
        }
      }
      final ready = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        bytes,
        edge,
        edge,
        ui.PixelFormat.rgba8888,
        ready.complete,
      );
      _noise = await ready.future;
      _program = await ui.FragmentProgram.fromAsset(
        'packages/weekglass_design_system/shaders/liquid_glass.frag',
      );
    } catch (error) {
      // A graphics/asset failure leaves a quiet, translucent static material.
      debugPrint('WeekGlass liquid material unavailable: $error');
    }
  }

  static double normalizeStrength(double value) =>
      value.isFinite ? value.clamp(0, maxStrength) : defaultStrength;

  static Color tint(String key) => switch (key) {
    'lavender' => const Color.fromRGBO(179, 122, 230, 1),
    'sage_green' => const Color.fromRGBO(87, 186, 189, 1),
    'soft_peach' => const Color.fromRGBO(239, 163, 122, 1),
    'rose' => const Color.fromRGBO(224, 133, 179, 1),
    'warm_sand' => const Color.fromRGBO(213, 182, 97, 1),
    'slate' => const Color.fromRGBO(149, 168, 199, 1),
    _ => const Color.fromRGBO(107, 166, 250, 1),
  };

  /// Pigments for daylight event glass, before mixing with the lake light.
  /// The dark material keeps its original palette.
  static Color daylightEventTint(String key) => switch (key) {
    'lavender' => const Color(0xFFA34FED),
    'sage_green' => const Color(0xFF29A9A5),
    'soft_peach' => const Color(0xFFF67B4E),
    'rose' => const Color(0xFFE14E89),
    'warm_sand' => const Color(0xFFDEAB32),
    'slate' => const Color(0xFF798598),
    _ => const Color(0xFF3F87F4),
  };

  static double phase(String key) => switch (key) {
    'lavender' => 7.3,
    'sage_green' => 14.6,
    'soft_peach' => 21.9,
    'rose' => 29.2,
    'warm_sand' => 36.5,
    'slate' => 43.8,
    _ => 0,
  };
}

/// One repaint clock, no per-frame widget builds or calendar layout changes.
/// Pause preserves the current reflection. Hidden windows, reduced motion and
/// muted routes do not advance it. No listeners means no scheduled frames.
class LiquidGlassScope extends StatefulWidget {
  const LiquidGlassScope({
    super.key,
    required this.child,
    this.strength = LiquidGlass.defaultStrength,
    this.motion = true,
    this.mobile = false,
  });
  final Widget child;
  final double strength;
  final bool motion;
  final bool mobile;

  @override
  State<LiquidGlassScope> createState() => _LiquidGlassScopeState();
}

class _LiquidGlassScopeState extends State<LiquidGlassScope>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final _LakeClock clock = _LakeClock(createTicker);
  AppLifecycleState? lifecycle;

  @override
  void initState() {
    super.initState();
    lifecycle = WidgetsBinding.instance.lifecycleState;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (mounted) setState(() => lifecycle = state);
  }

  @override
  Widget build(BuildContext context) {
    final motion =
        widget.motion &&
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed);
    final program = widget.mobile
        ? LiquidGlass._mobileProgram
        : LiquidGlass._program;
    clock.active = motion && widget.strength > 0 && program != null;
    return _LiquidMaterial(
      clock: clock,
      program: program,
      mobile: widget.mobile,
      strength: LiquidGlass.normalizeStrength(widget.strength),
      motion: motion,
      child: widget.child,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    clock.dispose();
    super.dispose();
  }
}

class _LakeClock extends ChangeNotifier {
  _LakeClock(Ticker Function(TickerCallback) createTicker) {
    ticker = createTicker(_tick);
  }
  late final Ticker ticker;
  double seconds = 0;
  Duration previous = Duration.zero;
  bool _active = false;

  set active(bool value) {
    if (_active == value) return;
    _active = value;
    _sync();
  }

  void _sync() {
    if (_active && hasListeners) {
      if (!ticker.isActive) {
        previous = Duration.zero;
        ticker.start();
      }
    } else {
      ticker.stop();
    }
  }

  void _tick(Duration elapsed) {
    final delta = ((elapsed - previous).inMicroseconds / 1e6).clamp(0.0, .05);
    previous = elapsed;
    seconds += delta;
    // Vsync also carries touch/wake/ripple feedback. Dropping the fractional
    // remainder of a 30 Hz cap produced uneven 20–30 Hz steps on 60 Hz displays.
    notifyListeners();
  }

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _sync();
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    _sync();
  }

  @override
  void dispose() {
    ticker.dispose();
    super.dispose();
  }
}

class _LiquidMaterial extends InheritedWidget {
  const _LiquidMaterial({
    required this.clock,
    required this.program,
    required this.mobile,
    required this.strength,
    required this.motion,
    required super.child,
  });
  final _LakeClock clock;
  final ui.FragmentProgram? program;
  final bool mobile;
  final double strength;
  final bool motion;

  @override
  bool updateShouldNotify(_LiquidMaterial oldWidget) =>
      program != oldWidget.program ||
      mobile != oldWidget.mobile ||
      strength != oldWidget.strength ||
      motion != oldWidget.motion ||
      clock != oldWidget.clock;
}

/// A small prismatic reflection for highlighted controls. Only its paint
/// layer listens to the same clock as the surrounding glass.
class IridescentGlass extends StatefulWidget {
  const IridescentGlass({super.key, required this.child, this.enabled = true});

  final Widget child;
  final bool enabled;

  @override
  State<IridescentGlass> createState() => _IridescentGlassState();
}

class _IridescentGlassState extends State<IridescentGlass> {
  double? _heldTime;

  @override
  Widget build(BuildContext context) {
    final material = context
        .dependOnInheritedWidgetOfExactType<_LiquidMaterial>();
    final clock = material?.clock;
    final moving =
        widget.enabled &&
        material?.motion == true &&
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context) &&
        ModalRoute.isCurrentOf(context) != false;
    if (moving) {
      _heldTime = null;
    } else {
      _heldTime ??= clock?.seconds ?? 0;
    }
    return Stack(
      fit: StackFit.passthrough,
      children: [
        if (widget.enabled)
          Positioned.fill(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _PrismReflection(
                  clock: moving ? clock : null,
                  heldTime: _heldTime ?? 0,
                ),
              ),
            ),
          ),
        widget.child,
      ],
    );
  }
}

class _PrismReflection extends CustomPainter {
  _PrismReflection({required this.clock, required this.heldTime})
    : super(repaint: clock);

  final _LakeClock? clock;
  final double heldTime;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final phase =
        .5 - .5 * math.cos((clock?.seconds ?? heldTime) * math.pi / 2.8 + 1.15);
    final shift = -1.05 + 2.1 * phase;
    final gradient = LinearGradient(
      begin: Alignment(shift - .58, .32),
      end: Alignment(shift + .58, -.32),
      colors: const [
        Color(0x006BEEDC),
        Color(0x526BEEDC),
        Color(0xADFFFFFF),
        Color(0x69FAC7E8),
        Color(0x00FAC7E8),
      ],
      stops: const [0, .30, .46, .66, 1],
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        rect,
        const Radius.circular(WeekGlassGeometry.radius),
      ).deflate(1),
      Paint()..shader = gradient.createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_PrismReflection oldDelegate) =>
      clock != oldDelegate.clock || heldTime != oldDelegate.heldTime;
}

/// Clear body → local flowing color → one stable outline → untouched content.
/// The optical layer never changes a hit target, size, position or text layout.
class LiquidGlassSurface extends StatefulWidget {
  const LiquidGlassSurface({
    super.key,
    required this.colorKey,
    required this.child,
    this.background = false,
    this.active = true,
  }) : _event = false;

  /// A calendar card or a swatch of its category glass.
  const LiquidGlassSurface.event({
    super.key,
    required this.colorKey,
    required this.child,
    this.active = true,
  }) : background = false,
       _event = true;

  final bool background;
  final bool _event;

  /// Whether this surface listens to the shared material clock. Offscreen
  /// callers can retain its content and gestures without repainting its optics.
  /// Inactive material stays at its captured phase, even if an ancestor paints;
  /// reactivation joins the shared clock's current phase without a new ticker.
  final bool active;
  final String colorKey;
  final Widget child;

  @override
  State<LiquidGlassSurface> createState() => _LiquidGlassSurfaceState();
}

class _LiquidGlassSurfaceState extends State<LiquidGlassSurface> {
  ui.FragmentProgram? program;
  ui.FragmentShader? shader;
  final pointer = _LakePointer();
  double? inactiveTime;

  @override
  Widget build(BuildContext context) {
    final material = context
        .dependOnInheritedWidgetOfExactType<_LiquidMaterial>();
    final nextProgram = material == null
        ? LiquidGlass._program
        : material.program;
    if (program != nextProgram) {
      shader?.dispose();
      program = nextProgram;
      shader = program?.fragmentShader();
      if (shader != null &&
          material?.mobile != true &&
          LiquidGlass._noise != null) {
        shader!.setImageSampler(
          0,
          LiquidGlass._noise!,
          filterQuality: FilterQuality.low,
        );
      }
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    final daylightEvent = widget._event && !dark;
    final motion = widget.active && (material?.motion ?? false);
    if (widget.active) {
      inactiveTime = null;
    } else {
      inactiveTime ??= material?.clock.seconds ?? 0;
      pointer.clear();
    }
    return LayoutBuilder(
      builder: (context, size) => Listener(
        onPointerDown: motion
            ? (event) {
                pointer.pressTime = material?.clock.seconds ?? 0;
                pointer.press = Offset(
                  event.localPosition.dx / size.maxWidth,
                  event.localPosition.dy / size.maxHeight,
                );
                pointer.target = pointer.press;
                pointer.targetActive = 1;
              }
            : null,
        onPointerMove: motion
            ? (event) {
                pointer.target = Offset(
                  (event.localPosition.dx / size.maxWidth).clamp(0, 1),
                  (event.localPosition.dy / size.maxHeight).clamp(0, 1),
                );
                pointer.targetActive = 1;
              }
            : null,
        onPointerUp: (event) {
          if (event.kind != ui.PointerDeviceKind.mouse)
            pointer.targetActive = 0;
        },
        onPointerCancel: (_) => pointer.targetActive = 0,
        child: MouseRegion(
          onHover: motion
              ? (event) {
                  pointer.target = Offset(
                    (event.localPosition.dx / size.maxWidth).clamp(0, 1),
                    (event.localPosition.dy / size.maxHeight).clamp(0, 1),
                  );
                  pointer.targetActive = 1;
                }
              : null,
          onExit: (_) => pointer.targetActive = 0,
          child: ClipRRect(
            borderRadius: WeekGlassGeometry.corners,
            // Calendar/sidebar already establish the shared glass backdrop.
            // Re-blurring it inside every moving card creates N offscreen
            // filters and makes a dense timetable much more expensive.
            child: Stack(
              fit: StackFit.passthrough,
              children: [
                Positioned.fill(
                  child: IgnorePointer(
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: _LakePainter(
                          clock: material?.clock,
                          active: widget.active,
                          inactiveTime: inactiveTime,
                          shader: shader,
                          dark: dark,
                          daylightEvent: daylightEvent,
                          tint: widget.background
                              ? Theme.of(context).colorScheme.primary
                              : daylightEvent
                              ? LiquidGlass.daylightEventTint(widget.colorKey)
                              : LiquidGlass.tint(widget.colorKey),
                          phase: LiquidGlass.phase(widget.colorKey),
                          strength:
                              material?.strength ?? LiquidGlass.defaultStrength,
                          motion: motion,
                          mobile: material?.mobile ?? false,
                          pointer: pointer,
                          background: widget.background,
                        ),
                      ),
                    ),
                  ),
                ),
                widget.child,
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    shader?.dispose();
    super.dispose();
  }
}

class _LakePointer {
  Offset target = const Offset(.35, .38);
  Offset current = const Offset(.35, .38);
  double targetActive = 0, active = 0, lastTime = 0;
  double pressTime = -100;
  Offset press = Offset.zero;

  void clear() {
    active = targetActive = 0;
    current = target;
    pressTime = -100;
  }

  void advance(double time, {double idleThreshold = .00001}) {
    final dt = (time - lastTime).clamp(0.0, .05);
    lastTime = time;
    // Below this amplitude the displacement is subpixel even on dense phone
    // screens. Finish the decay so idle surfaces can skip interaction math.
    // Keep this threshold aligned with the shader's uniform hover branch.
    if (targetActive == 0 && active <= idleThreshold) {
      active = 0;
      current = target;
      return;
    }
    // Same damping as the approved 60 Hz preview, independent of paint rate.
    final step = 1 - math.pow(1 - .075, dt * 60);
    current = Offset.lerp(current, target, step.toDouble())!;
    active += (targetActive - active) * step;
  }
}

class _LakePainter extends CustomPainter {
  _LakePainter({
    required this.clock,
    required this.active,
    required this.inactiveTime,
    required this.shader,
    required this.dark,
    required this.daylightEvent,
    required this.tint,
    required this.phase,
    required this.strength,
    required this.motion,
    required this.mobile,
    required this.pointer,
    required this.background,
  }) : super(repaint: active ? clock : null);
  final _LakeClock? clock;
  final bool active;
  final double? inactiveTime;
  final ui.FragmentShader? shader;
  final bool dark, motion, background, mobile, daylightEvent;
  final Color tint;
  final double phase, strength;
  final _LakePointer pointer;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final radius = math.min(WeekGlassGeometry.radius, size.shortestSide / 2);
    final shape = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    // The surface's ClipRRect already clips the phone reflection layer.
    if (!mobile) {
      canvas.save();
      canvas.clipRRect(shape);
    }
    final body = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      stops: const [0, .65, 1],
      colors: dark
          ? const [Color(0x17D5DFFF), Color(0x079CACE0), Color(0x0BC8D6FF)]
          : [
              Colors.white.withValues(alpha: .28),
              Colors.white.withValues(alpha: .055),
              Colors.white.withValues(alpha: .17),
            ],
    );
    if (!background) {
      canvas.drawRect(rect, Paint()..shader = body.createShader(rect));
    }
    final time = inactiveTime ?? clock?.seconds ?? 0;
    if (motion) pointer.advance(time, idleThreshold: mobile ? .001 : .00001);
    final effect = shader;
    if (strength > 0 && effect != null) {
      final values = [
        size.width,
        size.height,
        time,
        strength,
        dark ? 1.0 : 0.0,
        motion ? pointer.active : 0.0,
        phase,
        pointer.current.dx,
        pointer.current.dy,
        tint.r,
        tint.g,
        tint.b,
        background ? 1.0 : 0.0,
        pointer.press.dx,
        pointer.press.dy,
        motion ? time - pointer.pressTime : 100.0,
        motion ? pointer.target.dx - pointer.current.dx : 0.0,
        motion ? pointer.target.dy - pointer.current.dy : 0.0,
        daylightEvent ? 1.0 : 0.0,
      ];
      for (var i = 0; i < values.length; i++) {
        effect.setFloat(i, values[i]);
      }
      canvas.drawRect(rect, Paint()..shader = effect);
    } else if (strength > 0) {
      canvas.drawRect(
        rect,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-.3, -.2),
            radius: 1.1,
            colors: [
              tint.withValues(alpha: (daylightEvent ? .27 : .13) * strength),
              tint.withValues(alpha: (daylightEvent ? .04 : .025) * strength),
            ],
          ).createShader(rect),
      );
    }
    if (!background) {
      canvas.drawRRect(
        shape.deflate(.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Colors.white.withValues(alpha: dark ? .259 : .74),
      );
    }
    if (!mobile) canvas.restore();
  }

  @override
  bool shouldRepaint(_LakePainter oldDelegate) =>
      active != oldDelegate.active ||
      inactiveTime != oldDelegate.inactiveTime ||
      background != oldDelegate.background ||
      shader != oldDelegate.shader ||
      dark != oldDelegate.dark ||
      daylightEvent != oldDelegate.daylightEvent ||
      tint != oldDelegate.tint ||
      phase != oldDelegate.phase ||
      strength != oldDelegate.strength ||
      motion != oldDelegate.motion ||
      mobile != oldDelegate.mobile ||
      clock != oldDelegate.clock;
}
