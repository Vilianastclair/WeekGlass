import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

const _width = 144;
const _height = 84;
const _colors = ['rose', 'sage_green'];

({double pigment, double transmission, int lightRange}) _sample(
  Uint8List pixels, {
  required bool rose,
}) {
  var pigment = 0;
  var alpha = 0;
  var count = 0;
  var least = 255;
  var most = 0;
  for (var y = 7; y < _height - 7; y++) {
    for (var x = 7; x < _width - 7; x++) {
      final i = (y * _width + x) * 4;
      // The channels are premultiplied. Compositing them over neutral glass
      // adds equally to R and G, so the difference measures category color.
      final redMinusGreen = pixels[i] - pixels[i + 1];
      pigment += rose ? redMinusGreen : -redMinusGreen;
      final opacity = pixels[i + 3];
      alpha += opacity;
      count++;
      least = math.min(least, opacity);
      most = math.max(most, opacity);
    }
  }
  return (
    pigment: pigment / count,
    transmission: 1 - alpha / count / 255,
    lightRange: most - least,
  );
}

void main() {
  for (final mobile in [false, true]) {
    testWidgets(
      '${mobile ? 'Phone' : 'Desktop'} event light is colorful and transmissive',
      (tester) async {
        await tester.runAsync(LiquidGlass.load);
        final keys = [for (var i = 0; i < _colors.length * 2; i++) GlobalKey()];

        Future<List<Uint8List>> paint(
          Brightness brightness,
          double strength,
        ) async {
          await tester.pumpWidget(
            MaterialApp(
              theme: brightness == Brightness.light
                  ? WeekGlassTheme.light()
                  : WeekGlassTheme.dark(),
              themeAnimationDuration: Duration.zero,
              home: LiquidGlassScope(
                motion: false,
                mobile: mobile,
                strength: strength,
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < keys.length; i++)
                        RepaintBoundary(
                          key: keys[i],
                          child: SizedBox(
                            width: _width.toDouble(),
                            height: _height.toDouble(),
                            child: i.isOdd
                                ? LiquidGlassSurface.event(
                                    colorKey: _colors[i ~/ 2],
                                    child: const SizedBox.expand(),
                                  )
                                : LiquidGlassSurface(
                                    colorKey: _colors[i ~/ 2],
                                    child: const SizedBox.expand(),
                                  ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
          return (await tester.runAsync(() async {
            final frames = <Uint8List>[];
            for (final key in keys) {
              final boundary =
                  key.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final image = await boundary.toImage(pixelRatio: 1);
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              );
              image.dispose();
              frames.add(bytes!.buffer.asUint8List());
            }
            return frames;
          }))!;
        }

        final daylight = await paint(
          Brightness.light,
          LiquidGlass.defaultStrength,
        );
        expect(tester.layers.whereType<BackdropFilterLayer>(), isEmpty);
        expect(tester.layers.whereType<ImageFilterLayer>(), isEmpty);
        expect(
          tester.layers.whereType<ClipRRectLayer>().map(
            (layer) => layer.clipBehavior,
          ),
          everyElement(isNot(Clip.antiAliasWithSaveLayer)),
        );
        final strongest = await paint(
          Brightness.light,
          LiquidGlass.maxStrength,
        );
        final dark = await paint(Brightness.dark, LiquidGlass.defaultStrength);
        final unlit = await paint(Brightness.light, 0);
        for (var i = 0; i < _colors.length; i++) {
          final generic = _sample(daylight[i * 2], rose: i == 0);
          final card = _sample(daylight[i * 2 + 1], rose: i == 0);
          final peak = _sample(strongest[i * 2 + 1], rose: i == 0);
          expect(
            card.pigment,
            greaterThan(generic.pigment + 5),
            reason: _colors[i],
          );
          expect(card.transmission, greaterThan(.70));
          expect(peak.transmission, greaterThan(.55));
          expect(
            card.lightRange,
            greaterThan(28),
            reason: 'Visible variation inside the glass',
          );
          expect(dark[i * 2 + 1], orderedEquals(dark[i * 2]));
          expect(unlit[i * 2 + 1], orderedEquals(unlit[i * 2]));
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
