# 离线课表解析引擎

一次构建给 Android 和 Windows 提供相同的解析器。运行期只接收课表文本，不接受文件路径、URL、账号、密码或 Cookie。

## 构建和验证

在本目录执行：

```powershell
python build.py
python test_engine.py
```

需要 Python 3.9 或更新版本及 JDK 17 或更新版本。构建使用精确版本的 Kotlin 编译器，先检查 Gradle 缓存，再从 Maven Central 下载缺失的 JAR；机器已有全部依赖时不用联网。用 `JAVA_HOME` 指定 JDK，用 `GRADLE_USER_HOME` 或 `COURSE_ADAPTER_MAVEN_CACHE` 指定依赖缓存。项目便携 JDK 可直接使用。

双端可用 `python build.py --dist <输出目录>` 分别构建，引擎、运行库和许可均写入指定目录；不带参数仍输出到本目录的 `dist/`。

独立命令行示例（Windows）：

```powershell
'{"op":"parse","adapter":"csv","source":"name,day,first,last,teacher,room,weeks\nPhysics,2,1,2,Lee,A101,1-8"}' |
  java -jar dist/engine.jar
```

CLI 读取一条 UTF-8 JSON 请求至 EOF，stdout 仅写一条 UTF-8 JSON 回复。Android 调用静态方法 `org.weekglass.courseadapter.Engine.handle(String)`。把宿主与解析进程分开，为每次请求设超时和内存上限。

## 注册清单

[上游项目](https://github.com/project-tRNA/CourseAdapter/tree/0cb290485d25b23ad3945608a6252e1293cc7c1e) 的 [完整快照](CourseAdapter-0cb2904.zip) 与许可保存在此。构建自动从源码读取包名和实际类名，不把测试程序、抽象基类或内部辅助类算作适配器。根目录的 YZZYParser 也参与编译；旧正方的两个构造模式分别注册为 `zf` 和 `zf_1`。

`{"op":"list"}` 列出与 [registry.json](registry.json) 相同的 84 个模式（83 个解析器类）：71 个接受 HTML，12 个接受课表 JSON，其中西北工业大学需要组合两份响应，1 个接受 CSV。每项列出可调用 ID、别名、输入要求、上游输入类型、实际类和源文件。使用学校/系统名称路由属于宿主职责；清单中的条目是数据格式，不是已验证可登录的学校或网站数量。

## 输入与输出

- `parse` 需要 `adapter` 与 `source` 两个字符串，不能以类路径实例化任意 Java 类型。ID、类名与别名不区分大小写。
- `source` 传入课表 HTML、CSV 或课表响应的 JSON **文本**。接口型适配器不会自己发送请求；单独传登录后的网页外壳也不能代替课程数据。
- 成功返回 `courses`。星期一至星期日为 1 至 7，节次和教学周均是闭区间，`type` 为 0 每周、1 单周、2 双周。课程单独指定的有效起止时间采用 `HH:mm`，无单独时间时为 `""`。
- 成功响应还包括上游提供的 `timeTable`、`tableName`、`nodes`、`startDate`、`maxWeek`。未提供的字段返回 null；从所给片段无法读取的可选元数据列在 `metadataUnavailable`，已解析的课程仍供预览核对。
- 未命中返回 `NO_COURSES` 或 `PARSE_ERROR`；错误输入类型返回 `UNSUPPORTED_INPUT`，没有注册的适配器返回 `UNKNOWN_ADAPTER`，请求不符合协议返回 `INVALID_REQUEST`。异常消息不包含用户数据。

## 离线调整

[prepare.py](prepare.py) 将上游保存文件的工具、示例入口和打印原始课程的语句移出产品。账号登录、Cookie 访问与第三方网络代码不参与运行；需要请求结果的原算法从宿主提供的数据继续执行。三峡大学改为读取课表子页内容。江西师范大学的课表格不含教学周起止。清华大学“全周”“单双周”“后八周”等描述依赖实际学期长度，离线不会补充第三方调休安排。两者在缺少必要学期长度时返回 `NEED_TERM_WEEKS`，宿主需让用户确认后将整数（1 至 53）作为顶层 `termWeeks` 重新提交。西安建筑科技大学未知学期不联网补学期起始日。福州软件职业技术学院只有在所给课程行数与总数一致时才接受整份进度表。

部分旧源码与仓库自身 Course/Parser 构造契约不符，准备步骤按起止节次修复武汉船舶职业技术学院实现。Kotlin 编译按上游既有的平台空值约定读取 Jsoup；目标表格不存在时引擎返回结构化错误。[audit.py](audit.py) 检查已编译适配器的成员引用，阻止新增文件、网络、执行、反射与日志调用；Jsoup 仅可用字符串创建文档，不能访问 URL。Windows 与 Android 的进程隔离由各自宿主实施。

## 分发

`dist/engine.jar` 是共享产物，Windows 用 `java -jar engine.jar`，清单仅加载本次构建锁定的依赖文件；Android 复用同一个引擎 JAR 并通过 Gradle 合并运行依赖，避免重复打包 Kotlin/Gson。精确版本在 [build.py](build.py) 中，许可放入 `dist/licenses/` 和 JAR 资源。源码包不需要保存编译器、JRE 或生成目录。

