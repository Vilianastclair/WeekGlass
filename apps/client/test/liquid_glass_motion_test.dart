import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

// This is a compiled-shader pixel fixture, not a GPU performance benchmark.
// The same viewport, timestep and surfaces can be run with either package.
const _output = String.fromEnvironment('GLASS_MOTION_OUTPUT');
const _baseline = bool.fromEnvironment('GLASS_MOTION_BASELINE');
const _animation = bool.fromEnvironment('GLASS_MOTION_ANIMATION');
const _viewport = Size(1264, 751);
const _frame = Duration(microseconds: 16667);
const _colors = [
  'mist_blue',
  'lavender',
  'sage_green',
  'soft_peach',
  'rose',
  'warm_sand',
  'slate',
];

class _Pixels {
  const _Pixels(this.bytes, this.width);
  final Uint8List bytes;
  final int width;
}

Map<String, double> _difference(_Pixels a, _Pixels b, Rect region) {
  var sum = 0.0;
  var changed = 0;
  var count = 0;
  final differences = <double>[];
  // Keep antialiased clipping/outline out of the optical-field measurement.
  final inset = region.deflate(4);
  for (var y = inset.top.ceil(); y < inset.bottom.floor(); y++) {
    for (var x = inset.left.ceil(); x < inset.right.floor(); x++) {
      final offset = (y * a.width + x) * 4;
      var pixel = 0.0;
      var peak = 0;
      for (var channel = 0; channel < 3; channel++) {
        final delta = (a.bytes[offset + channel] - b.bytes[offset + channel])
            .abs();
        pixel += delta;
        peak = math.max(peak, delta);
      }
      pixel /= 3;
      sum += pixel;
      differences.add(pixel);
      if (peak >= 3) changed++;
      count++;
    }
  }
  differences.sort();
  return {
    'mean_rgb_delta_255': sum / count,
    'p95_rgb_delta_255': differences[(count * .95).floor()],
    'changed_fraction_at_3_levels': changed / count,
  };
}

void main() {
  for (final dark in [false, true]) {
    testWidgets('unattended lake motion is visible and smooth: '
        '${dark ? 'dark' : 'light'}', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = _viewport;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        await LiquidGlass.load();
        final font = FontLoader('MotionSpecimen')
          ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Variable.ttf'));
        await font.load();
      });
      final key = GlobalKey();
      final surfaces = <String, GlobalKey>{};
      var contentBuilds = 0;
      final canvasColor = dark
          ? const Color(0xff1c2539)
          : const Color(0xffdce5f4);
      Widget surface(
        String name,
        String color,
        double width,
        double height, {
        bool background = false,
      }) {
        final surfaceKey = surfaces[name] = GlobalKey();
        return SizedBox(
          key: surfaceKey,
          width: width,
          height: height,
          child: LiquidGlassSurface(
            colorKey: color,
            background: background,
            child: Builder(
              builder: (_) {
                contentBuilds++;
                return const SizedBox.expand();
              },
            ),
          ),
        );
      }

      Widget row(String kind, double height) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var index = 0; index < _colors.length; index++) ...[
            if (index != 0) const SizedBox(width: 12),
            surface('$kind/${_colors[index]}', _colors[index], 160, height),
          ],
        ],
      );
      final theme = dark ? ThemeData.dark() : ThemeData.light();
      await tester.pumpWidget(
        MaterialApp(
          theme: theme.copyWith(
            colorScheme: theme.colorScheme.copyWith(
              primary: const Color(0xff91a8dc),
            ),
          ),
          home: LiquidGlassScope(
            strength: .72,
            child: Center(
              child: RepaintBoundary(
                key: key,
                child: ColoredBox(
                  color: canvasColor,
                  child: SizedBox.fromSize(
                    size: _viewport,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          SizedBox(
                            height: 32,
                            child: Text(
                              'Lake / ${dark ? 'dark' : 'light'} / 72%',
                              style: TextStyle(
                                inherit: false,
                                fontFamily: 'MotionSpecimen',
                                fontSize: 18,
                                color: dark ? Colors.white : Colors.black87,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              for (
                                var index = 0;
                                index < _colors.length;
                                index++
                              ) ...[
                                if (index != 0) const SizedBox(width: 12),
                                SizedBox(
                                  width: 160,
                                  height: 16,
                                  child: Text(
                                    _colors[index],
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      inherit: false,
                                      fontFamily: 'MotionSpecimen',
                                      fontSize: 12,
                                      color: dark
                                          ? Colors.white
                                          : Colors.black87,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 8),
                          row('normal', 96),
                          const SizedBox(height: 16),
                          row('tall', 220),
                          const SizedBox(height: 16),
                          row('short', 24),
                          const SizedBox(height: 16),
                          surface(
                            'background',
                            'mist_blue',
                            1192,
                            160,
                            background: true,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final bounds = {
        for (final entry in surfaces.entries)
          entry.key: tester.getRect(find.byKey(entry.value)),
      };
      final initialBuilds = contentBuilds;
      final frames = <int, _Pixels>{};
      final themeName = dark ? 'dark' : 'light';
      var step = 0;
      for (final sample in [0, 1, 60, 120, 240]) {
        while (step < sample) {
          await tester.pump(_frame);
          step++;
        }
        frames[sample] = (await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final raw = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          if (_output.isNotEmpty) {
            final directory = Directory(_output);
            await directory.create(recursive: true);
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            await File('${directory.path}/$themeName-frame-$sample.png')
                .writeAsBytes(png!.buffer.asUint8List());
          }
          final result = _Pixels(raw!.buffer.asUint8List(), image.width);
          image.dispose();
          return result;
        }))!;
      }
      final metrics = <String, Object>{};
      for (final entry in bounds.entries) {
        final changes = <String, Object>{};
        for (final sample in [1, 60, 120, 240]) {
          changes['from_0_to_frame_$sample'] = _difference(
            frames[0]!,
            frames[sample]!,
            entry.value,
          );
        }
        metrics[entry.key] = changes;
      }
      // Keep useful measurements even when a visibility assertion fails.
      if (_output.isNotEmpty) {
        await tester.runAsync(
          () => File('$_output/$themeName-metrics.json').writeAsString(
            const JsonEncoder.withIndent('  ').convert({
              'viewport': [1264, 751],
              'strength': .72,
              'motion': true,
              'pointer_input': false,
              'frame_microseconds': 16667,
              'sample_frames': [0, 1, 60, 120, 240],
              'theme': themeName,
              'metrics': metrics,
            }),
          ),
        );
      }
      for (final entry in bounds.entries) {
        if (!_baseline && entry.key.startsWith('normal/')) {
          final visible = _difference(frames[0]!, frames[120]!, entry.value);
          // Whole-region changes, not the old "at least one pixel differs".
          expect(
            visible['mean_rgb_delta_255'],
            greaterThan(1.5),
            reason: '${entry.key} should visibly drift within two seconds.',
          );
          expect(
            visible['changed_fraction_at_3_levels'],
            greaterThan(.25),
            reason: '${entry.key} must move across a broad reflection.',
          );
          final adjacent = _difference(frames[0]!, frames[1]!, entry.value);
          expect(
            adjacent['mean_rgb_delta_255'],
            lessThan(.5),
            reason: '${entry.key} must remain gradual between vsync steps.',
          );
        }
        expect(tester.getRect(find.byKey(surfaces[entry.key]!)), entry.value);
      }
      expect(
        contentBuilds,
        initialBuilds,
        reason: 'Clock repaints cannot rebuild the content or run layout.',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  if (_animation) {
    for (final dark in [false, true]) {
      testWidgets(
        'capture 20fps lake film: ${dark ? 'dark' : 'light'}',
        (tester) => _captureFilm(tester, dark),
      );
    }
  }
}

Future<void> _captureFilm(WidgetTester tester, bool dark) async {
  expect(
    _output,
    isNotEmpty,
    reason: 'Animation captures need an output path.',
  );
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(640, 480);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.runAsync(() async {
    await LiquidGlass.load();
    final font = FontLoader('MotionSpecimen')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Variable.ttf'));
    await font.load();
  });
  final key = GlobalKey();
  const colors = ['mist_blue', 'lavender', 'soft_peach'];
  Widget row(double height) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      for (var index = 0; index < colors.length; index++) ...[
        if (index > 0) const SizedBox(width: 12),
        SizedBox(
          width: 176,
          height: height,
          child: LiquidGlassSurface(
            colorKey: colors[index],
            child: const SizedBox.expand(),
          ),
        ),
      ],
    ],
  );
  final theme = dark ? ThemeData.dark() : ThemeData.light();
  await tester.pumpWidget(
    MaterialApp(
      theme: theme.copyWith(
        colorScheme: theme.colorScheme.copyWith(
          primary: const Color(0xff91a8dc),
        ),
      ),
      home: LiquidGlassScope(
        strength: .72,
        child: RepaintBoundary(
          key: key,
          child: ColoredBox(
            color: dark ? const Color(0xff1c2539) : const Color(0xffdce5f4),
            child: DefaultTextStyle(
              style: TextStyle(
                fontFamily: 'MotionSpecimen',
                fontSize: 13,
                color: dark ? Colors.white70 : Colors.black54,
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    SizedBox(
                      height: 24,
                      child: Text(
                        'WeekGlass / ${dark ? 'dark' : 'light'} / 72% / no pointer',
                      ),
                    ),
                    const SizedBox(height: 12),
                    row(80),
                    const SizedBox(height: 12),
                    row(160),
                    const SizedBox(height: 12),
                    row(20),
                    const SizedBox(height: 12),
                    const SizedBox(
                      width: 552,
                      height: 100,
                      child: LiquidGlassSurface(
                        colorKey: 'mist_blue',
                        background: true,
                        child: SizedBox.expand(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  final directory = Directory('$_output/${dark ? 'dark' : 'light'}-20fps');
  await tester.runAsync(() => directory.create(recursive: true));
  for (var frame = 0; frame < 80; frame++) {
    if (frame != 0) await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '${directory.path}/frame-${frame.toString().padLeft(3, '0')}.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
}
