import 'package:flutter/material.dart';

enum SidebarAction {
  create('新建日程', Icons.add_rounded),
  undo('撤销', Icons.undo_rounded),
  courses('导入课表', Icons.school_outlined),
  importEvents('导入日程', Icons.file_download_outlined),
  exportEvents('导出日程', Icons.ios_share_rounded),
  appearance('皮肤与外观', Icons.water_drop_outlined),
  cloud('云服务', Icons.cloud_outlined),
  updates('软件更新', Icons.system_update_alt_rounded),
  view('切换视图', Icons.view_week_outlined);

  const SidebarAction(this.label, this.icon);
  final String label;
  final IconData icon;
  bool get isCalendarFileAction => this == importEvents || this == exportEvents;

  bool availableOn(TargetPlatform platform) =>
      platform != TargetPlatform.iOS ||
      isCalendarFileAction ||
      const {create, undo, appearance, cloud, view}.contains(this);

  static const defaults = {create, undo, courses, cloud, view};
  static const iPhoneDefaults = {
    create,
    undo,
    view,
    importEvents,
    exportEvents,
  };
}
