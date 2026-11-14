import 'weekglass_geometry.dart';
import 'weekglass_skin.dart';
import 'crystal_decoration.dart';

import 'package:flutter/material.dart';

@immutable
class WeekGlassPalette extends ThemeExtension<WeekGlassPalette> {
  const WeekGlassPalette({
    this.skin = WeekGlassSkin.moonstone,
    this.isDark = false,
    this.reflection = const Color(0xFFF5F9FF),
    this.atmosphereOpacity = .90,
    this.atmosphereStrength = 0,
    this.cardBase = const Color(0xA01B2A43),
    this.cardEdge = const Color(0x70202C46),
    this.atmosphereTint = const Color(0xFF8EADDA),
    this.glassTop = const Color(0xFF526886),
    this.glassMiddle = const Color(0xFF17263D),
    this.glassBottom = const Color(0xFF25324B),
    this.shadow = const Color(0xFF07172F),
    required this.canvas,
    required this.sidebar,
    required this.surface,
    required this.surfaceSoft,
    required this.surfaceHover,
    required this.text,
    required this.muted,
    required this.mutedSoft,
    required this.line,
    required this.lineStrong,
    required this.accent,
    required this.accentStrong,
    required this.accentSoft,
    required this.gridLine,
    required this.gridSubline,
    required this.weekend,
    required this.currentTime,
  });

  final WeekGlassSkin skin;
  final bool isDark;
  final Color reflection;
  final double atmosphereOpacity;
  final double atmosphereStrength;
  final Color cardBase;
  final Color cardEdge;
  final Color atmosphereTint;
  final Color glassTop;
  final Color glassMiddle;
  final Color glassBottom;
  final Color shadow;
  final Color canvas;
  final Color sidebar;
  final Color surface;
  final Color surfaceSoft;
  final Color surfaceHover;
  final Color text;
  final Color muted;
  final Color mutedSoft;
  final Color line;
  final Color lineStrong;
  final Color accent;
  final Color accentStrong;
  final Color accentSoft;
  final Color gridLine;
  final Color gridSubline;
  final Color weekend;
  final Color currentTime;

  /// Recolor the raster's light, not its alpha. A blend-mode filter applies its
  /// opaque color after the image paint opacity and can flatten the whole scene.
  /// This matrix preserves alpha and black levels throughout theme animation.
  ColorFilter get atmosphereFilter {
    if (!isDark) {
      // The existing light-field texture in daylight: lift its black levels
      // into the skin's cool shade while retaining the curved lighting detail.
      final shade = daylightShade;
      final r = 1 - shade.r, g = 1 - shade.g, b = 1 - shade.b;
      return ColorFilter.matrix([
        r * .2126,
        r * .7152,
        r * .0722,
        0,
        shade.r * 255,
        g * .2126,
        g * .7152,
        g * .0722,
        0,
        shade.g * 255,
        b * .2126,
        b * .7152,
        b * .0722,
        0,
        shade.b * 255,
        0,
        0,
        0,
        1,
        0,
      ]);
    }
    final strength = atmosphereStrength;
    final neutral = 1 - strength;
    final luminance =
        atmosphereTint.r * .2126 +
        atmosphereTint.g * .7152 +
        atmosphereTint.b * .0722;
    final r = atmosphereTint.r / luminance;
    final g = atmosphereTint.g / luminance;
    final b = atmosphereTint.b / luminance;
    return ColorFilter.matrix([
      neutral + strength * r * .2126,
      strength * r * .7152,
      strength * r * .0722,
      0,
      0,
      strength * g * .2126,
      neutral + strength * g * .7152,
      strength * g * .0722,
      0,
      0,
      strength * b * .2126,
      strength * b * .7152,
      neutral + strength * b * .0722,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ]);
  }

  Color get daylightShade => Color.lerp(canvas, accent, .18)!;

  static const light = WeekGlassPalette(
    canvas: Color(0xFFE9EFF7),
    sidebar: Color(0xFFE8ECF8),
    surface: Color(0xDFFFFFFF),
    surfaceSoft: Color(0x90FFFFFF),
    surfaceHover: Color(0xF7FFFFFF),
    text: Color(0xFF222B48),
    muted: Color(0xFF53617F),
    mutedSoft: Color(0xFF63718E),
    line: Color(0xFFCCD6EE),
    lineStrong: Color(0xFFB6C5E2),
    accent: Color(0xFF5676CF),
    accentStrong: Color(0xFF465CB8),
    accentSoft: Color(0xFFDFE6FA),
    gridLine: Color(0xFFDCE3F1),
    gridSubline: Color(0xFFE8ECF7),
    weekend: Color(0xFFF0F1FA),
    currentTime: Color(0xFFB34A88),
  );

  static const dark = WeekGlassPalette(
    isDark: true,
    atmosphereOpacity: .70,
    canvas: Color(0xFF0A0F20),
    sidebar: Color(0xFF10182C),
    surface: Color(0xB8111B31),
    surfaceSoft: Color(0x70253452),
    surfaceHover: Color(0xD5324263),
    text: Color(0xFFEEF3FF),
    muted: Color(0xFFB3C1DE),
    mutedSoft: Color(0xFF8F9FBE),
    line: Color(0xFF354462),
    lineStrong: Color(0xFF566789),
    accent: Color(0xFF9CB6FF),
    accentStrong: Color(0xFFB8CAFF),
    accentSoft: Color(0xFF303654),
    gridLine: Color(0xFF30405B),
    gridSubline: Color(0xFF202D45),
    weekend: Color(0xFF181E36),
    currentTime: Color(0xFFF1A9D5),
  );

  Color get onCurrentTime => currentTime.computeLuminance() > .179
      ? const Color(0xFF11151C)
      : Colors.white;

  static WeekGlassPalette of(BuildContext context) =>
      Theme.of(context).extension<WeekGlassPalette>() ??
      (Theme.of(context).brightness == Brightness.dark ? dark : light);

  /// Fixed, curated pairs keep each skin legible in both appearances.
  static WeekGlassPalette forSkin(WeekGlassSkin skin, Brightness brightness) {
    final night = brightness == Brightness.dark;
    if (skin == WeekGlassSkin.moonstone) return night ? dark : light;
    final tones = switch (skin) {
      WeekGlassSkin.amethyst => (
        Color(0xFFEEE7F5),
        Color(0xFF161021),
        Color(0xFF76549C),
        Color(0xFFD7BBF2),
        Color(0xFFB3A0D0),
        Color(0xFF332745),
      ),
      WeekGlassSkin.roseQuartz => (
        Color(0xFFF5E7EC),
        Color(0xFF21131C),
        Color(0xFF9A4D70),
        Color(0xFFF2BBD2),
        Color(0xFFD7A1B7),
        Color(0xFF482A3B),
      ),
      WeekGlassSkin.champagne => (
        Color(0xFFF3EBDD),
        Color(0xFF211A12),
        Color(0xFF87642C),
        Color(0xFFF0D29D),
        Color(0xFFD4BB8F),
        Color(0xFF423629),
      ),
      WeekGlassSkin.glacier => (
        Color(0xFFE1EEEF),
        Color(0xFF0D1C20),
        Color(0xFF326F78),
        Color(0xFFA6DCE1),
        Color(0xFF8CBFC9),
        Color(0xFF254149),
      ),
      WeekGlassSkin.graphite => (
        Color(0xFFE9EBEE),
        Color(0xFF15171C),
        Color(0xFF59616D),
        Color(0xFFD0D6DF),
        Color(0xFFA7B0BC),
        Color(0xFF333942),
      ),
      WeekGlassSkin.moonstone => throw StateError('Default handled above'),
    };
    Color mix(Color a, Color b, double t) => Color.lerp(a, b, t)!;
    final canvas = night ? tones.$2 : tones.$1;
    final reflection = night ? tones.$4 : mix(tones.$1, Colors.white, .38);
    final foreground = night
        ? mix(Colors.white, tones.$4, .14)
        : mix(const Color(0xFF20232D), tones.$3, .16);
    return WeekGlassPalette(
      skin: skin,
      isDark: night,
      atmosphereOpacity: night ? .70 : .90,
      atmosphereStrength: 1,
      cardBase: mix(canvas, tones.$6, .40).withValues(alpha: .63),
      cardEdge: mix(canvas, tones.$6, .65).withValues(alpha: .44),
      canvas: canvas,
      sidebar: mix(canvas, tones.$5, night ? .08 : .12),
      surface:
          (night
                  ? mix(canvas, tones.$6, .22)
                  : mix(Colors.white, tones.$1, .24))
              .withValues(alpha: night ? .88 : .91),
      surfaceSoft: (night ? tones.$6 : Colors.white).withValues(
        alpha: night ? .54 : .56,
      ),
      surfaceHover: (night ? mix(tones.$6, tones.$4, .12) : Colors.white)
          .withValues(alpha: .96),
      text: foreground,
      muted: night
          ? mix(tones.$4, Colors.white, .22)
          : mix(foreground, tones.$3, .42),
      mutedSoft: night
          ? mix(tones.$4, canvas, .23)
          : mix(foreground, tones.$3, .62),
      line: mix(canvas, tones.$5, night ? .30 : .45),
      lineStrong: mix(canvas, tones.$5, night ? .62 : .72),
      accent: night ? tones.$4 : tones.$3,
      accentStrong: night ? mix(tones.$4, Colors.white, .12) : tones.$3,
      accentSoft: mix(canvas, tones.$5, night ? .20 : .28),
      gridLine: mix(canvas, tones.$5, night ? .19 : .22),
      gridSubline: mix(canvas, tones.$5, night ? .09 : .10),
      weekend: mix(canvas, tones.$5, .08),
      currentTime: night ? tones.$4 : tones.$3,
      reflection: reflection,
      atmosphereTint: tones.$5,
      glassTop: mix(tones.$6, tones.$4, .26),
      glassMiddle: mix(canvas, tones.$6, .40),
      glassBottom: mix(canvas, tones.$6, .65),
      shadow: mix(const Color(0xFF080B11), tones.$2, .42),
    );
  }

  @override
  WeekGlassPalette copyWith({
    WeekGlassSkin? skin,
    bool? isDark,
    double? atmosphereOpacity,
    double? atmosphereStrength,
    Color? cardBase,
    Color? cardEdge,
    Color? canvas,
    Color? sidebar,
    Color? surface,
    Color? surfaceSoft,
    Color? surfaceHover,
    Color? text,
    Color? muted,
    Color? mutedSoft,
    Color? line,
    Color? lineStrong,
    Color? accent,
    Color? accentStrong,
    Color? accentSoft,
    Color? gridLine,
    Color? gridSubline,
    Color? weekend,
    Color? currentTime,
    Color? reflection,
    Color? atmosphereTint,
    Color? glassTop,
    Color? glassMiddle,
    Color? glassBottom,
    Color? shadow,
  }) => WeekGlassPalette(
    skin: skin ?? this.skin,
    isDark: isDark ?? this.isDark,
    atmosphereOpacity: atmosphereOpacity ?? this.atmosphereOpacity,
    atmosphereStrength: atmosphereStrength ?? this.atmosphereStrength,
    cardBase: cardBase ?? this.cardBase,
    cardEdge: cardEdge ?? this.cardEdge,
    canvas: canvas ?? this.canvas,
    sidebar: sidebar ?? this.sidebar,
    surface: surface ?? this.surface,
    surfaceSoft: surfaceSoft ?? this.surfaceSoft,
    surfaceHover: surfaceHover ?? this.surfaceHover,
    text: text ?? this.text,
    muted: muted ?? this.muted,
    mutedSoft: mutedSoft ?? this.mutedSoft,
    line: line ?? this.line,
    lineStrong: lineStrong ?? this.lineStrong,
    accent: accent ?? this.accent,
    accentStrong: accentStrong ?? this.accentStrong,
    accentSoft: accentSoft ?? this.accentSoft,
    gridLine: gridLine ?? this.gridLine,
    gridSubline: gridSubline ?? this.gridSubline,
    weekend: weekend ?? this.weekend,
    currentTime: currentTime ?? this.currentTime,
    reflection: reflection ?? this.reflection,
    atmosphereTint: atmosphereTint ?? this.atmosphereTint,
    glassTop: glassTop ?? this.glassTop,
    glassMiddle: glassMiddle ?? this.glassMiddle,
    glassBottom: glassBottom ?? this.glassBottom,
    shadow: shadow ?? this.shadow,
  );

  @override
  WeekGlassPalette lerp(covariant WeekGlassPalette? other, double t) {
    if (other == null) return this;
    return WeekGlassPalette(
      skin: t < .5 ? skin : other.skin,
      isDark: t < .5 ? isDark : other.isDark,
      atmosphereOpacity:
          atmosphereOpacity + (other.atmosphereOpacity - atmosphereOpacity) * t,
      atmosphereStrength:
          atmosphereStrength +
          (other.atmosphereStrength - atmosphereStrength) * t,
      cardBase: Color.lerp(cardBase, other.cardBase, t)!,
      cardEdge: Color.lerp(cardEdge, other.cardEdge, t)!,
      canvas: Color.lerp(canvas, other.canvas, t)!,
      sidebar: Color.lerp(sidebar, other.sidebar, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceSoft: Color.lerp(surfaceSoft, other.surfaceSoft, t)!,
      surfaceHover: Color.lerp(surfaceHover, other.surfaceHover, t)!,
      text: Color.lerp(text, other.text, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      mutedSoft: Color.lerp(mutedSoft, other.mutedSoft, t)!,
      line: Color.lerp(line, other.line, t)!,
      lineStrong: Color.lerp(lineStrong, other.lineStrong, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentStrong: Color.lerp(accentStrong, other.accentStrong, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      gridLine: Color.lerp(gridLine, other.gridLine, t)!,
      gridSubline: Color.lerp(gridSubline, other.gridSubline, t)!,
      weekend: Color.lerp(weekend, other.weekend, t)!,
      currentTime: Color.lerp(currentTime, other.currentTime, t)!,
      reflection: Color.lerp(reflection, other.reflection, t)!,
      atmosphereTint: Color.lerp(atmosphereTint, other.atmosphereTint, t)!,
      glassTop: Color.lerp(glassTop, other.glassTop, t)!,
      glassMiddle: Color.lerp(glassMiddle, other.glassMiddle, t)!,
      glassBottom: Color.lerp(glassBottom, other.glassBottom, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
    );
  }

  /// One continuous optical surface; child regions remain transparent.
  CrystalDecoration glassDecoration({
    double radius = WeekGlassGeometry.radius,
    bool elevated = false,
    GlassLayer layer = GlassLayer.panel,
  }) => CrystalDecoration(
    dark: isDark,
    tint: isDark ? glassMiddle : reflection,
    ink: shadow,
    layer: elevated ? GlassLayer.overlay : layer,
    radius: radius,
  );

  Color eventColor(String key, {bool selected = false}) {
    final pair = switch (key) {
      'lavender' => (Color(0xFFEDE5FF), Color(0xFF60458D)),
      'sage_green' => (Color(0xFFDDF3F0), Color(0xFF326C70)),
      'soft_peach' => (Color(0xFFFFE9DD), Color(0xFF8D5745)),
      'rose' => (Color(0xFFF9E2F0), Color(0xFF844D73)),
      'warm_sand' => (Color(0xFFF8F0D6), Color(0xFF796632)),
      'slate' => (Color(0xFFE9ECF5), Color(0xFF586582)),
      _ => (Color(0xFFE1EEFF), Color(0xFF40628F)),
    };
    if (isDark) {
      final darkPair = switch (key) {
        'lavender' => (Color(0xFF46355F), Color(0xFFEAD8FF)),
        'sage_green' => (Color(0xFF234B50), Color(0xFFB9ECE8)),
        'soft_peach' => (Color(0xFF5B403D), Color(0xFFFFDAC6)),
        'rose' => (Color(0xFF523D58), Color(0xFFF6D1F2)),
        'warm_sand' => (Color(0xFF514B3C), Color(0xFFF5E7BC)),
        'slate' => (Color(0xFF3C465A), Color(0xFFE4E9F5)),
        _ => (Color(0xFF243D58), Color(0xFFC5E3FF)),
      };
      return selected ? darkPair.$2 : darkPair.$1;
    }
    return selected ? pair.$2 : pair.$1;
  }
}

class WeekGlassTheme {
  static ThemeData light({WeekGlassSkin skin = WeekGlassSkin.moonstone}) =>
      _build(
        WeekGlassPalette.forSkin(skin, Brightness.light),
        Brightness.light,
      );
  static ThemeData dark({WeekGlassSkin skin = WeekGlassSkin.moonstone}) =>
      _build(WeekGlassPalette.forSkin(skin, Brightness.dark), Brightness.dark);

  static ThemeData _build(WeekGlassPalette palette, Brightness brightness) {
    final scheme = ColorScheme(
      brightness: brightness,
      primary: palette.accentStrong,
      onPrimary: brightness == Brightness.dark
          ? palette.canvas
          : const Color(0xFFFFFFFF),
      secondary: palette.accent,
      onSecondary: brightness == Brightness.dark
          ? palette.canvas
          : const Color(0xFFFFFFFF),
      error: brightness == Brightness.dark
          ? const Color(0xFFF0A5A5)
          : const Color(0xFFA63244),
      onError: const Color(0xFFFFFFFF),
      surface: palette.surface,
      onSurface: palette.text,
      surfaceContainerHighest: palette.surfaceSoft,
      onSurfaceVariant: palette.muted,
      outline: palette.lineStrong,
      outlineVariant: palette.line,
      shadow: palette.shadow,
      scrim: palette.shadow.withValues(alpha: .60),
      inverseSurface: palette.text,
      onInverseSurface: palette.canvas,
      inversePrimary: palette.accent,
    );

    return ThemeData(
      useMaterial3: true,
      extensions: [palette],
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: 'WeekGlassSans',
      fontFamilyFallback: const ['Noto Sans CJK SC', 'sans-serif'],
      scaffoldBackgroundColor: palette.canvas,
      canvasColor: palette.canvas,
      dividerColor: palette.line,
      splashFactory: NoSplash.splashFactory,
      visualDensity: VisualDensity.standard,
      dialogTheme: const DialogThemeData(shape: WeekGlassGeometry.shape),
      cardTheme: const CardThemeData(shape: WeekGlassGeometry.shape),
      snackBarTheme: const SnackBarThemeData(shape: WeekGlassGeometry.shape),
      popupMenuTheme: const PopupMenuThemeData(shape: WeekGlassGeometry.shape),
      menuTheme: const MenuThemeData(
        style: MenuStyle(
          shape: WidgetStatePropertyAll(WeekGlassGeometry.shape),
        ),
      ),
      datePickerTheme: const DatePickerThemeData(
        shape: WeekGlassGeometry.shape,
      ),
      timePickerTheme: const TimePickerThemeData(
        shape: WeekGlassGeometry.shape,
      ),
      filledButtonTheme: const FilledButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(WeekGlassGeometry.shape),
        ),
      ),
      elevatedButtonTheme: const ElevatedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(WeekGlassGeometry.shape),
        ),
      ),
      outlinedButtonTheme: const OutlinedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(WeekGlassGeometry.shape),
        ),
      ),
      textButtonTheme: const TextButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(WeekGlassGeometry.shape),
        ),
      ),
      segmentedButtonTheme: const SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(WeekGlassGeometry.shape),
        ),
      ),
      chipTheme: const ChipThemeData(shape: WeekGlassGeometry.shape),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: palette.accentStrong,
        selectionColor: palette.accent.withValues(alpha: 0.22),
        selectionHandleColor: palette.accent,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.surfaceSoft,
        hintStyle: TextStyle(color: palette.mutedSoft, fontSize: 13),
        labelStyle: TextStyle(color: palette.muted, fontSize: 12),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 13,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: WeekGlassGeometry.corners,
          borderSide: BorderSide(color: palette.lineStrong),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: WeekGlassGeometry.corners,
          borderSide: BorderSide(color: palette.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: WeekGlassGeometry.corners,
          borderSide: BorderSide(color: palette.accent, width: 1.3),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: palette.isDark ? palette.glassBottom : palette.text,
          borderRadius: WeekGlassGeometry.corners,
        ),
        textStyle: const TextStyle(color: Colors.white, fontSize: 11),
      ),
    );
  }
}
