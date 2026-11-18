# 从教务页面到日历

武汉大学沿用已验证的本人账号流程。其他学校使用同一个学校选择器；若只有学校与版式的绑定，没有可靠的 HTTPS 入口，可以先选校名，再填写官网提供的教务入口。未映射的学校默认自动识别，也可指定教务系统，不必选择解析类、粘贴响应或导出文件。

## 两份真实页面经过本机引擎和日历

测试使用 [WakeUp 作者保存的学校页面](https://github.com/YZune/Schedule_Html/tree/e036a6ee3dc3b5d438a6fb72c5be84376ffde896)。原页面不再分发。Edge 在独立临时配置中仅连接本机，禁止原页面脚本、外部资源及表单提交。运行实际 Dart 读取协调器，包括注册表查询、同源区域提取、异步结果取回和安装版 JVM 解析。Flutter 测试在相同来源和学期下预览、确认、保存，再重复导入。回放使用指定的第一周和节次时间；原页没有提供这些学校的完整校历和作息。

| 原页 | 可排规则 | 首次保存 | 重复导入新增 |
| --- | ---: | ---: | ---: |
| [天津工业大学 URP](https://github.com/YZune/Schedule_Html/blob/e036a6ee3dc3b5d438a6fb72c5be84376ffde896/天津工业大学_URP_0.html) | 19 | 242 | 0 |
| [内蒙古民族大学 URP](https://github.com/YZune/Schedule_Html/blob/e036a6ee3dc3b5d438a6fb72c5be84376ffde896/内蒙古民族大学_URP_0.html) | 58 | 185 | 0 |

内蒙古民族大学原页的明细星期写作“一”至“日”，没有“周”前缀；回放暴露并修正了原解析器把它们当成星期 0 的问题。课表通过培养计划分类展示，读取同一学期明确关联的课程明细，不把两份独立课表拼在一起。原有[四份正方和强智历史页的验收](../school-direct-20261118/portal-reader.md)继续通过。

## JSON 课表如何取得

Windows 和 Android 共用随包脚本。用户点读取后，只处理本人课表的指定区域或课程字段。校方查询使用当前页面的同源会话，不允许重定向，不取出登录凭证，也不订阅所有网络响应。同校未预配置的教务域须由用户确认，只对本次打开学校页面有效。下表描述读取条件，不代表已用各校的学生账号完成导入。

| 解析器 | 当前可读取的入口与条件 |
| --- | --- |
| 新 URP | 个人课程明细表或课表模型。若当前课表含 mycoursetable，并已请求作者历史页中记载的个人课表接口，可重复查询那个确切的同源地址。 |
| 北京航空航天大学 | 读取 datas.arrangedList。优先读取已展示的课表模型；若本研教务页提供可识别的学期选择器，可向官方域的 getMyScheduleDetail.do 查询。合成回放验证教师、单双周、教室、起止时刻，以及学期不符时停止。 |
| 南方科技大学 | 已显示的课表模型，或从 tis.sustech.edu.cn 按所选学期查询 xszykb/queryxszykbzong。 |
| 西北工业大学与上海工程技术大学新版 | 本人课表的页面模型，或使用该页所选的学期和已发布的排课模型标识查询。西工大需要同一学期的 get-data 与 print-data 两份响应；上海工程技术大学使用 print-data。 |
| 福州软件职业技术学院 | 已显示的个人学习计划数据表，行数须与 total 相符。如果学校仅将当前分页保留在模型中，不把它当作完整学期。 |
| 重庆对外经贸学院、合肥工业大学、吉林大学研究生 | 从个人课表页面模型中按各校字段取数。公开解析器未给出可复用的当前校方请求契约；页面未暴露课程模型时无法取得此专用输入。 |
| 桂林电子科技大学北海校区、江西农业大学接口版、阳光学院 | 已显示的个人课程模型有离线解析路径；原接入代码分别使用内网 HTTP 地址、登录跳转标识、或包含学号姓名的请求。WeekGlass 不照搬这些登录链，不猜接口，也不向学校索要额外账号资料。 |

如课表没有结束周，江西师范大学及依赖全学期范围的清华大学课表会要求填写本校该学期的教学周数，再对同一份本机课表继续解析。取消不会写入日程。

手机画面：[选校](school-picker-phone.png)、[打开本人课表](school-entry-phone.png)、[确认后保存](school-preview-phone.png)。

## 重现

在 Windows 项目工具环境中进入 apps/client。将 WG_SCHOOL_ARCHIVE_DIR 指向上述两份及原有四份 HTML 的目录；WG_SCHOOL_ENGINE_DIR 指向 Windows 安装内含 runtime、engine.jar、lib 的 data/course_adapter 目录。执行：

```powershell
flutter test --no-pub test/school_portal_model_test.dart test/school_portal_archive_test.dart test/school_portal_timetable_test.dart test/school_portal_import_widget_test.dart
```
