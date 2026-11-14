import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

double contrast(Color a, Color b) {
  final first = a.computeLuminance(), second = b.computeLuminance();
  return (math.max(first, second) + .05) / (math.min(first, second) + .05);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('recoloring a dark raster preserves image transparency', () async {
    final sourceRecorder = ui.PictureRecorder();
    final sourceCanvas = Canvas(sourceRecorder);
    sourceCanvas.drawColor(Colors.black, BlendMode.src);
    final sourcePicture = sourceRecorder.endRecording();
    final source = await sourcePicture.toImage(2, 2);
    for (final skin in WeekGlassSkin.values) {
      for (final brightness in Brightness.values) {
        final palette = WeekGlassPalette.forSkin(skin, brightness);
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawColor(palette.canvas, BlendMode.src);
        paintImage(
          canvas: canvas,
          rect: const Rect.fromLTWH(0, 0, 2, 2),
          image: source,
          opacity: palette.atmosphereOpacity,
          colorFilter: palette.atmosphereFilter,
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(2, 2);
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final expected = Color.alphaBlend(
          (palette.isDark ? Colors.black : palette.daylightShade).withValues(
            alpha: palette.atmosphereOpacity,
          ),
          palette.canvas,
        );
        expect(
          bytes.getUint8(0),
          closeTo(expected.r * 255, 2),
          reason: skin.id,
        );
        expect(
          bytes.getUint8(1),
          closeTo(expected.g * 255, 2),
          reason: skin.id,
        );
        expect(
          bytes.getUint8(2),
          closeTo(expected.b * 255, 2),
          reason: skin.id,
        );
        image.dispose();
        picture.dispose();
      }
    }
    source.dispose();
    sourcePicture.dispose();
  });

  test('all skins keep content and controls readable on their glass', () {
    for (final skin in WeekGlassSkin.values) {
      for (final brightness in Brightness.values) {
        final palette = WeekGlassPalette.forSkin(skin, brightness);
        final theme = brightness == Brightness.dark
            ? WeekGlassTheme.dark(skin: skin)
            : WeekGlassTheme.light(skin: skin);
        final surfaces = [
          palette.canvas,
          Color.alphaBlend(palette.surface, palette.canvas),
          ...palette.glassDecoration().gradient!.colors.map(
            (stop) => Color.alphaBlend(stop, palette.canvas),
          ),
        ];
        for (final background in surfaces) {
          expect(
            contrast(palette.text, background),
            greaterThanOrEqualTo(4.5),
            reason: '${skin.id}/$brightness primary text',
          );
          expect(
            contrast(palette.muted, background),
            greaterThanOrEqualTo(4.5),
            reason: '${skin.id}/$brightness secondary text',
          );
        }
        expect(
          contrast(theme.colorScheme.primary, theme.colorScheme.onPrimary),
          greaterThanOrEqualTo(4.5),
          reason: '${skin.id}/$brightness action',
        );
        expect(
          contrast(palette.currentTime, palette.onCurrentTime),
          greaterThanOrEqualTo(4.5),
          reason: '${skin.id}/$brightness clock',
        );
      }
    }
  });

  test('appearance does not change event category meaning', () {
    const keys = [
      'lavender',
      'sage_green',
      'soft_peach',
      'rose',
      'warm_sand',
      'slate',
      'blue',
    ];
    for (final brightness in Brightness.values) {
      final original = WeekGlassPalette.forSkin(
        WeekGlassSkin.moonstone,
        brightness,
      );
      for (final skin in WeekGlassSkin.values) {
        final palette = WeekGlassPalette.forSkin(skin, brightness);
        for (final key in keys) {
          expect(palette.eventColor(key), original.eventColor(key));
          expect(
            palette.eventColor(key, selected: true),
            original.eventColor(key, selected: true),
          );
        }
      }
    }
  });

  testWidgets(
    'theme inheritance reaches controls without a separate palette switch',
    (tester) async {
      WeekGlassPalette? inherited;
      await tester.pumpWidget(
        MaterialApp(
          theme: WeekGlassTheme.dark(skin: WeekGlassSkin.roseQuartz),
          home: Builder(
            builder: (context) {
              inherited = WeekGlassPalette.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(inherited!.skin, WeekGlassSkin.roseQuartz);
      expect(inherited!.isDark, isTrue);
      final transition = inherited!.lerp(
        WeekGlassPalette.forSkin(WeekGlassSkin.glacier, Brightness.dark),
        .5,
      );
      expect(transition.isDark, isTrue);
      expect(transition.canvas, isNot(inherited!.canvas));
      expect(transition.eventColor('rose'), inherited!.eventColor('rose'));
    },
  );
}
