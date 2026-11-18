"""Prepare the offline portion of the pinned source tree. The archive remains unmodified."""
import json
import re
import os
import shutil
import tempfile
from urllib.request import urlopen
from pathlib import Path
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parent
PIN = "0cb290485d25b23ad3945608a6252e1293cc7c1e"

def upstream_archive():
    local = ROOT / f"CourseAdapter-{PIN[:7]}.zip"
    if local.is_file():
        return local
    # The original archive includes author-specific test material. Git users
    # fetch the pinned upstream source at build time instead of mirroring it.
    cache = Path.home() / ".cache/weekglass-courseadapter/upstream"
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / f"{PIN}.zip"
    if not archive.is_file():
        with tempfile.NamedTemporaryFile(dir=cache, delete=False) as tmp:
            name=tmp.name
        try:
            with urlopen(f"https://codeload.github.com/project-tRNA/CourseAdapter/zip/{PIN}", timeout=60) as response, open(name,"wb") as sink:
                shutil.copyfileobj(response, sink)
            with ZipFile(name) as z:
                z.getinfo(f"CourseAdapter-{PIN}/LICENSE")
            os.replace(name,archive)
        finally:
            Path(name).unlink(missing_ok=True)
    return archive

# Change only the transport around the original course conversion functions.
def cut(s, start, end, replacement=""):
    a = s.index(start)
    b = s.index(end, a)
    return s[:a] + replacement + s[b:]

def offline(name, s):
    # Upstream developer examples may print or open files; never include the examples.
    s = re.sub(r'^fun main\(\)\s*\{.*?^\}', '', s, flags=re.M|re.S)
    if name == "Parser":
        s = s[:s.index("    private fun convertCourse")] + "}\n"
        s = cut(s, "    private val _baseList", "    abstract fun")
        s = s.replace("import main.java.Generator", "")
    if name == "Common":
        s = cut(s, "    suspend fun <T> Semaphore", "    // ✅")
    if name == "AHSTUParser":
        s = s[:s.index("class AHSTUCourseProvider")]
        s = s.replace("    val timeTable = TimeTable(", "    override fun generateTimeTable() = TimeTable(")
    if name == "CTGUParser":
        s = cut(s, "        val file = File(source)", "        val courseList")
        s = s.replace("courseFilePath.readText()", "source")
    if name == "JAVTCParser":
        s = s.replace('JAVTCParser() : Parser("")', 'JAVTCParser(source: String) : Parser(source)')
        s = re.sub(r'Jsoup\.connect\("[^"]+"\)\.get\(\)', 'Jsoup.parse(source)', s)
    if name == "HHUParser":
        s = cut(s, "class HHUParser(", "        // 两个正则", "class HHUParser(source: String) : Parser(source) {\n    override fun generateCourseList(): List<Course> {\n        val body = source\n")
    if name == "SUSTechParser":
        s = cut(s, "class SUSTechParser(", "        //parseCourseList", "class SUSTechParser(source: String) : Parser(source) {\n    override fun generateCourseList(): List<Course> {\n        val rd = source\n")
    if name == "JXAUJkParser":
        s = cut(s, "class JXAUJkParser(", "        for (course in courseTable)", "class JXAUJkParser(source: String) : Parser(source) {\n    override fun generateCourseList(): List<Course> {\n        val courseList = arrayListOf<Course>()\n        val courseTable = Gson().fromJson(source, CourseTableInfo::class.java).Data\n")
        s = s[:s.index("    private fun getSemesterId")] + "}\n"
    if name == "GDBHParser":
        s = cut(s, "    private final String cookie;", "    @Nullable", "    public GDBHParser(String source) { super(source); }\n")
        s = s.replace("getCourseList();", 'courseArray = JsonParser.parseString(getSource()).getAsJsonObject().getAsJsonArray("data");')
        s = s[:s.index("    private String sendGetRequest")] + "}\n"
        s = s.replace("List.of(", "java.util.Arrays.asList(")
    if name == "YGUParser":
        s = cut(s, "class YGUParser :", "        val coursesDataJson =", 'class YGUParser(source: String) : Parser(source) {\n    private var _nodes = 12\n    private val _courseDataArrayList = ArrayList<courseData>()\n    init {\n        val coursesDataJsonStr = source\n')
        s = s.replace('return _tableName', 'return "阳光学院"').replace("GetTermDataErrorException(", "IllegalArgumentException(")
    if name == "FSTVCParser":
        s = cut(s, "class FSTVCParser(", "    private val nodeNum", 'class FSTVCParser(source: String) : Parser(source) {\n    private val gson = GsonBuilder().create()\n')
        s = cut(s, "    private suspend fun getStudyPlanApiUrl", "    private fun transformPlanToCourse")
        s = cut(s, "        val apiUrl = runBlocking", "        val p0 =", '        val page = gson.fromJson(source, StudyPlanAPIReturn::class.java)\n        require(page.rows.size == page.total)\n        val plans = page.rows\n        if (plans.isEmpty()) return emptyList()\n')
    if name == "NWPUParser":
        s = cut(s, "const val casLoginUrl:", "    private var _timeTableName", 'class NWPUParser(source: String) : Parser(source) {\n')
        s = cut(s, "    private fun webFunc", "        var countChangAn", '''    override fun generateCourseList(): List<Course> {
        val envelope = JsonParser.parseString(source).asJsonObject
        val jsonFromGetData = envelope.getAsJsonObject("getData")
        val jsonFromPrintData = envelope.getAsJsonObject("printData")
        val semesterName = envelope.get("semesterName")?.asString ?: ""
''')
    if name == "SUESParser2":
        s = cut(s, "    //按照 Cookie", "    private var json:")
        s = cut(s, "    override fun getMaxWeek", "        timetable = json!!", '''    override fun generateCourseList(): List<Course> {
        json = JsonParser.parseString(source).asJsonObject
''')
    if name == "THUParser":
        s = cut(s, "        semesterRegex.find(source)", "        parseSecondaryCourseTable()")
    if name == "XAUATParser":
        s = cut(s, "        // 如果没有手动录入", "    @Nullable", "        return null;\n    }\n\n")
    if name == "WISTParser":
        s = s.replace("WISTParser(private val source: String) : Parser()", "WISTParser(source: String) : Parser(source)")
    if name == "WISTParser":
        s = re.sub(r"^[ \t]*step = [^\n]*\n", "", s, flags=re.M)
    if name == "CTGUParser":
        s = s.replace('doc.select("tbody")[3]', 'doc.select("tbody:has(td[field=kcmc]):has(td[field=sjms])").last()')
    if name == "UrpParser":
        s = s.replace('kbtable.text().contains("星期一")', 'kbtable.select("th").any { it.text().trim() == "星期一" }')
        s = s.replace('Common.getWeekFromChinese(str)', 'val day = str.removePrefix("星期").removePrefix("周").replace("天","日")\n            if (day.length == 1) "一二三四五六日".indexOf(day) + 1 else 0')
    if name == "ECNUParser":
        s = s.replace('document.select("table.table")[1]', 'document.select("table.table").let { if (it.size == 1) it[0] else it[1] }')
    if name == "SHTechParser":
        s = s.replace('val table = frameDocument.getElementById("div-table")', 'val table = document.getElementById("div-table") ?: frameDocument.getElementById("div-table")')
    if name == "XAUATParser":
        s = s.replace('table.table:nth-child(5) > tbody:nth-child(1)', 'table.table > tbody:has(tr#swsjbzlb1)')
    if name == "NWPUGraduateParser":
        s = s.replace('.getElementsByTag("option").filter { it.hasAttr("selected") }[0]', '.select("option[selected]")[0]')
    if name == "Parser":
        s = s.replace("    abstract fun generateCourseList", """    var confirmedTermWeeks: Int? = null
    fun requireTermWeeks(): Int = confirmedTermWeeks ?: throw org.weekglass.courseadapter.TermWeeksRequired()
    abstract fun generateCourseList""")
    if name == "THUParser":
        s = s.replace("var weekCount = 16", "val weekCount: Int get() = confirmedTermWeeks ?: 0")
        for old, new in (('"全周" -> 1..totalWeeks','"全周" -> 1..requireTermWeeks()'),
                         ('"后八周" -> 9..totalWeeks','"后八周" -> requireTermWeeks().let { maxOf(1,it-7)..it }'),
                         ('"单周" -> 1..totalWeeks step 2','"单周" -> 1..requireTermWeeks() step 2'),
                         ('"双周" -> 2..totalWeeks step 2','"双周" -> 2..requireTermWeeks() step 2')):
            s = s.replace(old,new)
    if name == "JXNUParser":
        s = s.replace('td.attr("bgcolor").equals("#66FFCC")','"#66FFCC".equalsIgnoreCase(td.attr("bgcolor"))')
        s = s.replace("Course c = getCourse(td);", """if (day < 1 || day > 7 || startNode < 1) continue;
                    Course c = getCourse(td, day);""")
        s = s.replace("getCourse(Element td)", "getCourse(Element td, int day)")
        s = cut(s, "        String name, room, teacher;", "    private int getStartNode", r'''        Element cell = td.selectFirst("div");
        if (cell == null) throw new IllegalArgumentException();
        String[] fields = cell.html().split("(?i)<br\\s*/?>", -1);
        if (fields.length < 3) throw new IllegalArgumentException();
        String name = Jsoup.parse(fields[0]).text().trim();
        String room = Jsoup.parse(fields[1]).text().replaceAll("^[（(]\\s*|\\s*[）)]$", "").trim();
        String teacher = Jsoup.parse(fields[2]).text().trim();
        if (name.isEmpty()) throw new IllegalArgumentException();
        return new Course(name, day, room, teacher, 0, 0, 1, requireTermWeeks(), 0, 0f, "", "", "");
    }

''')
    if name == "JinZhiParser":
        s = s.replace(".split(',')", ".split(',', '，')")
        s = cut(s, "                val dayIndex", "                room =", r'''                val weekdayToken = Regex("""(?:星期|周)?([一二三四五六日天1-7])""")
                val periods = Regex("""(?:第)?(\d+)(?:\s*[-~～至]\s*(\d+))?\s*节?""")
                val dayIndex = detail.indices.drop(1).firstOrNull { idx ->
                    weekdayToken.matches(detail[idx].trim()) && (detail[idx].trim().startsWith("星") ||
                        detail[idx].trim().startsWith("周") || periods.matches(detail.getOrNull(idx+1)?.trim() ?: ""))
                } ?: -1
                if (dayIndex < 1) {
                    courseList.add(Course(courseName,0,teacher=teacher,startNode=0,endNode=0,startWeek=0,endWeek=0,type=0))
                    return@forEach
                }
                val token = weekdayToken.matchEntire(detail[dayIndex].trim())!!.groupValues[1].replace("天","日")
                day = token.toIntOrNull() ?: ("一二三四五六日".indexOf(token)+1)
                val nodeInfo = periods.matchEntire(detail.getOrNull(dayIndex+1)?.trim() ?: "")
                start = nodeInfo?.groupValues?.get(1)?.toIntOrNull() ?: 0
                end = nodeInfo?.groupValues?.get(2)?.toIntOrNull() ?: start
''')
        s = s.replace("                        startWeek = 1\n                        endWeek = 1","                        startWeek = 0\n                        endWeek = 0")

    # Logs can contain the full captured page. Strip statements rather than redirecting process-wide streams.
    s = re.sub(r'^([ \t]*)(?:System\.(?:out|err)\.print\w*|println|print)\([^\n]*\)\s*;?[ \t]*$', r'\1' + (';' if name in {'GDBHParser','HUATParser','JXNUParser','HNZJParser'} else 'Unit'), s, flags=re.M)
    s = re.sub(r'^import (?:java\.io\.File|java\.net\.[^\n]*|kotlin\.io\.path\.readText|kotlinx\.[^\n]*|Common\.acquireInBlock|main\.java\.exception\.[^\n]*|org\.jsoup\.Connection[^\n]*);?\s*$', '', s, flags=re.M)
    return s

ALIASES = {
    "ZhengFangParser": ["zf"], "UrpParser": ["urp","urp_new"], "NewZFParser": ["zf_new"], "OldQzParser": ["qz_old"],
    "Qz2017Parser": ["qz_2017"], "QzBrParser": ["qz_br"], "QzCrazyParser": ["qz_crazy"],
    "QzWithNodeParser": ["qz_with_node"], "NewUrpParser": ["urp_new_ajax"], "ChengFangParser": ["cf"],
    "JinZhiParser": ["jz"], "PekingParser": ["pku"], "HFUTParser": ["hfu"],
    "CSXYParser": ["ccsu_qz_old","ccsu"], "WakeupParser": ["gxic"], "WISTParser": ["wsit"],
}
JSON = {"BUAAParser","CCIBEParser","HFUTParser","JLUParser","NewUrpParser","FSTVCParser","GDBHParser","YGUParser","SUSTechParser","JXAUJkParser","SUESParser2","NWPUParser"}
HINTS = {
    "CSVParser":"带标题行的七列 CSV：课程名、星期、开始节、结束节、教师、教室、周数。",
    "NewUrpParser":"课表 JSON 含 dateList[0].selectCourseList。", "BUAAParser":"getMyScheduleDetail.do 返回的 JSON。",
    "CCIBEParser":"含 kcmc、xqj、jc、qsz、jsz 的课程 JSON 数组。", "HFUTParser":"含 result.scheduleList、lessonList 和 scheduleGroupList 的课表 JSON。",
    "JLUParser":"吉林大学课表查询的 JSON 响应。",
    "FSTVCParser":"完整教学进度 JSON：rows 包含所有行，total 等于行数，分页须先合并。",
    "GDBHParser":"getstutable 课程响应，含 data 数组。", "SUSTechParser":"queryxszykbzong 返回的课程 JSON 数组。",
    "JXAUJkParser":"GetStudentKebiaoByXq 返回的 JSON，含 Data 数组。",
    "SUESParser2":"所选学期 print-data 响应，含 studentTableVms。",
    "YGUParser":"jw/kpkglkcb/student 的课表 JSON，含 data[].weekList。",
    "NWPUParser":"同一学期的组合 JSON：getData 与 printData 为两份课表响应，semesterName 为可选学期名称。",
    "JXNUParser":"学期课程格没有起止周，需确认该学期教学周数。",
    "CTGUParser":"课表子页 home.html 的内容，不是其父页面或文件路径。",
    "THUParser":"含 setInitValue 的课表页；全周、单双周或后八周须确认学期教学周数。离线不含第三方调休安排。",
    "JNUParser":"含课表 XML 的页面或其 XML 内容。",
}
ORIGINAL = {
    "CTGUParser":"files", "JAVTCParser":"network", "HHUParser":"credentials", "SUSTechParser":"credentials",
    "JXAUJkParser":"credentials","FSTVCParser":"session","GDBHParser":"session","NWPUParser":"credentials",
    "SUESParser2":"session","YGUParser":"session","THUParser":"htmlWithOnlineCalendar","XAUATParser":"htmlWithOnlineCalendar"
}
def prepare(directory):
    rows, cases = [], []
    archive = upstream_archive()
    with ZipFile(archive) as z:
        for info in sorted(z.namelist()):
            rel = info.removeprefix(f"CourseAdapter-{PIN}/")
            if not re.fullmatch(r'(src/main/java/(bean/.+|parser/.+|Common)\.(kt|java)|YZZYParser\.kt)', rel):
                continue
            p = Path(rel)
            src = z.read(info).decode('utf-8-sig').replace('\r\n','\n')
            content = offline(p.stem, src)
            dest = directory / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text(content, encoding="utf8")
            if p.stem in {'Parser','Common'} or 'bean' in p.parts:
                continue
            # One top-level adapter class per parser source. Derive the class, not its filename (e.g. GXIC).
            name = re.search(r'^(?:(?:public|open) )?class (\w+)(?:\s*[:(]| extends Parser)', src, re.M)[1]
            package = re.search(r'^package ([\w.]+)', src,re.M)[1]
            id_ = (ALIASES.get(name) or [re.sub('Parser','',name).lower()])[0]
            for key, extra in [(id_, False)] + ([("zf_1",True)] if name=="ZhengFangParser" else []):
                aliases = sorted(set([name, re.sub("Parser","",name), p.stem, re.sub("Parser","",p.stem), package+"."+name] + ALIASES.get(name, [])) - {key}, key=lambda v:(v.lower(),v)) if not extra else []
                kind = "json" if name in JSON else "csv" if name=="CSVParser" else "html"
                row = dict(id=key,aliases=aliases,available=True,inputKind=kind,originalInputKind=ORIGINAL.get(name,kind),sourceFile=rel,className=package+"."+name,requirement=HINTS.get(name,"所选学期完整课表页面的 HTML，含原始表格与内嵌课表数据。"))
                rows.append(row)
                args = ('source, '+str(int(extra))) if name=="ZhengFangParser" else 'source'
                cases.append(f'        "{key}" -> {package}.{name}({args})')
    rows.sort(key=lambda r:r['id'])
    data = dict(revision=PIN,adapters=rows)
    path = directory/"Registry.kt"
    path.write_text("package org.weekglass.courseadapter\nimport parser.Parser\ninternal fun parserFor(id:String,source:String):Parser = when(id) {\n"+"\n".join(cases)+'\n        else -> throw IllegalArgumentException("Unknown adapter")\n}\n',encoding="utf8")
    return data

