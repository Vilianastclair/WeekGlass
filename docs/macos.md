# WeekGlass macOS 开发与验收

macOS 从 Windows 正式源码 `v0.22.6` 开始，沿用桌面周历、日程规则、SQLite 数据和同步服务。正式入口是原生 `WeekGlass.app`，由 Swift 和 AppKit 创建窗口与菜单，Flutter 渲染周历。快捷操作使用 Command 键，SQLite 数据存放在应用沙盒。普通应用标识为 `com.viliana.weekglass`，工程最低目标 macOS 12.0。

## 在 Mac 上构建和验收

使用有图形登录会话的 Mac、完整 Xcode，以及 `tooling/versions.json` 中固定的 Flutter 3.47.9 和 Dart 3.13.7。在仓库根目录运行：

```bash
bash tooling/scripts/test-macos.sh --package
```

脚本用单独的沙盒启动同一个测试应用两次。从正常侧栏新建日程并保存，退出后再从 SQLite 打开日程，核对标题、备注、起止时间，并保存两张实际界面截图。测试使用独立数据和空的登录存储。随后用正常入口构建 `WeekGlass.app`，核对应用标识、版本和架构。调试包在 `apps/client/build/weekglass-macos/WeekGlass-macOS-debug.zip`，每次验收的日志和截图保存在同目录下的 `verification`。

只在没有现用 WeekGlass 数据的 macOS 登录环境加 `--verify-launch`。它会实际打开构建出的普通应用，等待原生窗口出现，最后仅关闭本次启动的实例。GitHub 私有验证仓库用 `ci/macos-validation-arm64` 运行 Apple Silicon 验收，用 `ci/macos-validation` 验收 Apple Silicon 和 Intel。测试脚本不发布安装包。

## 下载与首次打开

发行包从 WeekGlass 官网及 GitHub 下载，不进入 App Store。macOS 版不使用 Apple Developer ID 签名或公证，使用 WeekGlass 的独立代码签名证书。该证书用于应用与凭据服务互认。安装后先尝试打开 WeekGlass；若系统提示无法验证开发者，确认文件来自官方发行页，再按 [Apple 的说明](https://support.apple.com/zh-cn/102445) 到「系统设置 → 隐私与安全性」仅为 WeekGlass 选择「仍要打开」。

## 功能范围

首个公开版必须在应用内完成后续升级。只做一次实机验收：从待发布版本升到私有后继构建，确认新版启动，日程、偏好和钥匙串留存。手动下载安装仅用于没有更新器的早期测试包。

历史机制试验使用独立标识 `com.viliana.weekglass.updatesmoke`。在干净的 Apple Silicon 图形登录会话中运行 `bash tooling/scripts/prepare-macos-app-update.sh`，它构建 0.22.8+57 和 0.22.9+58，使用同一临时项目证书签应用、同一临时 Ed25519 密钥签本机更新源和包。脚本只启动旧版一次，随后由客户端检查、下载、安装并重启。新版须从原安装路径在新进程中读回原日程、外观设置和文件钥匙串凭据，并显示周历窗口。第一个失败点即停止，日志位于 `apps/client/build/weekglass-macos/verification/`。这两份测试包不分发。

- 桌面周历、侧栏、设置和日程文件导入导出沿用共享代码。工程权限允许读写用户选定的文件。
- 云端登录沿用浏览器与本机回调，凭据使用 macOS 钥匙串。服务端合同增加了 `macos` 设备标识，现有 Windows 和 Android 枚举保留。正式服务器已接受该设备类型。
- 教务网页接入 WKWebView。支持已有专用规则和通用网页读取；两个架构的安装包均携带离线课表引擎，已在安装后的应用目录用 CSV 验收读取。
- macOS 主窗口关闭 AppKit 自动显隐动效，无窗口动效选项。保留原生窗口按钮，最小化和全屏仍由系统管理。窗口内的界面动效和玻璃设置保持原样。Windows 的托盘和开窗动效仅在 Windows 启用。
- 应用内升级使用 Sparkle 2.10.1；正式包绑定分架构 HTTPS 更新源和项目 Ed25519 公钥。

## 当前验收状态

[正式构建 45790371273](https://github.com/Vilianastclair/WeekGlass-macOS-validation/actions/runs/45790371273)从提交 `524b14a` 生成 Apple Silicon、Intel 两份 0.22.12+61 安装镜像，以及仅用于升级验收的 Apple Silicon 0.22.13+62。两个架构的正式应用均从对应镜像打开了周历窗口，主程序和随包凭据服务通过严格的原生签名验证。首次在受隔离的 Mac 上运行官网 DMG 仍须按上文使用 Apple 的单应用打开流程。

首次连接云账号时，浏览器授权回传到本机。独立沙盒服务 `com.viliana.weekglass.account` 保存刷新凭据，通过项目证书与应用标识同时验证调用方；主程序只在内存使用短期访问凭据。服务加入登录会话，参见 [Apple XPC 服务设置](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html)。每个架构复用[固定组件清单](../tooling/macos-account/frozen-components.json)中的完整已签归档；后续构建从私有发布附件恢复，验证归档、原生资源封印、证书和代码目录标识。正式版本取自客户端 pubspec，私有后继由 [升级配置](../tooling/macos-account/private-successor.json) 指定。

[身份机制验证](https://github.com/Vilianastclair/WeekGlass-macOS-validation/actions/runs/45788837337)在独立测试身份下验证了不同版本通过同一沙盒服务读回合成钥匙串项，同时拒绝其他应用标识。公开前仍须在普通正式包中完成 61 至 62 自动升级，并以同一账号、同一设备、受保护请求和零授权交互验收。

### 早期测试记录

2026 年 11 月 26 日，私有仓库的[单次升级验收](https://github.com/Vilianastclair/WeekGlass-macOS-validation/actions/runs/45780998382)在 Apple Silicon、macOS 15.8.2、Xcode 16.4 上执行了提交 `374c2be`。两版通过原生代码签名校验，绑定同一证书和应用标识。旧版请求更新源和后继包，服务器均返回 HTTP 200；新启动的构建 58 写出了错误回执。测试在文件钥匙串操作时收到 `errSecAuthFailed`（`-25293`），未生成周历窗口截图。该次回执没有区分读取凭据和删除测试项。正式发行等待登录凭据在新版中无交互读回的证据。

[Apple 的安全服务源码](https://github.com/apple-oss-distributions/Security/blob/main/securityd/src/clientid.cpp#L254-L274)为符合其证书规则的开发者分配团队分区；其他签名程序按代码目录摘要分区。重建后的自签主程序可以通过同一身份要求，却落入不同的钥匙串分区。这与本次拒绝相符；记录中没有系统给出的具体分区判定。

初版 `0326a87` 在 Apple Silicon 的 macOS 15.8.2 图形会话用 Xcode 16.4 构建。LaunchServices 打开了 1024 × 681 的原生窗口，隔离测试从周历新建日程后退出，重开时核对了标题、备注和时间。
