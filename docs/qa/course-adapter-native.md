# 双端本机课表解析验收

2026 年 11 月 18 日，Windows x64 和 Android ARM64 均通过 Flutter Release 业务入口构建。未发布更新，未使用学校账号。

| 检查 | 观测结果 |
| --- | --- |
| Windows 安装目录 | 从实际 `data/course_adapter` 启动私有 JRE，按正式安全策略使用 `java -jar`，10 组引擎用例通过，包括 URP 中文星期、CSV、HTML 和 JSON。 |
| Dart 映射和传输 | 4 项通过：固定钟点无节点/空节次表仍可保存，错误作息和非周一起始日期不作默认值，UTF-8 体积限制生效，Windows 管道端到端保留课程字段。 |
| Android 隔离服务 | 在 API 34 测试模拟器运行 ARM64 Release 探针，注册表有 84 个模式；1,126,518 字节的合成 JSON 经 Flutter 通道、Binder 描述符和隔离服务读取。R8 后课程名称、教师、教室、星期三、第 3 至 4 节与第 1、3、5 周均正确，未注册的格式返回 `UNKNOWN_ADAPTER`。 |
| 更新包输入 | Windows 解析组件共 126 个文件、36,490,516 字节，按 ZIP Deflate 6 单独压缩为 24,156,224 字节；路径均通过现有增量更新路径规则。Android 业务 APK 为 37,640,876 字节，使用开发签名，包含注册表和授权。 |

可复现入口见[本机运行方式](../product/wakeup-engine-runtime.md)。Windows 测试为已安装布局的真实子进程；Android 测试为运行在模拟器上的实际应用通道，不涉及校方登录，也不代表所有学校和原始数据版本都已通过账号实测。
