import 'package:flutter/material.dart';
import 'package:weekglass_design_system/weekglass_design_system.dart';

import '../calendar_io/calendar_io.dart';
import '../cloud/cloud_settings_dialog.dart';
import '../course_import/course_import_dialog.dart';
import '../updates/update_service.dart';
import '../updates/update_settings_tile.dart';
import 'event_editor_dialog.dart';
import 'planner_controller.dart';
import 'sidebar_action.dart';
import 'skin_picker_dialog.dart';

Future<void> openPlannerAction(
  BuildContext context,
  PlannerController controller,
  SidebarAction action,
) async {
  switch (action) {
    case SidebarAction.create:
      await openEventEditor(
        context,
        controller: controller,
        date: controller.anchorDate,
      );
    case SidebarAction.undo:
      await controller.undo();
    case SidebarAction.courses:
      await openCourseImport(context, controller);
    case SidebarAction.importEvents:
      await openCalendarImport(context, controller);
    case SidebarAction.exportEvents:
      await openCalendarExport(context, controller);
    case SidebarAction.appearance:
      await openSkinPicker(context, controller);
    case SidebarAction.cloud:
      if (controller.cloud case final cloud?) {
        await openCloudSettings(context, cloud);
      }
    case SidebarAction.updates:
      if (context.mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => GlassAlertDialog(
            title: const Text('软件更新'),
            content: SizedBox(
              width: 440,
              child: UpdateSettingsTile(service: UpdateService.instance),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
      }
    case SidebarAction.view:
      break;
  }
}
