# iPhone 开发与验收

本分支 `client/ios` 基于 Android 0.22.11+60 的 `57dd4a3`。比对 macOS 0.22.12+61 后，两边的领域、数据和设计系统代码一致；此处沿用移动分支的周历、手势和编辑器。Runner 使用项目固定的 Flutter 3.47.9（Dart 3.13.7）Swift 模板，目标为 iOS 15 及以上的 iPhone。工程位于 [Runner 工作区](../../apps/client/ios/Runner.xcworkspace)。

准备好 Xcode、iOS 模拟器运行时、Python 3 和上述 Flutter 后，在 Mac 上从本分支源码根目录运行：

```sh
python3 tooling/scripts/test_ios_planner.py
```

[验收脚本](../../tooling/scripts/test_ios_planner.py)按锁文件准备依赖，在新建的独立 iPhone 模拟器上编译正常入口 `lib/main.dart`。[界面用例](../../apps/client/ios/RunnerUITests/RunnerUITests.swift)从整周视图新建带唯一标题的 09:00 至 10:00 日程，终止进程并重新启动，核对标题、日期和时段。用例随后通过详情中的「调整」修改标题并重开，再通过「删除」移除日程并重开，检验修改和删除都已保存。任何一步失败就以失败退出。测试结束后移除这台测试模拟器；Xcode 执行测试时生成的记录保存在 `apps/client/build/ios-planner-test/run-*/Planner.xcresult`。

周历数据库通过 `sqflite_darwin` 打开应用支持目录中的 `weekglass.sqlite3`；`path_provider_foundation` 提供目录，`shared_preferences_foundation` 保存设置，`flutter_timezone` 读取时区。Swift 插件由 Flutter 注册。首个 iPhone 版本只开放本机计划；云账号、教务课表、文件导入导出、系统提醒和应用内安装更新留在各自的平台接入阶段。

Windows 已通过 390 × 844 的 Flutter 界面用例：周日 09:00 至 10:00 的日程，创建和改名后各自关闭并重新打开 SQLite，记录标识相同，详情显示的日期与时段正确；从详情删除后再打开数据库，周历为空。iPhone 原生编译、模拟器冷启动和设备性能仍待在 Mac 实测。
