# 课表解析器的本机运行方式

Windows 和 Android 都编译 `tooling/course_adapter_engine` 中固定版本的解析器。客户端只传入选定的格式和课表内容，不传学校登录会话。解析失败或超时只结束这次读取；日历、原有导入和其他本机功能不依赖解析器进程。

## Windows

正常运行 `tooling/scripts/build-windows.ps1`。CMake 使用工程指定的 Microsoft OpenJDK 17 和 Python 3.9 以上版本构建，最终在主程序旁的 `data/course_adapter` 下安装引擎和专用运行时。运行时仅链接 Java 基础、XML、日志和 Gson 反射所需的模块，不是整套开发工具。用户不需要配置 Java 或 PATH。

每次读取由一个临时进程通过 UTF-8 管道完成；专用 Java 17 策略允许读取引擎 JAR 和依赖，不授予网络或任意文件访问权限。15 秒后终止未返回的进程。更新包应包含整个 `data/course_adapter`，所有新文件均沿用既有 Windows 安装与增量分发流程。

## Android

正常运行 `tooling/scripts/build-android.ps1`。Gradle 编译同一份引擎，R8 保留校方 JSON 所用的字段名。Android 使用系统 ART，无需打包 JRE。解析在不导出且无应用权限的独立服务中运行；两端通过描述符传递内存管道，不受 Binder 单条课表体积限制，也不写临时课表。服务超时后解除绑定并结束正在解析的独立进程。

## 开发验收

在 `apps/client` 中，令 `WEEKGLASS_TEST_COURSE_RUNTIME` 指向 Windows 成品的 `data/course_adapter`，执行 `flutter test test/wakeup_engine_test.dart`，其中一项会直接启动随包 JRE。

在专用测试设备上构建并运行 `flutter build apk --release -t tool/course_adapter_probe.dart` 生成的探针，可验证 Flutter 通道、Android 隔离服务、压缩后的 Gson 实体、中文传输和大于 1 MiB 的输入。探针显示 `COURSE_ADAPTER_OK` 才算通过；它与应用包名相同，不要安装到个人日常使用的设备。验收后用默认入口重新构建交付 APK。

## 对应源码与许可

Windows 保留 JRE 的 `runtime/legal` 及 `OpenJDK.txt`；[微软发布的匹配源码](https://github.com/microsoft/openjdk-jdk17u/tree/release/jdk-17.0.21.0.2_1)与 `tooling/scripts/link_course_runtime.py` 可重建此运行时。Android 的 `desugar_jdk_libs` 2.1.5 对应 [Google 的 2.1.5 源码](https://github.com/google/desugar_jdk_libs/tree/73170c345e6a762fc6a1f0301bb15218850023ef)，授权及来源位于 APK 的 `assets/desugar_licenses`。两者均采用 GPLv2 和 Classpath Exception。对外分发二进制时，同一发行渠道应提供上述对应源码。引擎及 Kotlin、Gson、jsoup 等依赖的许可随引擎提供。
