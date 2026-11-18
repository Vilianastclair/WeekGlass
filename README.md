# WeekGlass

**优雅地规划你的一天！**

WeekGlass 是一款面向 Windows 和 Android 的周日历。把课表、约会和专注时间放进同一张日历。无需账号，离线也能排日程。

- [下载 Windows x64 安装包](https://github.com/Vilianastclair/WeekGlass/releases/download/v0.21.0/WeekGlass-Setup-0.21.0-Windows-x64.exe)
- [下载 Android ARM64 APK](https://github.com/Vilianastclair/WeekGlass/releases/download/v0.21.0/WeekGlass-Android-0.21.0-arm64.apk)

[GitHub 发行页](https://github.com/Vilianastclair/WeekGlass/releases) | [官网](https://cloud.viliana.cn/) | [English](README-EN.md)

**Windows**：运行 EXE 安装，在「设置 → 软件与通知」检查更新。

**Android**：打开 APK 安装，在「设置 → 软件更新」升级。下载并校验后，WeekGlass 会在前台打开系统安装器，按提示确认即可。

## 排好你的一周

- **拖出一段时间**：在日历上直接创建日程，点开先看备注。每周重复的安排可以一起建、一起改。
- **手机上双指缩放时间轴**：捏合看全天，张开看细节，自动记住本机的显示比例。
- **按作息查看日程**：调整起床和睡眠时间不会改写已有日程；日历只显示清醒时段内的部分。连接支持作息同步的云服务后，两端可共用这组时间。
- **导入课表和日历**：在「学校课表」里选择学校，登录教务并打开个人课表，读取后核对课程再保存。武汉大学保留专用导入；其他学校可通过通用入口读取符合新正方或强智格式的页面。也可导入 ICS、CSV、JSON，导出彩色或黑白 PDF。
- **日程默认留在本机**：要跨设备同步，可以选官方付费云服务，也可以[用自己的服务器免费同步](server/README.md)。

## 使用官方云

打开「设置 → 云服务」，点「订阅云服务」在浏览器开通，再回到云服务登录同一账号，确认合并后才同步。官方云 ¥1.00／30 天或 ¥9.99／365 天，微信单次付款，不自动续费。

在[云服务账号网页](https://cloud.viliana.cn/account)管理订单、设备和账号安全。订阅到期后停止云端同步，本机日历照常使用；如需取回云端日程，可从网页自助导出。

## 从源码构建

[0.21.1 更新说明](docs/releases/0.21.1.md)

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
