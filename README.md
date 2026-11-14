# WeekGlass · 周计划

[English](README-EN.md) · [官网](https://cloud.viliana.cn/) · [下载 Windows](https://cloud.viliana.cn/download/windows) · [下载 Android](https://cloud.viliana.cn/download/WeekGlass-Android-arm64.apk)

WeekGlass 是一款本机优先的周日历。它把一周放在同一张时间网格上，让你看清什么时候有空、在哪留出一段时间。无需注册即可离线使用；要跨设备同步，可以使用官方云，也可以自托管。

- 在空白处点击或拖动创建日程；查看备注、复制日程，或批量编辑同一系列。
- 可隐藏睡眠时段、自选皮肤和侧栏功能；Windows 固定周视图，Android 的视图适配手机。
- 支持武汉大学在线课表，导入前可以核对节次和教学周。日历可导入 ICS、CSV、JSON，也可导出彩色或黑白 PDF。
- 日程默认留在本机。官方云同步是独立的可选付费服务；[自托管同步](server/README.md)不收费。

## 从源码构建

使用 **Flutter 3.47.9（Dart 3.13.7）**。在仓库根目录运行：

```powershell
cd apps/client
flutter pub get
flutter analyze
flutter test
```

**Windows x64**：安装 Visual Studio 的「使用 C++ 的桌面开发」工作负载（含 x64 C++ 工具、ATL、CMake 和 Windows SDK），开启 Windows 开发人员模式。运行 `flutter build windows --release`，在 `build/windows/x64/runner/Release` 中运行 `weekglass.exe`，保留同目录的依赖文件。学校登录还需要 Edge WebView2 Runtime。

**Android ARM64**：安装 JDK 17、Android SDK 36 和 NDK 28.2.13676358。运行 `flutter build apk --release --target-platform android-arm64`，安装包位于 `build/app/outputs/flutter-apk/app-release.apk`。本机构建使用开发签名，不能覆盖签名不同的已安装版本。

客户端和原生入口在 `apps/client`；日程规则、SQLite 存储、视觉组件在 `packages`；同步服务、API 合同与增量更新工具在 `server`。首次安装建议用官网提供的安装包；应用内更新沿用官方签名发行渠道。

<a name="support"></a>

## 捐赠说明

目前还未开放捐赠。如果 WeekGlass 对你有用，欢迎在仓库右上角点 **Star**，或把它分享给朋友。遇到问题或有改进建议，也欢迎[告诉我们](https://github.com/Irthing/WeekGlass/issues/new)。

## 开源与商业授权

Copyright © 2026 Viliana and WeekGlass contributors.

WeekGlass 自有代码采用 [GNU AGPL-3.0-only](LICENSE)。个人和企业都可以按 AGPL 使用；本地使用和自托管免费，官方云服务可另行收费。需要闭源分发或运营修改版、希望采用不同条款的，可发邮件至 [support@viliana.cn](mailto:support@viliana.cn?subject=WeekGlass%20Commercial%20Licensing) 洽谈单独的商业授权。购买官方云服务不等于取得商业代码许可。

此前按 MIT 发布的版本仍按其原有许可使用。随仓库分发的第三方代码和字体继续遵循各自的[许可](THIRD_PARTY_NOTICES.md)。
