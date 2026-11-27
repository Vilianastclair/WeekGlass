# iPhone 开发与验收

本分支 `client/ios` 基于 Android 0.22.11+60 的 `57dd4a3`。比对 macOS 0.22.12+61 后，两边的领域、数据和设计系统代码一致；此处沿用移动分支的周历、手势和编辑器。Runner 使用项目固定的 Flutter 3.47.9（Dart 3.13.7）Swift 模板，目标为 iOS 15 及以上的 iPhone。工程位于 [Runner 工作区](../../apps/client/ios/Runner.xcworkspace)。

## 设备发行包

在 Mac 上使用 Xcode 26.2、Python 3 与上方固定版本的 Flutter，从源码根目录运行：

```sh
python3 tooling/scripts/package_ios_device.py
```

[设备构建脚本](../../tooling/scripts/package_ios_device.py)编译正常入口的 iOS Release AOT 版本，检查应用和框架的设备平台、arm64 架构、版本、离线素材、字体及插件注册，再以 `Payload/Runner.app` 打包。IPA 和同名 JSON 收据写入 `apps/client/build/ios/device-package/`。收据列出 Git 提交、文件大小、SHA256 和实测的包内容。包内不含证书或描述文件，安装前须个人签名。

将 iOS 源码提交推至公开构建分支 `ci/ios-device` 后，[设备工作流](../../.github/workflows/ios-device.yml)使用标准 macOS 15 托管机执行同一入口，收件名称为 `WeekGlass iOS device package`。本流程不开模拟器。

## 模拟器开发验收

准备好 Xcode、iOS 模拟器运行时、Python 3 和上述 Flutter 后，在 Mac 上从本分支源码根目录运行：

```sh
python3 tooling/scripts/test_ios_planner.py
```

[验收脚本](../../tooling/scripts/test_ios_planner.py)按锁文件准备依赖，在新建的独立 iPhone 模拟器上编译正常入口 `lib/main.dart`。[界面用例](../../apps/client/ios/RunnerUITests/RunnerUITests.swift)从整周视图新建带唯一标题的 09:00 至 10:00 日程，终止进程并重新启动，核对标题、日期和时段。用例随后通过详情中的「调整」修改标题并重开，用系统「文件」保存 JSON，删除日程并重开，再从系统选择器导回同一文件，重开后核对标题、日期和时段。任何一步失败就以失败退出。测试结束后移除这台测试模拟器；Xcode 执行测试时生成的记录保存在 `apps/client/build/ios-planner-test/run-*/Planner.xcresult`。

周历数据库通过 `sqflite_darwin` 打开应用支持目录中的 `weekglass.sqlite3`；`path_provider_foundation` 提供目录，`shared_preferences_foundation` 保存设置，`flutter_timezone` 读取时区。Swift 插件由 Flutter 注册。iPhone 已开放本机日程和[日程文件导入导出](iphone-calendar-files.md)。从「设置 → 云服务」可连接官方云或自托管服务器。登录使用系统 Safari 界面和本机钥匙串，首次合并后同步日程及对应校历。iPhone 可接收其他设备导入的课程，尚未提供教务导入、系统提醒或应用内安装更新。

Windows 已通过 390 × 844 的 Flutter 界面用例：周日 09:00 至 10:00 的日程，创建和改名后各自关闭并重新打开 SQLite，记录标识相同，详情显示的日期与时段正确；从详情删除后再打开数据库，周历为空。已发布的 0.22.14 用 iPhoneOS SDK 构建设备版；iPhone 17 Pro 模拟器验证了新建、改名与冷启动留存。系统文件保存再导入的完整往返和实体 iPhone 的安装运行尚未验完。

## 云端账号验收

在 Mac 上运行 `bash tooling/scripts/ios_cloud_fixture.sh`。它在回环地址启动独立的 WeekGlass 服务与 PostgreSQL，用一次性测试账号从 iPhone 模拟器的设置页登录，检查授权、合并和冷启动后的连接，并核对服务端记录的设备类型。退出时删除本次模拟器和测试服务。
