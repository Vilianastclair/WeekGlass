# WeekGlass

**优雅地规划你的一天！**

WeekGlass 是一款面向 Windows 和 Android 的周日历。把课表、约会和专注时间放进同一张日历。无需账号，离线也能排日程。

[下载 Windows x64 安装包](https://github.com/Vilianastclair/WeekGlass/releases/download/v0.20.13/WeekGlass-Setup-0.20.13-Windows-x64.exe) · [下载 Android ARM64（APK）](https://github.com/Vilianastclair/WeekGlass/releases/download/v0.20.13/WeekGlass-Android-0.20.13-arm64.apk) · [官网](https://cloud.viliana.cn/) · [English](README-EN.md)

**Windows**：打开 EXE 安装。**Android**：打开 APK 安装。已有用户可在「设置 → 软件更新」升级。

## 排好你的一周

- **拖出一段时间**：在日历上直接创建日程，点开先看备注。每周重复的安排可以一起建、一起改。
- **导入课表和日历**：支持武汉大学在线课表和 ICS、CSV、JSON 文件。需要打印时，可导出彩色或黑白 PDF。
- **日程默认留在本机**：要跨设备同步，可以选官方付费云服务，也可以[用自己的服务器免费同步](server/README.md)。

## 从源码构建

使用 Flutter 3.47.9（Dart 3.13.7）。在仓库根目录运行：

```sh
cd apps/client
flutter pub get
flutter test
```

- **Windows**：准备 Visual Studio 的 C++ 桌面开发工具（含 ATL、CMake 和 Windows SDK），开启开发人员模式。运行 `flutter build windows --release`。[构建 EXE 安装包](tooling/windows-installer/README.md)。
- **Android**：准备 JDK 17、Android SDK 36 和 NDK 28.2.13676358。运行 `flutter build apk --release --target-platform android-arm64`。

<a name="support"></a>

## 支持 WeekGlass

用得顺手的话，欢迎点个 Star、[友情赞助](https://cloud.viliana.cn/support)，或[告诉我哪里还能做得更好](https://github.com/Vilianastclair/WeekGlass/issues/new)。

## 许可证

WeekGlass 自有代码采用 [AGPL-3.0-only](LICENSE)。需要单独商业授权，请联系 [support@viliana.cn](mailto:support@viliana.cn?subject=WeekGlass%20Commercial%20Licensing)。[第三方许可](THIRD_PARTY_NOTICES.md)
