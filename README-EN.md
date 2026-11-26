# WeekGlass

**See your week at a glance. Make time for what matters.**

WeekGlass is a weekly calendar for Windows and Android. Keep classes, appointments, and focus time in one view. Plan offline without an account.

- [Download the Windows x64 installer](https://github.com/Vilianastclair/WeekGlass/releases/download/v0.22.0/WeekGlass-Setup-0.22.0-Windows-x64.exe)
- [Download the Android ARM64 APK](https://github.com/Vilianastclair/WeekGlass/releases/download/v0.22.0/WeekGlass-Android-0.22.0-arm64.apk)

[GitHub releases](https://github.com/Vilianastclair/WeekGlass/releases) | [Website](https://cloud.viliana.cn/) | [简体中文](README.md)

**Windows:** Run the EXE installer. Check for updates under Settings → Software and notifications.

**Android:** Open the APK to install. Get updates under Settings → Software Update. After verification, WeekGlass opens the system installer in the foreground so you can confirm installation.

## Plan your week

- **Make time by dragging on the calendar.** Open an event to see its notes. Create and edit recurring events as a group.
- **Pinch the time axis on your phone.** Pinch inward to fit the day or spread vertically for detail. Your display scale is remembered on this device.
- **Set your visible hours.** Changing wake and sleep times clips the calendar view without modifying saved events. Both times can sync between devices on a compatible server.
- **Bring in an existing schedule.** Choose your school, sign in to its academic portal, open your personal timetable and review the courses before saving. Wuhan University has a dedicated import flow. The in-app reader handles supported school-specific pages and systems including Zhengfang, Qiangzhi and URP. Choose the undergraduate or graduate portal you actually use. Import and export ICS, CSV or JSON, or export a weekly schedule as a monochrome A4 PDF for printing.
- **Keep your calendar on your device.** To sync across devices, choose the paid WeekGlass Cloud service or [use your own server for free](server/README.md).

## Use WeekGlass Cloud

Open **Settings → Cloud services → Subscribe to cloud** to buy a plan in your browser. Then return to Cloud services and sign in with the same account. Sync starts after you confirm the calendar merge. Plans cost ¥1.00 for 30 days or ¥9.99 for 365 days, paid once with WeChat Pay. Neither plan renews automatically.

Visit [your cloud account](https://cloud.viliana.cn/account) to manage orders, devices and account security. When your subscription ends, cloud sync pauses and your local calendar keeps working. You can export your cloud calendar from the account site.

## Build from source

[What changed in 0.22.0 (Chinese)](docs/releases/0.22.0.md)

Use Flutter 3.47.9 (Dart 3.13.7). From the repository root:

```sh
cd apps/client
flutter pub get
flutter test
```

- **Windows:** Install Python 3.9 or later, the [pinned JDK 17](docs/product/wakeup-engine-runtime.md) and Visual Studio's Desktop development with C++ tools, including ATL, CMake, and the Windows SDK. Enable Developer Mode and run `flutter build windows --release`. [Build the EXE installer](tooling/windows-installer/README.md).
- **Android:** Install JDK 17, Android SDK 36, and NDK 28.2.13676358. Run `flutter build apk --release --target-platform android-arm64`.

## Support WeekGlass

If WeekGlass works well for you, star the repository, [support it via WeChat](https://cloud.viliana.cn/support), or [tell me what could be better](https://github.com/Vilianastclair/WeekGlass/issues/new).

## License

Original WeekGlass code is available under [AGPL-3.0-only](LICENSE). For a separate commercial license, email [support@viliana.cn](mailto:support@viliana.cn?subject=WeekGlass%20Commercial%20Licensing). [Third-party notices](THIRD_PARTY_NOTICES.md)
