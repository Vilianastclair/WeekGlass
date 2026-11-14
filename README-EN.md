# WeekGlass

[简体中文](README.md) · [Website](https://cloud.viliana.cn/) · [Download for Windows](https://cloud.viliana.cn/download/windows) · [Download for Android](https://cloud.viliana.cn/download/WeekGlass-Android-arm64.apk)

WeekGlass is a local-first weekly calendar for Windows and Android. See your week in one grid, set aside time by dragging on the calendar, and open event notes without entering edit mode. Organize recurring events, import ICS, CSV or JSON, or export a color or black-and-white PDF. Windows keeps a full-week view; Android offers layouts suited to a phone.

You can use the calendar offline without an account. Official hosted sync is optional and paid; [self-hosted sync](server/README.md) is free.

## Build from source

Use **Flutter 3.47.9 (Dart 3.13.7)**. From the repository root:

```powershell
cd apps/client
flutter pub get
flutter analyze
flutter test
```

- **Windows x64:** Install Visual Studio's Desktop development with C++ workload with x64 tools, ATL, CMake and a Windows SDK, then enable Windows Developer Mode. Run `flutter build windows --release` and launch `weekglass.exe` from `build/windows/x64/runner/Release`. Keep the files next to the executable. School sign-in also needs the Edge WebView2 Runtime.
- **Android ARM64:** Install JDK 17, Android SDK 36 and NDK 28.2.13676358. Run `flutter build apk --release --target-platform android-arm64`. The APK is at `build/app/outputs/flutter-apk/app-release.apk`. Local builds use a development key and cannot replace an install signed with a different key.

`apps/client` contains the shared Flutter app and native runners, `packages` contains calendar logic, local storage and UI components, and `server` contains the sync API, its contract and the signed update utilities. Official installations and in-app updates remain on the WeekGlass distribution channel.

## Donations

Donations aren't open yet. If WeekGlass is useful to you, you can star this repository or share it with a friend. You can also [report a problem or suggest an improvement](https://github.com/Irthing/WeekGlass/issues/new).

## Open source and commercial licensing

Copyright © 2026 Viliana and WeekGlass contributors.

WeekGlass's original code is available under the [GNU AGPL-3.0-only](LICENSE). Individuals and businesses can use it under the AGPL. Local use and self-hosting are free; official hosted sync is a separate paid service. If you want to distribute a closed-source derivative or run a modified service under different terms, contact [support@viliana.cn](mailto:support@viliana.cn?subject=WeekGlass%20Commercial%20Licensing) to discuss a separate commercial license. A hosted sync purchase does not grant a commercial source code license.

Earlier releases published under MIT keep their original license. Bundled third-party code and fonts remain under their [respective licenses](THIRD_PARTY_NOTICES.md).
