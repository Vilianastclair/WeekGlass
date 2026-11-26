import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:weekglass/app/app_services.dart';
import 'package:weekglass/features/cloud/cloud_auth_service.dart';
import 'package:weekglass/features/planner/event_editor_dialog.dart';
import 'package:weekglass/features/planner/glass_event_card.dart';
import 'package:weekglass/main.dart' as weekglass;

const _title = '小组短会';
const _notes = '材料：周计划样稿。\n会议室 B2，带上笔记。';
const _range = '09:00 — 10:00';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS creates or reopens a local calendar event', (
    tester,
  ) async {
    expect(Platform.isMacOS, isTrue, reason: 'Run on the macOS device.');
    final env = Platform.environment;
    final phase = env['WEEKGLASS_MAC_SMOKE_PHASE'];
    if (phase != 'create' && phase != 'reopen') {
      throw StateError('Set WEEKGLASS_MAC_SMOKE_PHASE to create or reopen.');
    }
    final runId = env['WEEKGLASS_MAC_SMOKE_ID'] ?? '';
    if (!RegExp(r'^[A-Za-z0-9-]{8,64}$').hasMatch(runId)) {
      throw StateError('Set WEEKGLASS_MAC_SMOKE_ID to a fresh random ID.');
    }

    // Keep the SQLite file in the test application's own cache directory.
    // The host never opens the application's sandbox container.
    final cache = await getTemporaryDirectory();
    final data = Directory(p.join(cache.path, 'weekglass-smoke-$runId'));
    final marker = File(p.join(data.path, 'created.pid'));
    final database = File(p.join(data.path, 'weekglass.sqlite3'));
    final creating = phase == 'create';
    if (creating) {
      expect(await data.exists(), isFalse, reason: 'Use a fresh run ID.');
      await data.create(recursive: true);
    } else {
      expect(await marker.exists(), isTrue, reason: 'Run create first.');
      final firstPid = int.parse(await marker.readAsString());
      expect(pid, isNot(firstPid), reason: 'Relaunch the native process.');
    }

    final boundary = GlobalKey();
    AppServices? services;
    var preserveForReopen = false;
    try {
      if (!creating) {
        expect(
          await database.exists(),
          isTrue,
          reason: 'Use the saved SQLite file.',
        );
      }
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      final startup = Stopwatch()..start();
      await weekglass.runWeekGlass(
        const [],
        createServices: () async => services = await AppServices.create(
          dataDirectory: data,
          cloudAuth: CloudAuthService(
            vault: _SignedOutVault(),
            transport: (_, _, _, _, _) async {
              throw StateError(
                'Network access is outside this local smoke test.',
              );
            },
          ),
        ),
        wrapApp: (app) => RepaintBoundary(key: boundary, child: app),
      );
      final createButton = find.byTooltip('新建日程').hitTestable();
      await _waitFor(
        tester,
        () => createButton.evaluate().isNotEmpty,
        'planner',
      );
      stdout.writeln(
        'WeekGlass macOS $phase pid=$pid plannerMs=${startup.elapsedMilliseconds}',
      );

      final card = find.byWidgetPredicate(
        (widget) => widget is GlassEventCard && widget.event.title == _title,
        description: 'saved calendar card',
      );
      if (creating) {
        expect(card, findsNothing);
        await _createEvent(tester, createButton);
        await _waitFor(
          tester,
          () => card.hitTestable().evaluate().isNotEmpty,
          'saved card',
        );
        expect(card, findsOneWidget);
        await _capture(binding, boundary, tester, 'create-planner');
        expect(await database.exists(), isTrue);
      } else {
        // The event must come from SQLite after a new native process launched.
        await _waitFor(
          tester,
          () => card.evaluate().isNotEmpty,
          'reopened card',
        );
        expect(card, findsOneWidget);
        await tester.ensureVisible(card);
        await tester.tap(card.hitTestable());
        final details = find.byType(Dialog);
        final note = find.descendant(
          of: details,
          matching: find.byType(SelectableText),
        );
        await _waitFor(
          tester,
          () => note.evaluate().isNotEmpty,
          'event details',
        );
        expect(
          find.descendant(of: details, matching: find.text(_title)),
          findsOneWidget,
        );
        expect(tester.widget<SelectableText>(note).data, _notes);
        expect(
          find.descendant(
            of: details,
            matching: find.textContaining('\n$_range'),
          ),
          findsOneWidget,
        );
        await _capture(binding, boundary, tester, 'reopen-details');
      }

      await services!.eventRepository.close();
      services = null;
      if (creating) {
        await marker.writeAsString('$pid', flush: true);
        preserveForReopen = true;
      }
    } catch (_) {
      if (boundary.currentContext != null) {
        try {
          await _capture(binding, boundary, tester, '$phase-failure');
        } catch (captureError) {
          stderr.writeln('Could not capture the $phase failure: $captureError');
        }
      }
      rethrow;
    } finally {
      try {
        await services?.eventRepository.close();
      } finally {
        if (!preserveForReopen) await data.delete(recursive: true);
      }
    }
  });
}

Future<void> _createEvent(WidgetTester tester, Finder createButton) async {
  await tester.tap(createButton);
  final editor = find.byType(EventEditorDialog);
  final titleField = _textField('留空即可预留一段时间');
  await _waitFor(
    tester,
    () => titleField.hitTestable().evaluate().isNotEmpty,
    'event title field',
  );
  await tester.enterText(titleField, _title);

  final noteToggle = find.text('备注（选填）');
  await tester.ensureVisible(noteToggle);
  await tester.pump();
  await tester.tap(noteToggle.hitTestable());
  final noteField = _textField('记录想法、地点或准备事项…');
  await _waitFor(
    tester,
    () => noteField.evaluate().isNotEmpty,
    'event note field',
  );
  await tester.pump(const Duration(milliseconds: 240));
  await tester.ensureVisible(noteField);
  await tester.pump();
  await tester.enterText(noteField.hitTestable(), _notes);

  final save = find.text('保存日程').hitTestable();
  await tester.tap(save);
  await _waitFor(tester, () => editor.evaluate().isEmpty, 'event save');
}

Finder _textField(String hint) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.hintText == hint,
  description: 'text field $hint',
);

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() ready,
  String description,
) async {
  final watch = Stopwatch()..start();
  do {
    await tester.pump(const Duration(milliseconds: 50));
    if (ready()) return;
  } while (watch.elapsed < const Duration(seconds: 12));
  fail('Timed out waiting for $description.');
}

Future<void> _capture(
  IntegrationTestWidgetsFlutterBinding binding,
  GlobalKey boundary,
  WidgetTester tester,
  String name,
) async {
  await tester.pump(const Duration(milliseconds: 300));
  final layer =
      boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await layer.toImage(pixelRatio: tester.view.devicePixelRatio);
  try {
    final png = (await image.toByteData(format: ImageByteFormat.png))!;
    final report = binding.reportData ??= <String, dynamic>{};
    final screenshots =
        report.putIfAbsent('screenshots', () => <dynamic>[]) as List<dynamic>;
    screenshots.add({
      'screenshotName': name,
      'bytes': png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
    });
  } finally {
    image.dispose();
  }
}

class _SignedOutVault implements CloudTokenVault {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> clear() async {}

  @override
  Future<void> write(String value) async {
    throw StateError('The macOS smoke test must stay signed out.');
  }
}
