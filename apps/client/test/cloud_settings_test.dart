import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:weekglass/features/cloud/cloud_connection.dart';
import 'package:weekglass/features/cloud/cloud_settings_dialog.dart';
import 'package:weekglass_data/weekglass_data.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

void main() {
  for (final size in [const Size(800, 600), const Size(390, 760)]) {
    testWidgets('cloud choices fit $size with enlarged text', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = SqliteEventRepository(
        factory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath,
      );
      final connection = CloudConnection(repository: repository);
      await tester.pumpWidget(
        MaterialApp(
          theme: WeekGlassTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => openCloudSettings(context, connection),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(find.text('WeekGlass 云'), findsOneWidget);
      expect(find.text('在浏览器中登录'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('自己的服务器'));
      await tester.pumpAndSettle();
      expect(find.text('服务器地址'), findsOneWidget);
      expect(find.text('自托管同步免费，由你的服务器保存日程。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      connection.dispose();
      await repository.close();
    });
  }
}
