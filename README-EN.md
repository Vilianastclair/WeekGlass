# WeekGlass

**See your week at a glance. Make time for what matters.**

WeekGlass is a weekly calendar for Windows and Android. Keep classes, appointments, and focus time in one view. Plan offline without an account.

[Download for Windows x64 (ZIP)](https://github.com/Irthing/WeekGlass/releases/download/downloads-2026-11-14/WeekGlass-Windows-x64-0.20.10.zip) · [Download for Android ARM64 (APK)](https://github.com/Irthing/WeekGlass/releases/download/downloads-2026-11-14/WeekGlass-Android-0.20.12-arm64.apk) · [Website](https://cloud.viliana.cn/) · [简体中文](README.md)

**Windows:** Extract the full ZIP, then run `weekglass.exe`. **Android:** Open the APK to install.

## Plan your week

- **Make time by dragging on the calendar.** Open an event to see its notes. Create and edit recurring events as a group.
- **Bring in an existing schedule.** Import a Wuhan University timetable or an ICS, CSV, or JSON file. Export a color or black-and-white PDF to print.
- **Keep your calendar on your device.** To sync across devices, choose the paid WeekGlass Cloud service or [use your own server for free](server/README.md).

## Build from source

Use Flutter 3.47.9 (Dart 3.13.7). From the repository root:

```sh
cd apps/client
flutter pub get
flutter test
```

- **Windows:** Install Visual Studio's Desktop development with C++ tools, including ATL, CMake, and the Windows SDK. Enable Developer Mode and run `flutter build windows --release`.
- **Android:** Install JDK 17, Android SDK 36, and NDK 28.2.13676358. Run `flutter build apk --release --target-platform android-arm64`.

## Support WeekGlass

If WeekGlass works well for you, star the repository or [tell me what could be better](https://github.com/Irthing/WeekGlass/issues/new).

## License

Original WeekGlass code is available under [AGPL-3.0-only](LICENSE). For a separate commercial license, email [support@viliana.cn](mailto:support@viliana.cn?subject=WeekGlass%20Commercial%20Licensing). [Third-party notices](THIRD_PARTY_NOTICES.md)
